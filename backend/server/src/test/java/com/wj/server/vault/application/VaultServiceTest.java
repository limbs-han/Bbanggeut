package com.wj.server.vault.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.lenient;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.wj.server.vault.domain.VaultViewRow;
import com.wj.server.vault.persistence.VaultMapper;
import com.wj.server.iot.telemetry.DevicePresenceStore;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class VaultServiceTest {
    @Mock
    private VaultMapper mapper;
    @Mock
    private DevicePresenceStore presenceStore;
    private VaultService service;

    @BeforeEach
    void setUp() {
        lenient().when(presenceStore.findAll(org.mockito.ArgumentMatchers.anyList()))
            .thenReturn(new DevicePresenceStore.BatchLookup(false, java.util.Map.of()));
        service = new VaultService(mapper, presenceStore);
    }

    @Test
    void listsVaultWithoutDeviceSoMemoriesRemainReachableAfterDisconnect() {
        UUID userId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        when(mapper.findAccessibleVaults(userId)).thenReturn(List.of(
            new VaultViewRow(
                vaultId, "우리 집", "ACTIVE", "OWNER", 30, true, null,
                null, 0, null, null, null, null, null)));

        var response = service.list(userId);

        assertThat(response).hasSize(1);
        assertThat(response.get(0).id()).isEqualTo(vaultId);
        assertThat(response.get(0).devices()).isEmpty();
        assertThat(response.get(0).subscriptionActive()).isTrue();
    }

    @Test
    void groupsMultiplePhysicalDevicesIntoOneVault() {
        UUID userId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        UUID firstDevice = UUID.randomUUID();
        UUID secondDevice = UUID.randomUUID();
        Instant now = Instant.parse("2026-07-29T00:00:00Z");
        when(mapper.findAccessibleVaults(userId)).thenReturn(List.of(
            row(vaultId, firstDevice, "거실", now),
            row(vaultId, secondDevice, "부모님 댁", now)));

        var response = service.list(userId);

        assertThat(response).hasSize(1);
        assertThat(response.get(0).devices())
            .extracting(item -> item.deviceId())
            .containsExactly(firstDevice, secondDevice);
    }

    @Test
    void createsIndependentVaultBeforeAnyDeviceIsPaired() {
        UUID userId = UUID.randomUUID();
        when(mapper.findAccessibleVault(
            org.mockito.ArgumentMatchers.eq(userId),
            org.mockito.ArgumentMatchers.any(UUID.class)))
            .thenAnswer(invocation -> List.of(
                new VaultViewRow(
                    invocation.getArgument(1), "새 금고", "ACTIVE", "OWNER",
                    30, false, null, null, 0,
                    null, null, null, null, null)));

        var response = service.create(userId, " 새 금고 ");

        verify(mapper).insertVault(response.id(), "새 금고");
        verify(mapper).insertOwner(response.id(), userId);
        assertThat(response.devices()).isEmpty();
    }

    private VaultViewRow row(
        UUID vaultId,
        UUID deviceId,
        String deviceName,
        Instant lastSeenAt
    ) {
        return new VaultViewRow(
            vaultId, "우리 집", "ACTIVE", "OWNER", 30, false, null,
            UUID.randomUUID(), 1, deviceId, deviceName,
            "WJ-DEV-01", "ONLINE", lastSeenAt);
    }
}
