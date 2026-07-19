package com.wj.server.invitation.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.auth.api.UserSummary;
import com.wj.server.auth.domain.UserRow;
import com.wj.server.auth.persistence.AuthMapper;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.InvitationProperties;
import com.wj.server.invitation.api.AcceptInvitationRequest;
import com.wj.server.invitation.api.CreateInvitationRequest;
import com.wj.server.invitation.api.DeviceMemberResponse;
import com.wj.server.invitation.api.InvitationCreatedResponse;
import com.wj.server.invitation.api.InvitationResponse;
import com.wj.server.invitation.domain.InvitationRow;
import com.wj.server.invitation.domain.MembershipRow;
import com.wj.server.invitation.persistence.InvitationMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class InvitationService {
    private static final SecureRandom SECURE_RANDOM = new SecureRandom();

    private final InvitationMapper invitationMapper;
    private final AuthMapper authMapper;
    private final InvitationProperties properties;
    private final AuditService auditService;
    private final Clock clock;

    @Autowired
    public InvitationService(
        InvitationMapper invitationMapper,
        AuthMapper authMapper,
        InvitationProperties properties,
        AuditService auditService
    ) {
        this(invitationMapper, authMapper, properties, auditService, Clock.systemUTC());
    }

    InvitationService(
        InvitationMapper invitationMapper,
        AuthMapper authMapper,
        InvitationProperties properties,
        AuditService auditService,
        Clock clock
    ) {
        this.invitationMapper = invitationMapper;
        this.authMapper = authMapper;
        this.properties = properties;
        this.auditService = auditService;
        this.clock = clock;
    }

    @Transactional
    public List<InvitationResponse> listInvitations(UUID userId, UUID deviceId) {
        requireOwner(userId, deviceId);
        invitationMapper.expirePendingForDevice(deviceId);
        return invitationMapper.findByDevice(deviceId).stream().map(this::toInvitation).toList();
    }

    @Transactional
    public InvitationCreatedResponse create(UUID userId, UUID deviceId, CreateInvitationRequest request) {
        requireOwner(userId, deviceId, "MEMBER_INVITE", "INVITATION", null);
        String email = normalizeEmail(request.email());
        invitationMapper.expirePendingForEmail(deviceId, email);
        if (invitationMapper.activeMembershipExistsByEmail(deviceId, email)) {
            auditService.denied(
                deviceId, userId, "MEMBER_INVITE", "INVITATION", null, "ALREADY_DEVICE_MEMBER");
            throw conflict("ALREADY_DEVICE_MEMBER", "이미 활성 구성원인 사용자입니다.");
        }

        UUID invitationId = UUID.randomUUID();
        String token = newToken();
        Instant now = clock.instant();
        Instant expiresAt = now.plus(properties.ttl());
        try {
            invitationMapper.insert(invitationId, deviceId, userId, email, hash(token), expiresAt);
        } catch (DuplicateKeyException exception) {
            auditService.denied(
                deviceId, userId, "MEMBER_INVITE", "INVITATION", null, "PENDING_INVITATION_EXISTS");
            throw conflict("PENDING_INVITATION_EXISTS", "이미 대기 중인 초대가 있습니다.");
        }
        auditService.success(deviceId, userId, "MEMBER_INVITE", "INVITATION", invitationId);
        return new InvitationCreatedResponse(
            invitationId, deviceId, email, "MEMBER", "PENDING", expiresAt, now, token);
    }

    @Transactional(noRollbackFor = ExpiredInvitationException.class)
    public void revokeInvitation(UUID userId, UUID deviceId, UUID invitationId) {
        requireOwner(userId, deviceId, "MEMBER_INVITE", "INVITATION", invitationId);
        InvitationRow invitation = invitationMapper.lockScoped(deviceId, invitationId).orElseThrow(this::notFound);
        if (!"PENDING".equals(invitation.status())) {
            auditService.denied(
                deviceId, userId, "MEMBER_INVITE", "INVITATION", invitation.id(),
                "INVITATION_NOT_PENDING");
            throw conflict("INVITATION_NOT_PENDING", "대기 중인 초대만 철회할 수 있습니다.");
        }
        if (!invitation.expiresAt().isAfter(clock.instant())) {
            invitationMapper.markExpired(invitation.id());
            auditService.denied(
                deviceId, userId, "MEMBER_INVITE", "INVITATION", invitation.id(),
                "INVITATION_EXPIRED");
            throw expired();
        }
        if (invitationMapper.revokeInvitation(invitation.id()) != 1) {
            throw conflict("INVITATION_NOT_PENDING", "대기 중인 초대만 철회할 수 있습니다.");
        }
        auditService.success(deviceId, userId, "MEMBER_INVITE", "INVITATION", invitation.id());
    }

    @Transactional(noRollbackFor = ExpiredInvitationException.class)
    public DeviceMemberResponse accept(UUID userId, AcceptInvitationRequest request) {
        InvitationRow invitation = invitationMapper.lockByTokenHash(hash(request.invitationToken()))
            .orElseThrow(this::notFound);
        if (!"PENDING".equals(invitation.status())) {
            auditService.denied(
                invitation.deviceId(), userId, "MEMBER_INVITE", "INVITATION", invitation.id(),
                "INVITATION_ALREADY_USED");
            throw conflict("INVITATION_ALREADY_USED", "이미 처리된 초대입니다.");
        }
        if (!invitation.expiresAt().isAfter(clock.instant())) {
            invitationMapper.markExpired(invitation.id());
            auditService.denied(
                invitation.deviceId(), userId, "MEMBER_INVITE", "INVITATION", invitation.id(),
                "INVITATION_EXPIRED");
            throw expired();
        }
        if ("REVOKED".equals(invitation.deviceStatus())) {
            auditService.denied(
                invitation.deviceId(), userId, "MEMBER_INVITE", "INVITATION", invitation.id(),
                "DEVICE_REVOKED");
            throw conflict("DEVICE_REVOKED", "해제된 기기의 초대입니다.");
        }

        UserRow user = authMapper.findUserById(userId).orElseThrow(this::notFound);
        if (!invitation.inviteeEmail().equals(normalizeEmail(user.email()))) {
            auditService.denied(
                invitation.deviceId(), userId, "MEMBER_INVITE", "INVITATION", invitation.id(),
                "INVITATION_RECIPIENT_MISMATCH");
            throw notFound();
        }
        invitationMapper.activateMember(invitation.deviceId(), userId);
        if (invitationMapper.markAccepted(invitation.id(), userId) != 1) {
            throw conflict("INVITATION_ALREADY_USED", "이미 처리된 초대입니다.");
        }
        DeviceMemberResponse response = invitationMapper.findMembership(invitation.deviceId(), userId)
            .map(this::toMember)
            .orElseThrow(this::notFound);
        auditService.success(
            invitation.deviceId(), userId, "MEMBER_INVITE", "MEMBERSHIP", response.id());
        return response;
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

    private void requireOwner(UUID userId, UUID deviceId) {
        requireOwner(userId, deviceId, null, null, null);
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

    private InvitationResponse toInvitation(InvitationRow row) {
        return new InvitationResponse(
            row.id(), row.deviceId(), row.inviteeEmail(), row.role(), row.status(),
            row.expiresAt(), row.createdAt());
    }

    private DeviceMemberResponse toMember(MembershipRow row) {
        return new DeviceMemberResponse(
            row.id(), row.deviceId(), new UserSummary(row.userId(), row.email(), row.displayName()),
            row.role(), row.status(), row.joinedAt());
    }

    private String normalizeEmail(String email) {
        return email.trim().toLowerCase(Locale.ROOT);
    }

    private String newToken() {
        byte[] bytes = new byte[32];
        SECURE_RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private String hash(String token) {
        try {
            return HexFormat.of().formatHex(
                MessageDigest.getInstance("SHA-256").digest(token.getBytes(StandardCharsets.UTF_8)));
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

    private ExpiredInvitationException expired() {
        return new ExpiredInvitationException();
    }

    private static final class ExpiredInvitationException extends ApiException {
        private ExpiredInvitationException() {
            super(HttpStatus.CONFLICT, "INVITATION_EXPIRED", "초대가 만료되었습니다.");
        }
    }
}
