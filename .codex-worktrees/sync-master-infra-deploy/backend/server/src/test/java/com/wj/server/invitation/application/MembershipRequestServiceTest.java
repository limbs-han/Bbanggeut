package com.wj.server.invitation.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.invitation.domain.MembershipRequestRow;
import com.wj.server.invitation.persistence.MembershipRequestMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class MembershipRequestServiceTest {
    private static final Instant NOW = Instant.parse("2026-07-26T12:00:00Z");

    @Mock
    private MembershipRequestMapper mapper;

    @Test
    void requesterCreatesOpaqueSingleUseLink() {
        UUID requesterId = UUID.randomUUID();
        var service = service();

        var response = service.create(requesterId);

        assertThat(response.token()).hasSize(43).doesNotContain("@");
        assertThat(response.expiresAt()).isEqualTo(NOW.plus(MembershipRequestService.LINK_TTL));
        verify(mapper).revokeActiveLinks(requesterId);
        verify(mapper).insert(
            any(), eq(requesterId),
            argThat(hash -> hash.matches("[0-9a-f]{64}")),
            eq(response.expiresAt()));
    }

    @Test
    void onlyAnOwnerCanPreviewRequesterEmail() {
        UUID ownerId = UUID.randomUUID();
        when(mapper.hasActiveOwnerMembership(ownerId)).thenReturn(false);

        assertThatThrownBy(() -> service().preview(ownerId, "opaque-token"))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("OWNER_MEMBERSHIP_REQUIRED");
    }

    @Test
    void consumedLinkMustMatchInvitationEmail() {
        String token = "opaque-token";
        UUID requesterId = UUID.randomUUID();
        when(mapper.findActive(any())).thenReturn(Optional.of(new MembershipRequestRow(
            UUID.randomUUID(), requesterId, "member@example.com", "멤버",
            NOW.plusSeconds(60), null)));

        assertThatThrownBy(() ->
            service().requireForInvitation(token, "someone@example.com"))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("MEMBERSHIP_REQUEST_EMAIL_MISMATCH");
    }

    private MembershipRequestService service() {
        return new MembershipRequestService(
            mapper, Clock.fixed(NOW, ZoneOffset.UTC));
    }
}
