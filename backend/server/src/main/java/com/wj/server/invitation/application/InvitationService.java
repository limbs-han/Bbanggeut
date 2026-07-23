package com.wj.server.invitation.application;

import java.time.Clock;
import java.util.List;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.auth.api.UserSummary;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.InvitationProperties;
import com.wj.server.invitation.api.DeviceMemberResponse;
import com.wj.server.invitation.api.InvitationResponse;
import com.wj.server.invitation.domain.InvitationRow;
import com.wj.server.invitation.domain.MembershipRow;
import com.wj.server.invitation.persistence.InvitationMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Invite flow: the OWNER invites a specific email address, and only the account
 * that owns that email can accept the invitation in-app to become a MEMBER. A
 * home camera is shared with named people, never through a link that can leak.
 */
@Service
public class InvitationService {
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

    /** OWNER invites an email; the invitation stays PENDING until that account acts. */
    @Transactional
    public InvitationResponse createInvitation(UUID userId, UUID deviceId, String email) {
        requireOwner(userId, deviceId, "MEMBER_INVITE", "INVITATION", null);
        String inviteeEmail = normalizeEmail(email);
        if (invitationMapper.activeMemberEmailExists(deviceId, inviteeEmail)) {
            throw conflict("ALREADY_DEVICE_MEMBER", "이미 이 기기의 구성원입니다.");
        }
        if (invitationMapper.pendingInvitationExists(deviceId, inviteeEmail)) {
            throw conflict("INVITATION_PENDING", "이미 대기 중인 초대가 있습니다.");
        }
        UUID invitationId = UUID.randomUUID();
        invitationMapper.insertInvitation(
            invitationId, deviceId, userId, inviteeEmail, clock.instant().plus(properties.ttl()));
        InvitationRow row = invitationMapper.findScopedInvitation(deviceId, invitationId)
            .orElseThrow(this::notFound);
        auditService.success(deviceId, userId, "MEMBER_INVITE", "INVITATION", invitationId);
        return toInvitation(row);
    }

    /** OWNER lists still-pending invitations for the device. */
    @Transactional(readOnly = true)
    public List<InvitationResponse> listDeviceInvitations(UUID userId, UUID deviceId) {
        requireOwner(userId, deviceId, null, null, null);
        return invitationMapper.findDeviceInvitations(deviceId).stream().map(this::toInvitation).toList();
    }

    /** OWNER withdraws a pending invitation before it is accepted. */
    @Transactional
    public void revokeInvitation(UUID userId, UUID deviceId, UUID invitationId) {
        requireOwner(userId, deviceId, "MEMBER_INVITE", "INVITATION", invitationId);
        if (invitationMapper.revokeInvitation(deviceId, invitationId, userId) != 1) {
            throw conflict("INVITATION_NOT_PENDING", "대기 중인 초대만 취소할 수 있습니다.");
        }
        auditService.success(deviceId, userId, "MEMBER_INVITE", "INVITATION", invitationId);
    }

    /** The invited account lists the invitations addressed to its email. */
    @Transactional(readOnly = true)
    public List<InvitationResponse> listMyInvitations(UUID userId) {
        String email = invitationMapper.findUserEmail(userId).orElseThrow(this::notFound);
        return invitationMapper.findReceivedInvitations(email).stream().map(this::toInvitation).toList();
    }

    /** The invited account accepts and becomes a MEMBER. */
    @Transactional
    public DeviceMemberResponse acceptInvitation(UUID userId, UUID invitationId) {
        String email = invitationMapper.findUserEmail(userId).orElseThrow(this::notFound);
        InvitationRow invitation = invitationMapper.lockInvitation(invitationId).orElseThrow(this::notFound);
        if (!invitation.inviteeEmail().equalsIgnoreCase(email)) {
            throw notFound();
        }
        if (!invitation.expiresAt().isAfter(clock.instant())) {
            throw conflict("INVITATION_EXPIRED", "만료된 초대입니다.");
        }
        if (invitationMapper.acceptInvitation(invitationId, userId) != 1) {
            throw conflict("INVITATION_NOT_PENDING", "대기 중인 초대만 수락할 수 있습니다.");
        }
        invitationMapper.activateMember(invitation.deviceId(), userId);
        DeviceMemberResponse response = invitationMapper.findMembership(invitation.deviceId(), userId)
            .map(this::toMember)
            .orElseThrow(this::notFound);
        auditService.success(invitation.deviceId(), userId, "MEMBER_INVITE", "MEMBERSHIP", response.id());
        return response;
    }

    /** The invited account declines the invitation. */
    @Transactional
    public void declineInvitation(UUID userId, UUID invitationId) {
        String email = invitationMapper.findUserEmail(userId).orElseThrow(this::notFound);
        InvitationRow invitation = invitationMapper.lockInvitation(invitationId).orElseThrow(this::notFound);
        if (!invitation.inviteeEmail().equalsIgnoreCase(email)) {
            throw notFound();
        }
        if (invitationMapper.declineInvitation(invitationId, userId) != 1) {
            throw conflict("INVITATION_NOT_PENDING", "대기 중인 초대만 거절할 수 있습니다.");
        }
        auditService.success(invitation.deviceId(), userId, "MEMBER_INVITE", "INVITATION", invitationId);
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

    private InvitationResponse toInvitation(InvitationRow row) {
        UserSummary inviter = row.inviterId() == null
            ? null
            : new UserSummary(row.inviterId(), row.inviterEmail(), row.inviterDisplayName());
        return new InvitationResponse(
            row.id(), row.deviceId(), row.deviceName(), row.inviteeEmail(),
            inviter, row.status(), row.expiresAt(), row.createdAt());
    }

    private DeviceMemberResponse toMember(MembershipRow row) {
        return new DeviceMemberResponse(
            row.id(), row.deviceId(), new UserSummary(row.userId(), row.email(), row.displayName()),
            row.role(), row.status(), row.joinedAt());
    }

    private String normalizeEmail(String email) {
        return email == null ? "" : email.trim().toLowerCase();
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }

    private ApiException conflict(String code, String message) {
        return new ApiException(HttpStatus.CONFLICT, code, message);
    }
}
