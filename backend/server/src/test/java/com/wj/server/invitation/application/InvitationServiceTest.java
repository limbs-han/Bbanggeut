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
import com.wj.server.auth.domain.UserRow;
import com.wj.server.auth.persistence.AuthMapper;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.InvitationProperties;
import com.wj.server.invitation.api.AcceptInvitationRequest;
import com.wj.server.invitation.api.CreateInvitationRequest;
import com.wj.server.invitation.domain.InvitationRow;
import com.wj.server.invitation.domain.MembershipRow;
import com.wj.server.invitation.persistence.InvitationMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class InvitationServiceTest {
    private static final Instant NOW = Instant.parse("2026-07-17T10:00:00Z");

    @Mock
    private InvitationMapper invitationMapper;
    @Mock
    private AuthMapper authMapper;
    @Mock
    private AuditService auditService;
    private InvitationService service;

    @BeforeEach
    void setUp() {
        service = new InvitationService(
            invitationMapper,
            authMapper,
            new InvitationProperties(Duration.ofDays(7)),
            auditService,
            Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void ownerCreatesNormalizedSingleUseInvitation() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(invitationMapper.findActiveRole(ownerId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(invitationMapper.activeMembershipExistsByEmail(deviceId, "member@example.com")).thenReturn(false);

        var created = service.create(ownerId, deviceId, new CreateInvitationRequest("Member@Example.com"));

        assertThat(created.inviteeEmail()).isEqualTo("member@example.com");
        assertThat(created.invitationToken()).hasSizeGreaterThanOrEqualTo(32);
        assertThat(created.expiresAt()).isEqualTo(NOW.plus(Duration.ofDays(7)));
        verify(invitationMapper).insert(
            any(UUID.class), eq(deviceId), eq(ownerId), eq("member@example.com"),
            org.mockito.ArgumentMatchers.matches("^[0-9a-f]{64}$"), eq(NOW.plus(Duration.ofDays(7))));
    }

    @Test
    void memberCannotCreateInvitation() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(invitationMapper.findActiveRole(userId, deviceId)).thenReturn(Optional.of("MEMBER"));

        assertThatThrownBy(() -> service.create(userId, deviceId, new CreateInvitationRequest("a@b.com")))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> assertThat(((ApiException) exception).status().value()).isEqualTo(403));
    }

    @Test
    void correctRecipientAcceptsAndGetsMemberResponse() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID membershipId = UUID.randomUUID();
        String token = "x".repeat(32);
        InvitationRow invitation = invitation(deviceId, "member@example.com", "PENDING", NOW.plusSeconds(60));
        UserRow user = new UserRow(userId, "member@example.com", "hash", "Member", "ACTIVE", 0);
        MembershipRow membership = new MembershipRow(
            membershipId, deviceId, userId, user.email(), user.displayName(), "MEMBER", "ACTIVE", NOW);
        when(invitationMapper.lockByTokenHash(any())).thenReturn(Optional.of(invitation));
        when(authMapper.findUserById(userId)).thenReturn(Optional.of(user));
        when(invitationMapper.markAccepted(invitation.id(), userId)).thenReturn(1);
        when(invitationMapper.findMembership(deviceId, userId)).thenReturn(Optional.of(membership));

        var accepted = service.accept(userId, new AcceptInvitationRequest(token));

        assertThat(accepted.id()).isEqualTo(membershipId);
        assertThat(accepted.user().email()).isEqualTo("member@example.com");
        verify(invitationMapper).activateMember(deviceId, userId);
    }

    @Test
    void wrongRecipientGetsHiddenNotFoundAndNoMembership() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        InvitationRow invitation = invitation(deviceId, "target@example.com", "PENDING", NOW.plusSeconds(60));
        when(invitationMapper.lockByTokenHash(any())).thenReturn(Optional.of(invitation));
        when(authMapper.findUserById(userId)).thenReturn(Optional.of(
            new UserRow(userId, "other@example.com", "hash", "Other", "ACTIVE", 0)));

        assertThatThrownBy(() -> service.accept(userId, new AcceptInvitationRequest("x".repeat(32))))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("RESOURCE_NOT_FOUND");
        verify(invitationMapper, never()).activateMember(any(), any());
    }

    @Test
    void ownerCannotBeRevokedThroughMemberEndpoint() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID membershipId = UUID.randomUUID();
        when(invitationMapper.findActiveRole(ownerId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(invitationMapper.lockScopedMembership(deviceId, membershipId)).thenReturn(Optional.of(
            new MembershipRow(membershipId, deviceId, ownerId, "owner@example.com", "Owner", "OWNER", "ACTIVE", NOW)));

        assertThatThrownBy(() -> service.revokeMember(ownerId, deviceId, membershipId))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("OWNER_CANNOT_BE_REVOKED");
    }

    private InvitationRow invitation(UUID deviceId, String email, String status, Instant expiresAt) {
        return new InvitationRow(
            UUID.randomUUID(), deviceId, UUID.randomUUID(), email, "MEMBER", status,
            expiresAt, NOW.minusSeconds(10), "OFFLINE");
    }
}
