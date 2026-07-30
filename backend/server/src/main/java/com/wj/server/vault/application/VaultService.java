package com.wj.server.vault.application;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.iot.telemetry.DevicePresenceSnapshot;
import com.wj.server.iot.telemetry.DevicePresenceStore;
import com.wj.server.vault.api.VaultDeviceResponse;
import com.wj.server.vault.api.VaultResponse;
import com.wj.server.vault.domain.VaultViewRow;
import com.wj.server.vault.persistence.VaultMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class VaultService {
    private final VaultMapper mapper;
    private final DevicePresenceStore presenceStore;

    public VaultService(VaultMapper mapper, DevicePresenceStore presenceStore) {
        this.mapper = mapper;
        this.presenceStore = presenceStore;
    }

    @Transactional
    public VaultResponse create(UUID userId, String name) {
        UUID vaultId = UUID.randomUUID();
        mapper.insertVault(vaultId, name.trim());
        mapper.insertOwner(vaultId, userId);
        return get(userId, vaultId);
    }

    @Transactional(readOnly = true)
    public List<VaultResponse> list(UUID userId) {
        return aggregate(mapper.findAccessibleVaults(userId));
    }

    @Transactional(readOnly = true)
    public VaultResponse get(UUID userId, UUID vaultId) {
        List<VaultResponse> result = aggregate(mapper.findAccessibleVault(userId, vaultId));
        if (result.isEmpty()) {
            throw new ApiException(
                HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "추억 금고를 찾을 수 없습니다.");
        }
        return result.get(0);
    }

    private List<VaultResponse> aggregate(List<VaultViewRow> rows) {
        DevicePresenceStore.BatchLookup presence = presenceStore.findAll(
            rows.stream()
                .map(VaultViewRow::deviceId)
                .filter(java.util.Objects::nonNull)
                .distinct()
                .toList());
        LinkedHashMap<UUID, VaultAccumulator> grouped = new LinkedHashMap<>();
        for (VaultViewRow row : rows) {
            VaultAccumulator accumulator = grouped.computeIfAbsent(
                row.id(), ignored -> new VaultAccumulator(row, new ArrayList<>()));
            if (row.deviceId() != null) {
                DevicePresenceSnapshot snapshot = presence.snapshots().get(row.deviceId());
                String status = presence.storeAvailable()
                    ? (snapshot == null ? "OFFLINE" : "ONLINE")
                    : row.deviceStatus();
                java.time.Instant lastSeenAt =
                    presence.storeAvailable() && snapshot != null
                        ? snapshot.lastSeenAt() : row.deviceLastSeenAt();
                accumulator.devices().add(new VaultDeviceResponse(
                    row.bindingId(), row.bindingGeneration(), row.deviceId(),
                    row.deviceName(), row.deviceModel(), status, lastSeenAt));
            }
        }
        return grouped.values().stream()
            .map(item -> new VaultResponse(
                item.row().id(), item.row().name(), item.row().status(),
                item.row().myRole(), item.row().retentionDays(),
                item.row().subscriptionActive(),
                item.row().subscriptionGraceUntil(),
                List.copyOf(item.devices())))
            .toList();
    }

    private record VaultAccumulator(
        VaultViewRow row,
        List<VaultDeviceResponse> devices
    ) {
    }
}
