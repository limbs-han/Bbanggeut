package com.wj.server.subscription.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
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
import com.wj.server.config.SubscriptionProperties;
import com.wj.server.device.domain.DeviceViewRow;
import com.wj.server.device.persistence.DeviceMapper;
import com.wj.server.subscription.persistence.SubscriptionMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class SubscriptionServiceTest {
    private static final Instant NOW = Instant.parse("2026-07-20T10:00:00Z");

    @Mock
    private SubscriptionMapper subscriptionMapper;
    @Mock
    private DeviceMapper deviceMapper;
    @Mock
    private AuditService auditService;

    private SubscriptionService service;

    @BeforeEach
    void setUp() {
        service = new SubscriptionService(
            subscriptionMapper, deviceMapper,
            new SubscriptionProperties(365, Duration.ofDays(30)),
            auditService,
            Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void activationExtendsRetentionToPremiumWindow() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(deviceMapper.lockAccessibleDevice(ownerId, deviceId))
            .thenReturn(Optional.of(view(deviceId, "OWNER")));

        var response = service.activate(ownerId, deviceId);

        verify(subscriptionMapper).activate(deviceId);
        verify(subscriptionMapper).extendRetentionToPremium(deviceId, 365);
        assertThat(response.active()).isTrue();
        assertThat(response.graceUntil()).isNull();
    }

    @Test
    void cancellationKeepsGraceWindowInsteadOfDeletingImmediately() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        Instant graceUntil = NOW.plus(Duration.ofDays(30));
        when(deviceMapper.lockAccessibleDevice(ownerId, deviceId))
            .thenReturn(Optional.of(view(deviceId, "OWNER")));
        when(subscriptionMapper.cancel(deviceId, graceUntil)).thenReturn(1);

        var response = service.cancel(ownerId, deviceId);

        verify(subscriptionMapper).resetRetentionToBaseline(deviceId, graceUntil);
        assertThat(response.active()).isFalse();
        assertThat(response.graceUntil()).isEqualTo(graceUntil);
    }

    @Test
    void cancellingInactiveSubscriptionConflicts() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(deviceMapper.lockAccessibleDevice(ownerId, deviceId))
            .thenReturn(Optional.of(view(deviceId, "OWNER")));
        when(subscriptionMapper.cancel(any(), any())).thenReturn(0);

        assertThatThrownBy(() -> service.cancel(ownerId, deviceId))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("SUBSCRIPTION_NOT_ACTIVE");
        verify(subscriptionMapper, never()).resetRetentionToBaseline(any(), any());
    }

    @Test
    void editorCannotChangeSubscription() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(deviceMapper.lockAccessibleDevice(userId, deviceId))
            .thenReturn(Optional.of(view(deviceId, "MEMBER")));

        assertThatThrownBy(() -> service.activate(userId, deviceId))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> assertThat(((ApiException) exception).status().value()).isEqualTo(403));
        verify(subscriptionMapper, never()).activate(any());
    }

    @Test
    void vaultOwnerActivatesSubscriptionWithoutAnyConnectedDevice() {
        UUID ownerId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        when(subscriptionMapper.lockVaultRole(ownerId, vaultId))
            .thenReturn(Optional.of("OWNER"));

        var response = service.activateForVault(ownerId, vaultId);

        verify(subscriptionMapper).activateVault(vaultId);
        verify(subscriptionMapper).extendVaultRetentionToPremium(vaultId, 365);
        assertThat(response.vaultId()).isEqualTo(vaultId);
        assertThat(response.deviceId()).isNull();
        assertThat(response.active()).isTrue();
    }

    @Test
    void vaultCancellationKeepsGraceWindow() {
        UUID ownerId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        Instant graceUntil = NOW.plus(Duration.ofDays(30));
        when(subscriptionMapper.lockVaultRole(ownerId, vaultId))
            .thenReturn(Optional.of("OWNER"));
        when(subscriptionMapper.cancelVault(vaultId, graceUntil)).thenReturn(1);

        var response = service.cancelForVault(ownerId, vaultId);

        verify(subscriptionMapper).resetVaultRetentionToBaseline(vaultId, graceUntil);
        assertThat(response.active()).isFalse();
        assertThat(response.graceUntil()).isEqualTo(graceUntil);
    }

    @Test
    void vaultMemberCannotChangeSubscription() {
        UUID userId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        when(subscriptionMapper.lockVaultRole(userId, vaultId))
            .thenReturn(Optional.of("MEMBER"));

        assertThatThrownBy(() -> service.activateForVault(userId, vaultId))
            .isInstanceOf(ApiException.class)
            .satisfies(exception ->
                assertThat(((ApiException) exception).status().value()).isEqualTo(403));
        verify(subscriptionMapper, never()).activateVault(any());
    }

    private DeviceViewRow view(UUID deviceId, String role) {
        return new DeviceViewRow(
            deviceId, "거실", "WJ-DEV-01", "OFFLINE", role, 30,
            null, "WJ-0001", null, NOW, true);
    }
}
