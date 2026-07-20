package com.wj.server.invitation.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.time.Clock;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.auth.api.UserSummary;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.InvitationProperties;
import com.wj.server.invitation.api.CreateJoinRequestRequest;
import com.wj.server.invitation.api.DeviceMemberResponse;
import com.wj.server.invitation.api.InviteLinkResponse;
import com.wj.server.invitation.api.JoinRequestResponse;
import com.wj.server.invitation.domain.InviteLinkRow;
import com.wj.server.invitation.domain.JoinRequestRow;
import com.wj.server.invitation.domain.MembershipRow;
import com.wj.server.invitation.persistence.InvitationMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Invite flow: the OWNER shares a per-device invite link (rotating it revokes
 * the previous one), anyone with the link submits a join request after logging
 * in, and the OWNER approves or rejects each request. A link alone never grants
 * membership.
 */
@Service
public class InvitationService {
    private static final SecureRandom SECURE_RANDOM = new SecureRandom();

    private final InvitationMapper invitationMapper;
    private final InvitationProperties properties;
    private final AuditService auditService;
    private final Clock clock;

    @Autowired
    public InvitationService(
        InvitationMapper invitationMapper,
        InvitationProperties properties,
        AuditService auditService
    ) {
        this(invitationMapper, properties, auditService, Clock.systemUTC());
    }

    InvitationService(
        InvitationMapper invitationMapper,
        InvitationProperties properties,
        AuditService auditService,
        Clock clock
    ) {
        this.invitationMapper = invitationMapper;
        this.properties = properties;
        this.auditService = auditService;
        this.clock = clock;
    }

    /** Creates the device invite link, revoking any previous link (rotation). */
    @Transactional
    public InviteLinkResponse createInviteLink(UUID userId, UUID deviceId) {
        requireOwner(userId, deviceId, "MEMBER_INVITE", "INVITE_LINK", null);
        invitationMapper.revokeActiveLinks(deviceId);
        UUID linkId = UUID.randomUUID();
        String token = newToken();
        var expiresAt = clock.instant().plus(properties.ttl());
        invitationMapper.insertLink(linkId, deviceId, hash(token), userId, expiresAt);
        auditService.success(deviceId, userId, "MEMBER_INVITE", "INVITE_LINK", linkId);
        return new InviteLinkResponse(deviceId, token, expiresAt);
    }

    @Transactional
    public void revokeInviteLink(UUID userId, UUID deviceId) {
        requireOwner(userId, deviceId, "MEMBER_INVITE", "INVITE_LINK", null);
        invitationMapper.revokeActiveLinks(deviceId);
        auditService.success(deviceId, userId, "MEMBER_INVITE", "INVITE_LINK", null);
    }

    /** A logged-in user submits the token from a shared link to request joining. */
    @Transactional
    public JoinRequestResponse createJoinRequest(UUID userId, CreateJoinRequestRequest request) {
        InviteLinkRow link = invitationMapper.findLinkByTokenHash(hash(request.inviteToken()))
            .orElseThrow(this::notFound);
        if (link.revokedAt() != null
            || !link.expiresAt().isAfter(clock.instant())
            || "REVOKED".equals(link.deviceStatus())) {
            throw notFound();
        }
        if (invitationMapper.activeMembershipExists(link.deviceId(), userId)) {
            throw conflict("ALREADY_DEVICE_MEMBER", "이미 이 기기의 구성원입니다.");
        }
        if (invitationMapper.pendingJoinRequestExists(link.deviceId(), userId)) {
            throw conflict("JOIN_REQUEST_PENDING", "이미 대기 중인 가입 요청이 있습니다.");
        }
        UUID requestId = UUID.randomUUID();
        invitationMapper.insertJoinRequest(requestId, link.deviceId(), userId);
        JoinRequestRow row = invitationMapper.lockScopedJoinRequest(link.deviceId(), requestId)
            .orElseThrow(this::notFound);
        return toJoinRequest(row);
    }

    @Transactional(readOnly = true)
    public List<JoinRequestResponse> listPendingJoinRequests(UUID userId, UUID deviceId) {
        requireOwner(userId, deviceId, null, null, null);
        return invitationMapper.findPendingJoinRequests(deviceId).stream()
            .map(this::toJoinRequest)
            .toList();
    }

    @Transactional
    public DeviceMemberResponse approveJoinRequest(UUID userId, UUID deviceId, UUID requestId) {
        requireOwner(userId, deviceId, "MEMBER_INVITE", "JOIN_REQUEST", requestId);
        JoinRequestRow request = invitationMapper.lockScopedJoinRequest(deviceId, requestId)
            .orElseThrow(this::notFound);
        if (!"PENDING".equals(request.status())
            || invitationMapper.decideJoinRequest(requestId, "APPROVED", userId) != 1) {
            throw conflict("JOIN_REQUEST_NOT_PENDING", "대기 중인 가입 요청만 승인할 수 있습니다.");
        }
        invitationMapper.activateMember(deviceId, request.userId());
        DeviceMemberResponse response = invitationMapper.findMembership(deviceId, request.userId())
            .map(this::toMember)
            .orElseThrow(this::notFound);
        auditService.success(deviceId, userId, "MEMBER_INVITE", "MEMBERSHIP", response.id());
        return response;
    }

    @Transactional
    public void rejectJoinRequest(UUID userId, UUID deviceId, UUID requestId) {
        requireOwner(userId, deviceId, "MEMBER_INVITE", "JOIN_REQUEST", requestId);
        JoinRequestRow request = invitationMapper.lockScopedJoinRequest(deviceId, requestId)
            .orElseThrow(this::notFound);
        if (!"PENDING".equals(request.status())
            || invitationMapper.decideJoinRequest(requestId, "REJECTED", userId) != 1) {
            throw conflict("JOIN_REQUEST_NOT_PENDING", "대기 중인 가입 요청만 거절할 수 있습니다.");
        }
        auditService.success(deviceId, userId, "MEMBER_INVITE", "JOIN_REQUEST", requestId);
    }

    @Transactional(readOnly = true)
    public List<DeviceMemberResponse> listMembers(UUID userId, UUID deviceId) {
        requireMember(userId, deviceId);
        return invitationMapper.findActiveMembers(deviceId).stream().map(this::toMember).toList();
    }

    @Transactional
    public void revokeMember(UUID userId, UUID deviceId, UUID membershipId) {
        requireOwner(userId, deviceId, "MEMBER_REVOKE", "MEMBERSHIP", membershipId);
        MembershipRow target = invitationMapper.lockScopedMembership(deviceId, membershipId)
            .orElseThrow(this::notFound);
        if ("OWNER".equals(target.role())) {
            auditService.denied(
                deviceId, userId, "MEMBER_REVOKE", "MEMBERSHIP", membershipId,
                "OWNER_CANNOT_BE_REVOKED");
            throw conflict("OWNER_CANNOT_BE_REVOKED", "OWNER 멤버십은 이 API로 회수할 수 없습니다.");
        }
        if (!"ACTIVE".equals(target.status()) || invitationMapper.revokeMember(membershipId, userId) != 1) {
            throw conflict("MEMBERSHIP_NOT_ACTIVE", "활성 MEMBER 멤버십만 회수할 수 있습니다.");
        }
        auditService.success(deviceId, userId, "MEMBER_REVOKE", "MEMBERSHIP", membershipId);
    }

    private void requireOwner(
        UUID userId,
        UUID deviceId,
        String action,
        String targetType,
        UUID targetId
    ) {
        String role = invitationMapper.findActiveRole(userId, deviceId).orElseThrow(this::notFound);
        if (!"OWNER".equals(role)) {
            if (action != null) {
                auditService.denied(deviceId, userId, action, targetType, targetId, "FORBIDDEN_ROLE");
            }
            throw new ApiException(HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE", "OWNER 권한이 필요합니다.");
        }
    }

    private void requireMember(UUID userId, UUID deviceId) {
        invitationMapper.findActiveRole(userId, deviceId).orElseThrow(this::notFound);
    }

    private JoinRequestResponse toJoinRequest(JoinRequestRow row) {
        return new JoinRequestResponse(
            row.id(), row.deviceId(),
            new UserSummary(row.userId(), row.email(), row.displayName()),
            row.status(), row.requestedAt());
    }

    private DeviceMemberResponse toMember(MembershipRow row) {
        return new DeviceMemberResponse(
            row.id(), row.deviceId(), new UserSummary(row.userId(), row.email(), row.displayName()),
            row.role(), row.status(), row.joinedAt());
    }

    private String newToken() {
        byte[] bytes = new byte[32];
        SECURE_RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private String hash(String token) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest(token.trim().getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }

    private ApiException conflict(String code, String message) {
        return new ApiException(HttpStatus.CONFLICT, code, message);
    }
}
