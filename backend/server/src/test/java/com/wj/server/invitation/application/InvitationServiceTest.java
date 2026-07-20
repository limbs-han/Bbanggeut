package com.wj.server.invitation.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
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
import com.wj.server.invitation.api.CreateJoinRequestRequest;
import com.wj.server.invitation.domain.InviteLinkRow;
import com.wj.server.invitation.domain.JoinRequestRow;
import com.wj.server.invitation.domain.MembershipRow;
import com.wj.server.invitation.persistence.InvitationMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class InvitationServiceTest {
    private static final Instant NOW = Instant.parse("2026-07-20T10:00:00Z");

    @Mock
    private InvitationMapper mapper;
    @Mock
    private AuditService auditService;

    private InvitationService service;

    @BeforeEach
    void setUp() {
        service = new InvitationService(
            mapper,
            new InvitationProperties(Duration.ofDays(7)),
            auditService,
            Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void ownerRotatesInviteLinkAndPlaintextTokenIsReturnedOnce() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findActiveRole(ownerId, deviceId)).thenReturn(Optional.of("OWNER"));

        var response = service.createInviteLink(ownerId, deviceId);

        verify(mapper).revokeActiveLinks(deviceId);
        verify(mapper).insertLink(any(), eq(deviceId), anyString(), eq(ownerId), eq(NOW.plus(Duration.ofDays(7))));
        assertThat(response.inviteToken()).isNotBlank();
        assertThat(response.expiresAt()).isEqualTo(NOW.plus(Duration.ofDays(7)));
    }

    @Test
    void memberCannotCreateInviteLink() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findActiveRole(userId, deviceId)).thenReturn(Optional.of("MEMBER"));

        assertThatThrownBy(() -> service.createInviteLink(userId, deviceId))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> assertThat(((ApiException) exception).status().value()).isEqualTo(403));
        verify(mapper, never()).insertLink(any(), any(), anyString(), any(), any());
    }

    @Test
    void expiredOrRevokedLinkHidesResourceOnJoinRequest() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findLinkByTokenHash(anyString()))
            .thenReturn(Optional.of(new InviteLinkRow(
                UUID.randomUUID(), deviceId, NOW, null, "OFFLINE")));

        assertThatThrownBy(() -> service.createJoinRequest(
            userId, new CreateJoinRequestRequest("token-value-1234")))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("RESOURCE_NOT_FOUND");
        verify(mapper, never()).insertJoinRequest(any(), any(), any());
    }

    @Test
    void validLinkCreatesPendingJoinRequest() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findLinkByTokenHash(anyString()))
            .thenReturn(Optional.of(new InviteLinkRow(
                UUID.randomUUID(), deviceId, NOW.plusSeconds(60), null, "OFFLINE")));
        when(mapper.activeMembershipExists(deviceId, userId)).thenReturn(false);
        when(mapper.pendingJoinRequestExists(deviceId, userId)).thenReturn(false);
        when(mapper.lockScopedJoinRequest(eq(deviceId), any()))
            .thenAnswer(invocation -> Optional.of(new JoinRequestRow(
                invocation.getArgument(1), deviceId, userId,
                "member@example.com", "멤버", "PENDING", NOW)));

        var response = service.createJoinRequest(
            userId, new CreateJoinRequestRequest("token-value-1234"));

        verify(mapper).insertJoinRequest(any(), eq(deviceId), eq(userId));
        assertThat(response.status()).isEqualTo("PENDING");
        assertThat(response.requester().email()).isEqualTo("member@example.com");
    }

    @Test
    void approvalActivatesMembership() {
        UUID ownerId = UUID.randomUUID();
        UUID requesterId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID requestId = UUID.randomUUID();
        when(mapper.findActiveRole(ownerId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(mapper.lockScopedJoinRequest(deviceId, requestId))
            .thenReturn(Optional.of(new JoinRequestRow(
                requestId, deviceId, requesterId, "member@example.com", "멤버", "PENDING", NOW)));
        when(mapper.decideJoinRequest(requestId, "APPROVED", ownerId)).thenReturn(1);
        when(mapper.findMembership(deviceId, requesterId))
            .thenReturn(Optional.of(new MembershipRow(
                UUID.randomUUID(), deviceId, requesterId,
                "member@example.com", "멤버", "MEMBER", "ACTIVE", NOW)));

        var member = service.approveJoinRequest(ownerId, deviceId, requestId);

        verify(mapper).activateMember(deviceId, requesterId);
        assertThat(member.role()).isEqualTo("MEMBER");
        assertThat(member.status()).isEqualTo("ACTIVE");
    }

    @Test
    void rejectionDoesNotCreateMembership() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID requestId = UUID.randomUUID();
        when(mapper.findActiveRole(ownerId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(mapper.lockScopedJoinRequest(deviceId, requestId))
            .thenReturn(Optional.of(new JoinRequestRow(
                requestId, deviceId, UUID.randomUUID(),
                "member@example.com", "멤버", "PENDING", NOW)));
        when(mapper.decideJoinRequest(requestId, "REJECTED", ownerId)).thenReturn(1);

        service.rejectJoinRequest(ownerId, deviceId, requestId);

        verify(mapper, never()).activateMember(any(), any());
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
