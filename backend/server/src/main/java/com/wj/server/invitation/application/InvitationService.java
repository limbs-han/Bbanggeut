package com.wj.server.invitation.application;

import java.time.Clock;
import java.util.List;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.auth.api.UserSummary;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.InvitationProperties;
import com.wj.server.device.api.TransferOwnershipRequest;
import com.wj.server.invitation.api.DeviceMemberResponse;
import com.wj.server.invitation.api.InvitationResponse;
import com.wj.server.invitation.domain.InvitationRow;
import com.wj.server.invitation.domain.MembershipRequestRow;
import com.wj.server.invitation.domain.MembershipRow;
import com.wj.server.invitation.persistence.InvitationMapper;
import com.wj.server.notification.application.NotificationService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Invite flow: the OWNER invites a specific email address, and only the account
 * that owns that email can accept the invitation in-app as a MEMBER. A
 * home camera is shared with named people, never through a link that can leak.
 */
@Service
public class InvitationService {
    private final InvitationMapper invitationMapper;
    private final InvitationProperties properties;
    private final AuditService auditService;
    private final MembershipRequestService membershipRequestService;
    private final NotificationService notificationService;
    private final Clock clock;

    @Autowired
    public InvitationService(
        InvitationMapper invitationMapper,
        InvitationProperties properties,
        AuditService auditService,
        MembershipRequestService membershipRequestService,
        NotificationService notificationService
    ) {
        this(invitationMapper, properties, auditService,
            membershipRequestService, notificationService, Clock.systemUTC());
    }

    InvitationService(
        InvitationMapper invitationMapper,
        InvitationProperties properties,
        AuditService auditService,
        MembershipRequestService membershipRequestService,
        NotificationService notificationService,
        Clock clock
    ) {
        this.invitationMapper = invitationMapper;
        this.properties = properties;
        this.auditService = auditService;
        this.membershipRequestService = membershipRequestService;
        this.notificationService = notificationService;
        this.clock = clock;
    }

    /** OWNER invites an email; the invitation stays PENDING until that account acts. */
    @Transactional
    public InvitationResponse createInvitation(
        UUID userId,
        UUID deviceId,
        String email,
        String membershipRequestToken
    ) {
        requireOwner(userId, deviceId, "MEMBER_INVITE", "INVITATION", null);
        String inviteeEmail = normalizeEmail(email);
        if (!invitationMapper.activeUserEmailExists(inviteeEmail)) {
            throw new ApiException(
                HttpStatus.NOT_FOUND,
                "INVITEE_ACCOUNT_NOT_FOUND",
                "가입된 사용자 이메일을 찾을 수 없습니다.");
        }
        MembershipRequestRow membershipRequest = membershipRequestToken == null
            || membershipRequestToken.isBlank()
            ? null
            : membershipRequestService.requireForInvitation(
                membershipRequestToken, inviteeEmail);
        if (invitationMapper.activeMemberEmailExists(deviceId, inviteeEmail)) {
            throw conflict("ALREADY_DEVICE_MEMBER", "이미 이 기기의 구성원입니다.");
        }
        if (invitationMapper.pendingInvitationExists(deviceId, inviteeEmail)) {
            throw conflict("INVITATION_PENDING", "이미 대기 중인 초대가 있습니다.");
        }
        UUID invitationId = UUID.randomUUID();
        invitationMapper.insertInvitation(
            invitationId, deviceId, userId, inviteeEmail, "MEMBER",
            clock.instant().plus(properties.ttl()));
        if (membershipRequest != null) {
            membershipRequestService.consume(
                membershipRequestToken, membershipRequest, userId, invitationId);
        }
        InvitationRow row = invitationMapper.findScopedInvitation(deviceId, invitationId)
            .orElseThrow(this::notFound);
        notificationService.invitationReceived(
            inviteeEmail, deviceId, row.deviceName(), invitationId);
        auditService.success(deviceId, userId, "MEMBER_INVITE", "INVITATION", invitationId);
        return toInvitation(row);
    }

    /** OWNER invites an account to a vault, including an archived vault with no device. */
    @Transactional
    public InvitationResponse createVaultInvitation(
        UUID userId,
        UUID vaultId,
        String email,
        String membershipRequestToken
    ) {
        requireVaultOwner(userId, vaultId, "MEMBER_INVITE", "INVITATION", null);
        String inviteeEmail = normalizeEmail(email);
        if (!invitationMapper.activeUserEmailExists(inviteeEmail)) {
            throw new ApiException(
                HttpStatus.NOT_FOUND,
                "INVITEE_ACCOUNT_NOT_FOUND",
                "가입된 사용자 이메일을 찾을 수 없습니다.");
        }
        MembershipRequestRow membershipRequest = membershipRequestToken == null
            || membershipRequestToken.isBlank()
            ? null
            : membershipRequestService.requireForInvitation(
                membershipRequestToken, inviteeEmail);
        if (invitationMapper.activeVaultMemberEmailExists(vaultId, inviteeEmail)) {
            throw conflict("ALREADY_VAULT_MEMBER", "이미 이 Vault의 구성원입니다.");
        }
        if (invitationMapper.pendingVaultInvitationExists(vaultId, inviteeEmail)) {
            throw conflict("INVITATION_PENDING", "이미 대기 중인 초대가 있습니다.");
        }

        UUID invitationId = UUID.randomUUID();
        UUID deviceId = invitationMapper.findFirstActiveDeviceId(vaultId).orElse(null);
        invitationMapper.insertVaultInvitation(
            invitationId, vaultId, deviceId, userId, inviteeEmail,
            clock.instant().plus(properties.ttl()));
        if (membershipRequest != null) {
            membershipRequestService.consume(
                membershipRequestToken, membershipRequest, userId, invitationId);
        }
        InvitationRow row = invitationMapper
            .findScopedVaultInvitation(vaultId, invitationId)
            .orElseThrow(this::notFound);
        notificationService.vaultInvitationReceived(
            inviteeEmail, vaultId, row.vaultName(), invitationId);
        auditService.successForVault(
            vaultId, deviceId, userId, "MEMBER_INVITE", "INVITATION",
            invitationId);
        return toInvitation(row);
    }

    /** OWNER lists still-pending invitations for the device. */
    @Transactional(readOnly = true)
    public List<InvitationResponse> listDeviceInvitations(UUID userId, UUID deviceId) {
        requireOwner(userId, deviceId, null, null, null);
        return invitationMapper.findDeviceInvitations(deviceId).stream().map(this::toInvitation).toList();
    }

    @Transactional(readOnly = true)
    public List<InvitationResponse> listVaultInvitations(UUID userId, UUID vaultId) {
        requireVaultOwner(userId, vaultId, null, null, null);
        return invitationMapper.findVaultInvitations(vaultId).stream()
            .map(this::toInvitation)
            .toList();
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

    @Transactional
    public void revokeVaultInvitation(
        UUID userId,
        UUID vaultId,
        UUID invitationId
    ) {
        UUID deviceId = invitationMapper.findFirstActiveDeviceId(vaultId).orElse(null);
        requireVaultOwner(
            userId, vaultId, "MEMBER_INVITE", "INVITATION", invitationId);
        if (invitationMapper.revokeVaultInvitation(
            vaultId, invitationId, userId) != 1) {
            throw conflict(
                "INVITATION_NOT_PENDING", "대기 중인 초대만 취소할 수 있습니다.");
        }
        auditService.successForVault(
            vaultId, deviceId, userId, "MEMBER_INVITE", "INVITATION",
            invitationId);
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
        DeviceMemberResponse response;
        if (invitation.vaultId() != null) {
            invitationMapper.activateVaultMemberByVault(invitation.vaultId(), userId);
            invitationMapper.activateMemberForVaultDevices(
                invitation.vaultId(), userId);
            response = invitationMapper
                .findVaultMembership(invitation.vaultId(), userId)
                .map(this::toMember)
                .orElseThrow(this::notFound);
        } else {
            invitationMapper.activateMember(invitation.deviceId(), userId, "MEMBER");
            invitationMapper.activateVaultMember(invitation.deviceId(), userId, "MEMBER");
            response = invitationMapper.findMembership(invitation.deviceId(), userId)
                .map(this::toMember)
                .orElseThrow(this::notFound);
        }
        // 초대를 보낸 사람에게 수락 소식을 알린다. 알림은 초대자가 이미
        // 탈퇴했으면 조용히 건너뛴다.
        String memberName =
            response.user() != null
                && response.user().displayName() != null
                && !response.user().displayName().isBlank()
            ? response.user().displayName()
            : email;
        notificationService.invitationAccepted(
            invitation.inviterId(), memberName,
            invitation.deviceId(), invitation.vaultId(), invitation.id());
        auditInvitationSuccess(
            invitation, userId, "MEMBERSHIP", response.id());
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
        auditInvitationSuccess(
            invitation, userId, "INVITATION", invitationId);
    }

    @Transactional(readOnly = true)
    public List<DeviceMemberResponse> listMembers(UUID userId, UUID deviceId) {
        requireMember(userId, deviceId);
        return invitationMapper.findActiveMembers(deviceId).stream().map(this::toMember).toList();
    }

    @Transactional(readOnly = true)
    public List<DeviceMemberResponse> listVaultMembers(UUID userId, UUID vaultId) {
        requireVaultMember(userId, vaultId);
        return invitationMapper.findActiveVaultMembers(vaultId).stream()
            .map(this::toMember)
            .toList();
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
            throw conflict("MEMBERSHIP_NOT_ACTIVE", "활성 MEMBER만 회수할 수 있습니다.");
        }
        invitationMapper.revokeVaultMember(deviceId, target.userId(), userId);
        auditService.success(deviceId, userId, "MEMBER_REVOKE", "MEMBERSHIP", membershipId);
    }

    @Transactional
    public void revokeVaultMember(
        UUID userId,
        UUID vaultId,
        UUID membershipId
    ) {
        UUID deviceId = invitationMapper.findFirstActiveDeviceId(vaultId).orElse(null);
        requireVaultOwner(
            userId, vaultId, "MEMBER_REVOKE", "MEMBERSHIP", membershipId);
        MembershipRow target = invitationMapper
            .lockScopedVaultMembership(vaultId, membershipId)
            .orElseThrow(this::notFound);
        if ("OWNER".equals(target.role())) {
            auditService.deniedForVault(
                vaultId, deviceId, userId, "MEMBER_REVOKE", "MEMBERSHIP",
                membershipId, "OWNER_CANNOT_BE_REVOKED");
            throw conflict(
                "OWNER_CANNOT_BE_REVOKED",
                "OWNER는 내보낼 수 없습니다. 먼저 소유권을 양도해 주세요.");
        }
        if (!"ACTIVE".equals(target.status())
            || invitationMapper.revokeVaultMembership(
                vaultId, membershipId, userId) != 1) {
            throw conflict(
                "MEMBERSHIP_NOT_ACTIVE", "활성 MEMBER만 내보낼 수 있습니다.");
        }
        invitationMapper.revokeMemberFromVaultDevices(
            vaultId, target.userId(), userId);
        auditService.successForVault(
            vaultId, deviceId, userId, "MEMBER_REVOKE", "MEMBERSHIP",
            membershipId);
    }

    @Transactional
    public void transferVaultOwnership(
        UUID userId,
        UUID vaultId,
        TransferOwnershipRequest request
    ) {
        UUID deviceId = invitationMapper.findFirstActiveDeviceId(vaultId).orElse(null);
        requireVaultOwner(
            userId, vaultId, "VAULT_UPDATE", "MEMBERSHIP",
            request.newOwnerMembershipId());
        MembershipRow target = invitationMapper
            .lockScopedVaultMembership(vaultId, request.newOwnerMembershipId())
            .orElseThrow(this::notFound);
        if (target.userId().equals(userId)) {
            throw conflict("ALREADY_OWNER", "이미 본인이 OWNER입니다.");
        }
        if (!"MEMBER".equals(target.role())
            || !"ACTIVE".equals(target.status())
            || invitationMapper.demoteVaultOwner(vaultId, userId) != 1
            || invitationMapper.promoteVaultMember(vaultId, target.id()) != 1) {
            throw conflict(
                "TRANSFER_TARGET_NOT_ACTIVE_MEMBER",
                "같은 Vault의 활성 MEMBER에게만 소유권을 양도할 수 있습니다.");
        }
        invitationMapper.syncVaultOwnerToDevices(
            vaultId, userId, target.userId());
        auditService.successForVault(
            vaultId, deviceId, userId, "VAULT_UPDATE", "MEMBERSHIP",
            target.id());
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

    private void requireVaultOwner(
        UUID userId,
        UUID vaultId,
        String action,
        String targetType,
        UUID targetId
    ) {
        String role = invitationMapper.findActiveVaultRole(userId, vaultId)
            .orElseThrow(this::notFound);
        if (!"OWNER".equals(role)) {
            if (action != null) {
                UUID deviceId = invitationMapper
                    .findFirstActiveDeviceId(vaultId)
                    .orElse(null);
                auditService.deniedForVault(
                    vaultId, deviceId, userId, action, targetType, targetId,
                    "FORBIDDEN_ROLE");
            }
            throw new ApiException(
                HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE",
                "OWNER 권한이 필요합니다.");
        }
    }

    private void requireVaultMember(UUID userId, UUID vaultId) {
        invitationMapper.findActiveVaultRole(userId, vaultId)
            .orElseThrow(this::notFound);
    }

    private void auditInvitationSuccess(
        InvitationRow invitation,
        UUID userId,
        String targetType,
        UUID targetId
    ) {
        if (invitation.vaultId() == null) {
            auditService.success(
                invitation.deviceId(), userId, "MEMBER_INVITE",
                targetType, targetId);
            return;
        }
        auditService.successForVault(
            invitation.vaultId(), invitation.deviceId(), userId,
            "MEMBER_INVITE", targetType, targetId);
    }

    private InvitationResponse toInvitation(InvitationRow row) {
        UserSummary inviter = row.inviterId() == null
            ? null
            : new UserSummary(row.inviterId(), row.inviterEmail(), row.inviterDisplayName());
        return new InvitationResponse(
            row.id(), row.deviceId(), row.deviceName(), row.inviteeEmail(),
            row.role(), inviter, row.status(), row.expiresAt(), row.createdAt(),
            row.vaultId(), row.vaultName());
    }

    private DeviceMemberResponse toMember(MembershipRow row) {
        return new DeviceMemberResponse(
            row.id(), row.deviceId(), new UserSummary(row.userId(), row.email(), row.displayName()),
            row.role(), row.status(), row.joinedAt(), row.vaultId());
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

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }
}
