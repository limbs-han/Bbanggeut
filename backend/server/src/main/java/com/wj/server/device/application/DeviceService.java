package com.wj.server.device.application;

import java.time.Clock;
import java.util.List;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.common.ratelimit.SlidingWindowRateLimiter;
import com.wj.server.device.api.ClaimDeviceRequest;
import com.wj.server.device.api.DeviceResponse;
import com.wj.server.device.api.DeviceSummaryResponse;
import com.wj.server.device.api.DeviceStatusResponse;
import com.wj.server.device.api.TransferOwnershipRequest;
import com.wj.server.device.api.UpdateDeviceRequest;
import com.wj.server.device.domain.DeviceViewRow;
import com.wj.server.device.domain.MembershipStateRow;
import com.wj.server.device.domain.RegistrationCodeRow;
import com.wj.server.device.persistence.DeviceMapper;
import com.wj.server.device.persistence.RegistrationCodeMapper;
import com.wj.server.iot.mqtt.DeviceMqttIdentityManager;
import com.wj.server.iot.telemetry.DevicePresenceSnapshot;
import com.wj.server.iot.telemetry.DevicePresenceStore;
import com.wj.server.vault.persistence.VaultMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class DeviceService {
    private final DeviceMapper deviceMapper;
    private final RegistrationCodeMapper registrationCodeMapper;
    private final RegistrationCodeHasher registrationCodeHasher;
    private final ClaimAttemptService claimAttemptService;
    private final AuditService auditService;
    private final DeviceMqttIdentityManager mqttIdentityManager;
    private final VaultMapper vaultMapper;
    private final DevicePresenceStore presenceStore;
    private final Clock clock;

    @Autowired
    public DeviceService(
        DeviceMapper deviceMapper,
        RegistrationCodeMapper registrationCodeMapper,
        RegistrationCodeHasher registrationCodeHasher,
        ClaimAttemptService claimAttemptService,
        AuditService auditService,
        DeviceMqttIdentityManager mqttIdentityManager,
        VaultMapper vaultMapper,
        DevicePresenceStore presenceStore
    ) {
        this(deviceMapper, registrationCodeMapper, registrationCodeHasher,
            claimAttemptService, auditService, mqttIdentityManager, vaultMapper, presenceStore,
            Clock.systemUTC());
    }

    DeviceService(
        DeviceMapper deviceMapper,
        RegistrationCodeMapper registrationCodeMapper,
        RegistrationCodeHasher registrationCodeHasher,
        ClaimAttemptService claimAttemptService,
        AuditService auditService,
        DeviceMqttIdentityManager mqttIdentityManager,
        VaultMapper vaultMapper,
        DevicePresenceStore presenceStore,
        Clock clock
    ) {
        this.deviceMapper = deviceMapper;
        this.registrationCodeMapper = registrationCodeMapper;
        this.registrationCodeHasher = registrationCodeHasher;
        this.claimAttemptService = claimAttemptService;
        this.auditService = auditService;
        this.mqttIdentityManager = mqttIdentityManager;
        this.vaultMapper = vaultMapper;
        this.presenceStore = presenceStore;
        this.clock = clock;
    }

    @Transactional
    public DeviceResponse claim(UUID userId, ClaimDeviceRequest request, String ipAddress) {
        SlidingWindowRateLimiter.Reservation reservation =
            claimAttemptService.reserveOrReject(userId, ipAddress);
        UUID attemptedDeviceId = null;
        try {
            // The submitted code identifies the device: the hash lookup is the
            // only way from an app request to a claim candidate.
            RegistrationCodeRow code = registrationCodeMapper
                .findByHashForUpdate(registrationCodeHasher.hash(request.registrationCode()))
                .orElseThrow(this::claimRejected);
            attemptedDeviceId = code.deviceId();

            if (code.usedAt() != null
                || !code.expiresAt().isAfter(clock.instant())
                || !"UNCLAIMED".equals(code.deviceStatus())) {
                throw claimRejected();
            }

            String requestedName = request.name() == null ? null : request.name().trim();
            if (deviceMapper.markClaimed(code.deviceId(), userId, requestedName) != 1
                || registrationCodeMapper.markUsed(code.id(), userId) != 1) {
                throw claimRejected();
            }
            UUID vaultId = request.vaultId();
            if (vaultId == null) {
                vaultId = UUID.randomUUID();
                vaultMapper.insertVault(
                    vaultId,
                    request.vaultName() == null
                        ? "나의 추억"
                        : request.vaultName().trim());
                vaultMapper.insertOwner(vaultId, userId);
            } else {
                String role = vaultMapper.findActiveRole(userId, vaultId)
                    .orElseThrow(this::notFound);
                requireOwner(role, userId, code.deviceId(), "DEVICE_CLAIM");
            }
            vaultMapper.insertActiveBinding(code.deviceId(), vaultId);
            deviceMapper.insertOwnerMembership(code.deviceId(), userId);
            deviceMapper.syncMembershipsFromVault(code.deviceId());
            DeviceResponse response = deviceMapper.findAccessibleDevice(userId, code.deviceId())
                .map(this::toCurrentDeviceResponse)
                .orElseThrow(() -> new IllegalStateException("Claimed device is not accessible to its owner"));
            claimAttemptService.completeSuccess(reservation);
            auditService.success(code.deviceId(), userId, "DEVICE_CLAIM", "DEVICE", code.deviceId());
            return response;
        } catch (ApiException exception) {
            if ("DEVICE_CLAIM_REJECTED".equals(exception.code())) {
                claimAttemptService.recordFailure(userId, ipAddress);
                if (attemptedDeviceId != null) {
                    auditService.denied(
                        attemptedDeviceId, userId, "DEVICE_CLAIM", "DEVICE", attemptedDeviceId,
                        "DEVICE_CLAIM_REJECTED");
                }
            }
            throw exception;
        }
    }

    @Transactional(readOnly = true)
    public List<DeviceSummaryResponse> list(UUID userId) {
        List<DeviceViewRow> rows = deviceMapper.findAccessibleDevices(userId);
        DevicePresenceStore.BatchLookup presence =
            presenceStore.findAll(rows.stream().map(DeviceViewRow::id).toList());
        return rows.stream()
            .map(row -> toSummaryResponse(
                row, presence.storeAvailable(), presence.snapshots().get(row.id())))
            .toList();
    }

    @Transactional(readOnly = true)
    public DeviceResponse get(UUID userId, UUID deviceId) {
        return deviceMapper.findAccessibleDevice(userId, deviceId)
            .map(this::toCurrentDeviceResponse)
            .orElseThrow(() -> new ApiException(
                HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다."));
    }

    @Transactional
    public DeviceResponse update(UUID userId, UUID deviceId, UpdateDeviceRequest request) {
        validateUpdate(request);
        DeviceViewRow device = deviceMapper.lockAccessibleDevice(userId, deviceId)
            .orElseThrow(this::notFound);
        requireOwner(device.myRole(), userId, deviceId, "DEVICE_UPDATE");
        deviceMapper.updateSettings(
            deviceId,
            request.namePresent(), request.namePresent() ? request.name().trim() : null,
            request.retentionDaysPresent(), request.retentionDays(),
            request.detectionEnabledPresent(), request.detectionEnabled());
        vaultMapper.updateRetentionForDevice(
            deviceId, request.retentionDaysPresent(), request.retentionDays());
        DeviceResponse response = deviceMapper.findAccessibleDevice(userId, deviceId)
            .map(this::toCurrentDeviceResponse)
            .orElseThrow(this::notFound);
        auditService.success(deviceId, userId, "DEVICE_UPDATE", "DEVICE", deviceId);
        return response;
    }

    @Transactional
    public DeviceStatusResponse status(UUID userId, UUID deviceId) {
        deviceMapper.findAccessibleDevice(userId, deviceId).orElseThrow(this::notFound);
        DevicePresenceStore.Lookup presence = presenceStore.find(deviceId);
        if (presence.storeAvailable()) {
            DevicePresenceSnapshot snapshot = presence.snapshot();
            return snapshot == null
                ? new DeviceStatusResponse(deviceId, "OFFLINE", false, 0, null, null, clock.instant())
                : new DeviceStatusResponse(
                    deviceId, "ONLINE", snapshot.recording(), snapshot.uploadQueueDepth(),
                    snapshot.bufferSeconds(), snapshot.personCount(), clock.instant());
        }

        // Redis outages fall back to the previous durable last-seen behavior.
        deviceMapper.markOfflineIfStale(deviceId);
        var status = deviceMapper.findAccessibleStatus(userId, deviceId).orElseThrow(this::notFound);
        return new DeviceStatusResponse(
            status.deviceId(), status.status(), status.recording(), status.uploadQueueDepth(),
            status.bufferSeconds(), status.personCount(), clock.instant());
    }

    /**
     * Transfers ownership to an existing active MEMBER of the same device.
     * Videos, members, settings and the device subscription all stay — only the
     * roles swap. The deferred one-active-OWNER trigger re-validates at commit.
     */
    @Transactional
    public void transferOwnership(UUID userId, UUID deviceId, TransferOwnershipRequest request) {
        DeviceViewRow device = deviceMapper.lockAccessibleDevice(userId, deviceId)
            .orElseThrow(this::notFound);
        requireOwner(device.myRole(), userId, deviceId, "DEVICE_UPDATE");
        MembershipStateRow target = deviceMapper.lockMembership(deviceId, request.newOwnerMembershipId())
            .orElseThrow(this::notFound);
        if (target.userId().equals(userId)) {
            throw new ApiException(
                HttpStatus.CONFLICT, "ALREADY_OWNER", "이미 본인이 OWNER인 기기입니다.");
        }
        if (!"MEMBER".equals(target.role())
            || !"ACTIVE".equals(target.status())
            || vaultMapper.demoteOwnerForDevice(deviceId, userId) != 1
            || vaultMapper.promoteMemberForDevice(deviceId, target.id()) != 1
            || deviceMapper.demoteOwnerToMember(deviceId, userId) != 1
            || deviceMapper.promoteNonOwnerToOwner(deviceId, target.id()) != 1) {
            throw new ApiException(
                HttpStatus.CONFLICT,
                "TRANSFER_TARGET_NOT_ACTIVE_MEMBER",
                "해당 기기의 활성 MEMBER에게만 소유권을 넘길 수 있습니다.");
        }
        auditService.success(deviceId, userId, "DEVICE_UPDATE", "MEMBERSHIP", target.id());
    }

    /**
     * Disconnects the physical camera from its vault. Memories, subscription
     * and vault membership survive; only live-device access is closed. The
     * stable physical row returns to UNCLAIMED so it can be paired again.
     */
    @Transactional
    public void revoke(UUID userId, UUID deviceId) {
        DeviceViewRow device = deviceMapper.lockAccessibleDevice(userId, deviceId)
            .orElseThrow(this::notFound);
        requireOwner(device.myRole(), userId, deviceId, "DEVICE_REVOKE");
        vaultMapper.lockActiveVaultId(deviceId).orElseThrow(this::notFound);
        if (vaultMapper.endActiveBinding(deviceId, userId, "DISCONNECTED") != 1
            || deviceMapper.markUnclaimed(deviceId) != 1) {
            throw notFound();
        }
        deviceMapper.revokeAllMemberships(deviceId, userId);
        auditService.success(deviceId, userId, "DEVICE_REVOKE", "DEVICE", deviceId);
    }

    private void validateUpdate(UpdateDeviceRequest request) {
        if (!request.namePresent() && !request.retentionDaysPresent()) {
            throw validation("수정할 필드를 하나 이상 입력해야 합니다.");
        }
        if (request.namePresent()
            && (request.name() == null || request.name().trim().isEmpty() || request.name().trim().length() > 80)) {
            throw validation("name은 공백이 아닌 1자 이상 80자 이하여야 합니다.");
        }
        if (request.retentionDaysPresent()
            && (request.retentionDays() == null
                || request.retentionDays() < 1 || request.retentionDays() > 3650)) {
            throw validation("retentionDays는 1 이상 3650 이하여야 합니다.");
        }
    }

    private void requireOwner(String role, UUID userId, UUID deviceId, String action) {
        if (!"OWNER".equals(role)) {
            auditService.denied(deviceId, userId, action, "DEVICE", deviceId, "FORBIDDEN_ROLE");
            throw new ApiException(HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE", "OWNER 권한이 필요합니다.");
        }
    }

    private DeviceSummaryResponse toSummaryResponse(
        DeviceViewRow row,
        boolean storeAvailable,
        DevicePresenceSnapshot snapshot
    ) {
        String status = storeAvailable ? (snapshot == null ? "OFFLINE" : "ONLINE") : row.status();
        java.time.Instant lastSeenAt =
            storeAvailable && snapshot != null ? snapshot.lastSeenAt() : row.lastSeenAt();
        return new DeviceSummaryResponse(
            row.id(), row.name(), row.model(), status, row.myRole(),
            row.retentionDays(), lastSeenAt, row.detectionEnabled());
    }

    private DeviceResponse toCurrentDeviceResponse(DeviceViewRow row) {
        DevicePresenceStore.Lookup presence = presenceStore.find(row.id());
        DevicePresenceSnapshot snapshot = presence.snapshot();
        String status = presence.storeAvailable()
            ? (snapshot == null ? "OFFLINE" : "ONLINE")
            : row.status();
        java.time.Instant lastSeenAt =
            presence.storeAvailable() && snapshot != null ? snapshot.lastSeenAt() : row.lastSeenAt();
        String firmwareVersion = presence.storeAvailable() && snapshot != null
            && snapshot.firmwareVersion() != null
            ? snapshot.firmwareVersion() : row.firmwareVersion();
        return new DeviceResponse(
            row.id(), row.name(), row.model(), status, row.myRole(),
            row.retentionDays(), lastSeenAt, row.serialNumber(),
            firmwareVersion, row.claimedAt(), row.detectionEnabled());
    }

    private ApiException claimRejected() {
        return new ApiException(
            HttpStatus.CONFLICT,
            "DEVICE_CLAIM_REJECTED",
            "기기를 등록할 수 없습니다. 화면 등록 코드와 기기의 등록 모드를 확인해 주세요.");
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }
}
