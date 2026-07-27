package com.wj.server.invitation.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.InvitationProperties;
import com.wj.server.invitation.domain.InvitationRow;
import com.wj.server.invitation.domain.MembershipRequestRow;
import com.wj.server.invitation.domain.MembershipRow;
import com.wj.server.invitation.persistence.InvitationMapper;
import com.wj.server.notification.application.NotificationService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class InvitationServiceTest {
    private static final Instant NOW = Instant.parse("2026-07-20T10:00:00Z");
    private static final Duration TTL = Duration.ofDays(7);

    @Mock
    private InvitationMapper mapper;
    @Mock
    private AuditService auditService;
    @Mock
    private MembershipRequestService membershipRequestService;
    @Mock
    private NotificationService notificationService;

    private InvitationService service;

    @BeforeEach
    void setUp() {
        service = new InvitationService(
            mapper,
            new InvitationProperties(TTL),
            auditService,
            membershipRequestService,
            notificationService,
            Clock.fixed(NOW, ZoneOffset.UTC));
    }

    private InvitationRow pendingInvitation(UUID id, UUID deviceId, UUID inviterId, String inviteeEmail, Instant expiresAt) {
        return new InvitationRow(
            id, deviceId, "Camera", inviterId, "owner@example.com", "오너",
            inviteeEmail, "MEMBER", "PENDING", expiresAt, NOW);
    }

    @Test
    void ownerInvitesEmailAndNormalizesIt() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findActiveRole(ownerId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(mapper.activeMemberEmailExists(deviceId, "member@example.com")).thenReturn(false);
        when(mapper.pendingInvitationExists(deviceId, "member@example.com")).thenReturn(false);
        when(mapper.findScopedInvitation(eq(deviceId), any()))
            .thenAnswer(invocation -> Optional.of(pendingInvitation(
                invocation.getArgument(1), deviceId, ownerId, "member@example.com", NOW.plus(TTL))));

        var response = service.createInvitation(
            ownerId, deviceId, "  Member@Example.com ", null);

        verify(mapper).insertInvitation(
            any(), eq(deviceId), eq(ownerId), eq("member@example.com"),
            eq("MEMBER"), eq(NOW.plus(TTL)));
        verify(notificationService).invitationReceived(
            eq("member@example.com"), eq(deviceId), eq("Camera"), any());
        assertThat(response.status()).isEqualTo("PENDING");
        assertThat(response.inviteeEmail()).isEqualTo("member@example.com");
    }

    @Test
    void ownerInvitationConsumesMatchingMembershipRequest() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID requesterId = UUID.randomUUID();
        String token = "opaque-request-token";
        MembershipRequestRow request = new MembershipRequestRow(
            UUID.randomUUID(), requesterId, "member@example.com", "멤버",
            NOW.plusSeconds(60), null);
        when(mapper.findActiveRole(ownerId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(membershipRequestService.requireForInvitation(
            token, "member@example.com")).thenReturn(request);
        when(mapper.findScopedInvitation(eq(deviceId), any()))
            .thenAnswer(invocation -> Optional.of(pendingInvitation(
                invocation.getArgument(1), deviceId, ownerId,
                "member@example.com", NOW.plus(TTL))));

        service.createInvitation(
            ownerId, deviceId, "member@example.com", token);

        verify(membershipRequestService).consume(
            eq(token), eq(request), eq(ownerId), any());
    }

    @Test
    void memberCannotInvite() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findActiveRole(userId, deviceId)).thenReturn(Optional.of("MEMBER"));

        assertThatThrownBy(() -> service.createInvitation(
            userId, deviceId, "member@example.com", null))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> assertThat(((ApiException) exception).status().value()).isEqualTo(403));
        verify(mapper, never()).insertInvitation(any(), any(), any(), any(), any(), any());
    }

    @Test
    void invitingAnExistingMemberConflicts() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findActiveRole(ownerId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(mapper.activeMemberEmailExists(deviceId, "member@example.com")).thenReturn(true);

        assertThatThrownBy(() -> service.createInvitation(
            ownerId, deviceId, "member@example.com", null))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("ALREADY_DEVICE_MEMBER");
        verify(mapper, never()).insertInvitation(any(), any(), any(), any(), any(), any());
    }

    @Test
    void acceptActivatesMembershipForTheInvitedEmail() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID invitationId = UUID.randomUUID();
        when(mapper.findUserEmail(userId)).thenReturn(Optional.of("member@example.com"));
        when(mapper.lockInvitation(invitationId))
            .thenReturn(Optional.of(pendingInvitation(
                invitationId, deviceId, UUID.randomUUID(), "member@example.com", NOW.plusSeconds(60))));
        when(mapper.acceptInvitation(invitationId, userId)).thenReturn(1);
        when(mapper.findMembership(deviceId, userId))
            .thenReturn(Optional.of(new MembershipRow(
                UUID.randomUUID(), deviceId, userId,
                "member@example.com", "멤버", "MEMBER", "ACTIVE", NOW)));

        var member = service.acceptInvitation(userId, invitationId);

        verify(mapper).activateMember(deviceId, userId, "MEMBER");
        assertThat(member.role()).isEqualTo("MEMBER");
        assertThat(member.status()).isEqualTo("ACTIVE");
    }

    @Test
    void acceptByAnotherEmailIsHidden() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID invitationId = UUID.randomUUID();
        when(mapper.findUserEmail(userId)).thenReturn(Optional.of("stranger@example.com"));
        when(mapper.lockInvitation(invitationId))
            .thenReturn(Optional.of(pendingInvitation(
                invitationId, deviceId, UUID.randomUUID(), "member@example.com", NOW.plusSeconds(60))));

        assertThatThrownBy(() -> service.acceptInvitation(userId, invitationId))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("RESOURCE_NOT_FOUND");
        verify(mapper, never()).acceptInvitation(any(), any());
        verify(mapper, never()).activateMember(any(), any(), any());
    }

    @Test
    void acceptExpiredInvitationConflicts() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID invitationId = UUID.randomUUID();
        when(mapper.findUserEmail(userId)).thenReturn(Optional.of("member@example.com"));
        when(mapper.lockInvitation(invitationId))
            .thenReturn(Optional.of(pendingInvitation(
                invitationId, deviceId, UUID.randomUUID(), "member@example.com", NOW.minusSeconds(1))));

        assertThatThrownBy(() -> service.acceptInvitation(userId, invitationId))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("INVITATION_EXPIRED");
        verify(mapper, never()).acceptInvitation(any(), any());
    }

    @Test
    void declineMarksInvitationWithoutMembership() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID invitationId = UUID.randomUUID();
        when(mapper.findUserEmail(userId)).thenReturn(Optional.of("member@example.com"));
        when(mapper.lockInvitation(invitationId))
            .thenReturn(Optional.of(pendingInvitation(
                invitationId, deviceId, UUID.randomUUID(), "member@example.com", NOW.plusSeconds(60))));
        when(mapper.declineInvitation(invitationId, userId)).thenReturn(1);

        service.declineInvitation(userId, invitationId);

        verify(mapper, never()).activateMember(any(), any(), any());
    }

    @Test
    void ownerMembershipCannotBeRevoked() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID membershipId = UUID.randomUUID();
        when(mapper.findActiveRole(ownerId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(mapper.lockScopedMembership(deviceId, membershipId))
            .thenReturn(Optional.of(new MembershipRow(
                membershipId, deviceId, ownerId, "owner@example.com", "오너",
                "OWNER", "ACTIVE", NOW)));

        assertThatThrownBy(() -> service.revokeMember(ownerId, deviceId, membershipId))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("OWNER_CANNOT_BE_REVOKED");
    }
}
