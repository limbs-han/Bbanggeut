package com.wj.server.device.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.device.api.ClaimDeviceRequest;
import com.wj.server.device.api.UpdateDeviceRequest;
import com.wj.server.device.domain.DeviceRow;
import com.wj.server.device.domain.DeviceStatusRow;
import com.wj.server.device.domain.DeviceViewRow;
import com.wj.server.device.persistence.DeviceMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class DeviceServiceTest {
    private static final Instant NOW = Instant.parse("2026-07-17T10:00:00Z");

    @Mock
    private DeviceMapper deviceMapper;
    @Mock
    private ClaimAttemptService claimAttemptService;
    @Mock
    private AuditService auditService;

    private ProductCodeHasher productCodeHasher;
    private DeviceService deviceService;

    @BeforeEach
    void setUp() {
        productCodeHasher = new ProductCodeHasher();
        deviceService = new DeviceService(
            deviceMapper, productCodeHasher, claimAttemptService, auditService,
            Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void claimCreatesOwnerAndReturnsOfflineDevice() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        String productCode = "ABCD-1234";
        DeviceRow candidate = candidate(deviceId, productCode, NOW.plusSeconds(30));
        DeviceViewRow claimed = new DeviceViewRow(
            deviceId, "거실", "WJ-DEV-01", "OFFLINE", "OWNER", 30,
            null, "WJ-0001", null, NOW);
        when(deviceMapper.findClaimCandidateForUpdate("WJ-0001")).thenReturn(Optional.of(candidate));
        when(deviceMapper.markClaimed(deviceId, userId, "거실")).thenReturn(1);
        when(deviceMapper.insertOwnerMembership(deviceId, userId)).thenReturn(1);
        when(deviceMapper.findAccessibleDevice(userId, deviceId)).thenReturn(Optional.of(claimed));

        var response = deviceService.claim(
            userId, new ClaimDeviceRequest(" WJ-0001 ", "abcd-1234", " 거실 "), "127.0.0.1");

        verify(deviceMapper).markClaimed(deviceId, userId, "거실");
        verify(deviceMapper).insertOwnerMembership(deviceId, userId);
        verify(claimAttemptService).recordSuccess(userId, " WJ-0001 ", "127.0.0.1");
        assertThat(response.status()).isEqualTo("OFFLINE");
        assertThat(response.myRole()).isEqualTo("OWNER");
        assertThat(response.name()).isEqualTo("거실");
    }

    @Test
    void claimRejectsExpiredRegistrationModeWithoutChangingDevice() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(deviceMapper.findClaimCandidateForUpdate("WJ-0001"))
            .thenReturn(Optional.of(candidate(deviceId, "ABCD-1234", NOW)));

        assertThatThrownBy(() -> deviceService.claim(
            userId, new ClaimDeviceRequest("WJ-0001", "ABCD-1234", null), "127.0.0.1"))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("DEVICE_CLAIM_REJECTED");

        verify(deviceMapper, never()).markClaimed(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any(),
            org.mockito.ArgumentMatchers.any());
        verify(deviceMapper, never()).insertOwnerMembership(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any());
        verify(claimAttemptService).recordFailure(userId, "WJ-0001", "127.0.0.1");
    }

    @Test
    void inaccessibleDeviceIsHiddenAsNotFound() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(deviceMapper.findAccessibleDevice(userId, deviceId)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> deviceService.get(userId, deviceId))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> {
                ApiException apiException = (ApiException) exception;
                assertThat(apiException.status().value()).isEqualTo(404);
                assertThat(apiException.code()).isEqualTo("RESOURCE_NOT_FOUND");
            });
    }

    @Test
    void ownerUpdatesNameAndRetentionDays() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        DeviceViewRow before = view(deviceId, "Before", "OFFLINE", "OWNER");
        DeviceViewRow after = new DeviceViewRow(
            deviceId, "After", "WJ-DEV-01", "OFFLINE", "OWNER", 90,
            null, "WJ-0001", null, NOW);
        UpdateDeviceRequest request = new UpdateDeviceRequest();
        request.setName("  After  ");
        request.setRetentionDays(90);
        when(deviceMapper.lockAccessibleDevice(userId, deviceId)).thenReturn(Optional.of(before));
        when(deviceMapper.findAccessibleDevice(userId, deviceId)).thenReturn(Optional.of(after));

        var response = deviceService.update(userId, deviceId, request);

        verify(deviceMapper).updateSettings(deviceId, true, "After", true, 90);
        assertThat(response.name()).isEqualTo("After");
        assertThat(response.retentionDays()).isEqualTo(90);
    }

    @Test
    void memberCannotUpdateDeviceSettings() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UpdateDeviceRequest request = new UpdateDeviceRequest();
        request.setName("New name");
        when(deviceMapper.lockAccessibleDevice(userId, deviceId))
            .thenReturn(Optional.of(view(deviceId, "Before", "OFFLINE", "MEMBER")));

        assertThatThrownBy(() -> deviceService.update(userId, deviceId, request))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> assertThat(((ApiException) exception).status().value()).isEqualTo(403));
        verify(deviceMapper, never()).updateSettings(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyBoolean(),
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyBoolean(),
            org.mockito.ArgumentMatchers.any());
    }

    @Test
    void statusMarksStaleOnlineDeviceOfflineBeforeReturningTelemetry() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(deviceMapper.findAccessibleDevice(userId, deviceId))
            .thenReturn(Optional.of(view(deviceId, "Camera", "ONLINE", "MEMBER")));
        when(deviceMapper.findAccessibleStatus(userId, deviceId))
            .thenReturn(Optional.of(new DeviceStatusRow(deviceId, "OFFLINE", false, 2, 120)));

        var response = deviceService.status(userId, deviceId);

        verify(deviceMapper).markOfflineIfStale(deviceId);
        assertThat(response.status()).isEqualTo("OFFLINE");
        assertThat(response.uploadQueueDepth()).isEqualTo(2);
        assertThat(response.checkedAt()).isEqualTo(NOW);
    }

    @Test
    void ownerRevocationDisablesDeviceCredentialsInvitationsAndMemberships() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(deviceMapper.lockAccessibleDevice(ownerId, deviceId))
            .thenReturn(Optional.of(view(deviceId, "Camera", "OFFLINE", "OWNER")));
        when(deviceMapper.markRevoked(deviceId)).thenReturn(1);

        deviceService.revoke(ownerId, deviceId);

        verify(deviceMapper).revokeActiveCredentials(deviceId);
        verify(deviceMapper).revokePendingInvitations(deviceId);
        verify(deviceMapper).revokeAllMemberships(deviceId, ownerId);
    }

    @Test
    void emptyDevicePatchIsRejected() {
        assertThatThrownBy(() -> deviceService.update(
            UUID.randomUUID(), UUID.randomUUID(), new UpdateDeviceRequest()))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("VALIDATION_FAILED");
    }

    private DeviceRow candidate(UUID deviceId, String productCode, Instant registrationExpiresAt) {
        return new DeviceRow(
            deviceId, "WJ-0001", productCodeHasher.hash(productCode),
            "William James Camera", "WJ-DEV-01", null, "UNCLAIMED", 30,
            registrationExpiresAt, null, null, null, null);
    }

    private DeviceViewRow view(UUID deviceId, String name, String status, String role) {
        return new DeviceViewRow(
            deviceId, name, "WJ-DEV-01", status, role, 30,
            null, "WJ-0001", null, NOW);
    }
}
