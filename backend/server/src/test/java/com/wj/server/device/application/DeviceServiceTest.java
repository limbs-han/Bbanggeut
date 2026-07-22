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
import com.wj.server.device.domain.DeviceStatusRow;
import com.wj.server.device.domain.DeviceViewRow;
import com.wj.server.device.domain.RegistrationCodeRow;
import com.wj.server.device.persistence.DeviceMapper;
import com.wj.server.device.persistence.RegistrationCodeMapper;
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
    private RegistrationCodeMapper registrationCodeMapper;
    @Mock
    private ClaimAttemptService claimAttemptService;
    @Mock
    private AuditService auditService;

    private RegistrationCodeHasher registrationCodeHasher;
    private DeviceService deviceService;

    @BeforeEach
    void setUp() {
        registrationCodeHasher = new RegistrationCodeHasher();
        deviceService = new DeviceService(
            deviceMapper, registrationCodeMapper, registrationCodeHasher,
            claimAttemptService, auditService, Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void claimResolvesDeviceFromCodeAndCreatesOwner() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID codeId = UUID.randomUUID();
        RegistrationCodeRow code = new RegistrationCodeRow(
            codeId, deviceId, NOW.plusSeconds(30), null, "UNCLAIMED");
        DeviceViewRow claimed = new DeviceViewRow(
            deviceId, "거실", "WJ-DEV-01", "OFFLINE", "OWNER", 30,
            null, "WJ-0001", null, NOW);
        when(registrationCodeMapper.findByHashForUpdate(registrationCodeHasher.hash("7F3K9XQM")))
            .thenReturn(Optional.of(code));
        when(deviceMapper.markClaimed(deviceId, userId, "거실")).thenReturn(1);
        when(registrationCodeMapper.markUsed(codeId, userId)).thenReturn(1);
        when(deviceMapper.insertOwnerMembership(deviceId, userId)).thenReturn(1);
        when(deviceMapper.findAccessibleDevice(userId, deviceId)).thenReturn(Optional.of(claimed));

        var response = deviceService.claim(
            userId, new ClaimDeviceRequest(" 7f3k-9xqm ", " 거실 "), "127.0.0.1");

        verify(deviceMapper).markClaimed(deviceId, userId, "거실");
        verify(registrationCodeMapper).markUsed(codeId, userId);
        verify(deviceMapper).insertOwnerMembership(deviceId, userId);
        verify(claimAttemptService).recordSuccess(userId, "127.0.0.1");
        assertThat(response.status()).isEqualTo("OFFLINE");
        assertThat(response.myRole()).isEqualTo("OWNER");
        assertThat(response.name()).isEqualTo("거실");
    }

    @Test
    void claimRejectsExpiredCodeWithoutChangingDevice() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        RegistrationCodeRow expired = new RegistrationCodeRow(
            UUID.randomUUID(), deviceId, NOW, null, "UNCLAIMED");
        when(registrationCodeMapper.findByHashForUpdate(registrationCodeHasher.hash("7F3K9XQM")))
            .thenReturn(Optional.of(expired));

        assertThatThrownBy(() -> deviceService.claim(
            userId, new ClaimDeviceRequest("7F3K9XQM", null), "127.0.0.1"))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("DEVICE_CLAIM_REJECTED");

        verify(deviceMapper, never()).markClaimed(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any(),
            org.mockito.ArgumentMatchers.any());
        verify(claimAttemptService).recordFailure(userId, "127.0.0.1");
    }

    @Test
    void claimRejectsUsedCodeAndUnknownCode() {
        UUID userId = UUID.randomUUID();
        RegistrationCodeRow used = new RegistrationCodeRow(
            UUID.randomUUID(), UUID.randomUUID(), NOW.plusSeconds(30), NOW.minusSeconds(5), "UNCLAIMED");
        when(registrationCodeMapper.findByHashForUpdate(registrationCodeHasher.hash("7F3K9XQM")))
            .thenReturn(Optional.of(used));
        when(registrationCodeMapper.findByHashForUpdate(registrationCodeHasher.hash("AAAA2222")))
            .thenReturn(Optional.empty());

        assertThatThrownBy(() -> deviceService.claim(
            userId, new ClaimDeviceRequest("7F3K9XQM", null), "127.0.0.1"))
            .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> deviceService.claim(
            userId, new ClaimDeviceRequest("AAAA2222", null), "127.0.0.1"))
            .isInstanceOf(ApiException.class);

        verify(claimAttemptService, org.mockito.Mockito.times(2))
            .recordFailure(userId, "127.0.0.1");
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
            .thenReturn(Optional.of(new DeviceStatusRow(deviceId, "OFFLINE", false, 2, 120, null)));

        var response = deviceService.status(userId, deviceId);

        verify(deviceMapper).markOfflineIfStale(deviceId);
        assertThat(response.status()).isEqualTo("OFFLINE");
        assertThat(response.uploadQueueDepth()).isEqualTo(2);
        assertThat(response.personCount()).isNull();
        assertThat(response.checkedAt()).isEqualTo(NOW);
    }

    @Test
    void ownerRevocationClosesOldRowDeletesVideosAndCreatesSuccessor() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(deviceMapper.lockAccessibleDevice(ownerId, deviceId))
            .thenReturn(Optional.of(view(deviceId, "Camera", "OFFLINE", "OWNER")));
        when(deviceMapper.markRevoked(deviceId)).thenReturn(1);

        deviceService.revoke(ownerId, deviceId);

        verify(deviceMapper).revokeActiveCredentials(deviceId);
        verify(deviceMapper).revokeInviteLinks(deviceId);
        verify(deviceMapper).cancelPendingJoinRequests(deviceId);
        verify(deviceMapper).revokeAllMemberships(deviceId, ownerId);
        verify(deviceMapper).markAllVideosDeleting(deviceId, ownerId);
        verify(deviceMapper).enqueueDeletionJobsForDevice(deviceId);
        verify(deviceMapper).insertSuccessorDevice(deviceId);
    }

    @Test
    void ownershipTransferSwapsRolesWithoutTouchingVideos() {
        UUID ownerId = UUID.randomUUID();
        UUID memberId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID membershipId = UUID.randomUUID();
        when(deviceMapper.lockAccessibleDevice(ownerId, deviceId))
            .thenReturn(Optional.of(view(deviceId, "Camera", "OFFLINE", "OWNER")));
        when(deviceMapper.lockMembership(deviceId, membershipId))
            .thenReturn(Optional.of(new com.wj.server.device.domain.MembershipStateRow(
                membershipId, memberId, "MEMBER", "ACTIVE")));
        when(deviceMapper.demoteOwnerToMember(deviceId, ownerId)).thenReturn(1);
        when(deviceMapper.promoteMemberToOwner(deviceId, membershipId)).thenReturn(1);

        deviceService.transferOwnership(
            ownerId, deviceId, new com.wj.server.device.api.TransferOwnershipRequest(membershipId));

        verify(deviceMapper).demoteOwnerToMember(deviceId, ownerId);
        verify(deviceMapper).promoteMemberToOwner(deviceId, membershipId);
        verify(deviceMapper, never()).markAllVideosDeleting(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any());
    }

    @Test
    void ownershipTransferRejectsRevokedMembershipTarget() {
        UUID ownerId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID membershipId = UUID.randomUUID();
        when(deviceMapper.lockAccessibleDevice(ownerId, deviceId))
            .thenReturn(Optional.of(view(deviceId, "Camera", "OFFLINE", "OWNER")));
        when(deviceMapper.lockMembership(deviceId, membershipId))
            .thenReturn(Optional.of(new com.wj.server.device.domain.MembershipStateRow(
                membershipId, UUID.randomUUID(), "MEMBER", "REVOKED")));

        assertThatThrownBy(() -> deviceService.transferOwnership(
            ownerId, deviceId, new com.wj.server.device.api.TransferOwnershipRequest(membershipId)))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("TRANSFER_TARGET_NOT_ACTIVE_MEMBER");
        verify(deviceMapper, never()).demoteOwnerToMember(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any());
    }

    @Test
    void emptyDevicePatchIsRejected() {
        assertThatThrownBy(() -> deviceService.update(
            UUID.randomUUID(), UUID.randomUUID(), new UpdateDeviceRequest()))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("VALIDATION_FAILED");
    }

    private DeviceViewRow view(UUID deviceId, String name, String status, String role) {
        return new DeviceViewRow(
            deviceId, name, "WJ-DEV-01", status, role, 30,
            null, "WJ-0001", null, NOW);
    }
}
