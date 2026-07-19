package com.wj.server.device.application;

import java.time.Clock;
import java.util.List;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.device.api.ClaimDeviceRequest;
import com.wj.server.device.api.DeviceResponse;
import com.wj.server.device.api.DeviceSummaryResponse;
import com.wj.server.device.api.DeviceStatusResponse;
import com.wj.server.device.api.UpdateDeviceRequest;
import com.wj.server.device.domain.DeviceRow;
import com.wj.server.device.domain.DeviceViewRow;
import com.wj.server.device.persistence.DeviceMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class DeviceService {
    private final DeviceMapper deviceMapper;
    private final ProductCodeHasher productCodeHasher;
    private final ClaimAttemptService claimAttemptService;
    private final AuditService auditService;
    private final Clock clock;

    @Autowired
    public DeviceService(
        DeviceMapper deviceMapper,
        ProductCodeHasher productCodeHasher,
        ClaimAttemptService claimAttemptService,
        AuditService auditService
    ) {
        this(deviceMapper, productCodeHasher, claimAttemptService, auditService, Clock.systemUTC());
    }

    DeviceService(
        DeviceMapper deviceMapper,
        ProductCodeHasher productCodeHasher,
        ClaimAttemptService claimAttemptService,
        AuditService auditService,
        Clock clock
    ) {
        this.deviceMapper = deviceMapper;
        this.productCodeHasher = productCodeHasher;
        this.claimAttemptService = claimAttemptService;
        this.auditService = auditService;
        this.clock = clock;
    }

    @Transactional
    public DeviceResponse claim(UUID userId, ClaimDeviceRequest request, String ipAddress) {
        claimAttemptService.ensureAllowed(userId, request.serialNumber(), ipAddress);
        UUID attemptedDeviceId = null;
        try {
            DeviceRow device = deviceMapper.findClaimCandidateForUpdate(request.serialNumber().trim())
                .orElseThrow(this::claimRejected);
            attemptedDeviceId = device.id();

            if (!"UNCLAIMED".equals(device.status())
                || device.productCodeRetiredAt() != null
                || device.registrationModeExpiresAt() == null
                || !device.registrationModeExpiresAt().isAfter(clock.instant())
                || !productCodeHasher.matches(request.productCode(), device.productCodeHash())) {
                throw claimRejected();
            }

            String requestedName = request.name() == null ? null : request.name().trim();
            if (deviceMapper.markClaimed(device.id(), userId, requestedName) != 1) {
                throw claimRejected();
            }
            deviceMapper.insertOwnerMembership(device.id(), userId);
            DeviceResponse response = deviceMapper.findAccessibleDevice(userId, device.id())
                .map(this::toDeviceResponse)
                .orElseThrow(() -> new IllegalStateException("Claimed device is not accessible to its owner"));
            claimAttemptService.recordSuccess(userId, request.serialNumber(), ipAddress);
            auditService.success(device.id(), userId, "DEVICE_CLAIM", "DEVICE", device.id());
            return response;
        } catch (ApiException exception) {
            if ("DEVICE_CLAIM_REJECTED".equals(exception.code())) {
                claimAttemptService.recordFailure(userId, request.serialNumber(), ipAddress);
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
        return deviceMapper.findAccessibleDevices(userId).stream()
            .map(this::toSummaryResponse)
            .toList();
    }

    @Transactional(readOnly = true)
    public DeviceResponse get(UUID userId, UUID deviceId) {
        return deviceMapper.findAccessibleDevice(userId, deviceId)
            .map(this::toDeviceResponse)
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
            request.retentionDaysPresent(), request.retentionDays());
        DeviceResponse response = deviceMapper.findAccessibleDevice(userId, deviceId)
            .map(this::toDeviceResponse)
            .orElseThrow(this::notFound);
        auditService.success(deviceId, userId, "DEVICE_UPDATE", "DEVICE", deviceId);
        return response;
    }

    @Transactional
    public DeviceStatusResponse status(UUID userId, UUID deviceId) {
        deviceMapper.findAccessibleDevice(userId, deviceId).orElseThrow(this::notFound);
        deviceMapper.markOfflineIfStale(deviceId);
        var status = deviceMapper.findAccessibleStatus(userId, deviceId).orElseThrow(this::notFound);
        return new DeviceStatusResponse(
            status.deviceId(), status.status(), status.recording(), status.uploadQueueDepth(),
            status.bufferSeconds(), clock.instant());
    }

    @Transactional
    public void revoke(UUID userId, UUID deviceId) {
        DeviceViewRow device = deviceMapper.lockAccessibleDevice(userId, deviceId)
            .orElseThrow(this::notFound);
        requireOwner(device.myRole(), userId, deviceId, "DEVICE_REVOKE");
        if (deviceMapper.markRevoked(deviceId) != 1) {
            throw notFound();
        }
        deviceMapper.revokeActiveCredentials(deviceId);
        deviceMapper.revokePendingInvitations(deviceId);
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

    private DeviceSummaryResponse toSummaryResponse(DeviceViewRow row) {
        return new DeviceSummaryResponse(
            row.id(), row.name(), row.model(), row.status(), row.myRole(),
            row.retentionDays(), row.lastSeenAt());
    }

    private DeviceResponse toDeviceResponse(DeviceViewRow row) {
        return new DeviceResponse(
            row.id(), row.name(), row.model(), row.status(), row.myRole(),
            row.retentionDays(), row.lastSeenAt(), row.serialNumber(),
            row.firmwareVersion(), row.claimedAt());
    }

    private ApiException claimRejected() {
        return new ApiException(
            HttpStatus.CONFLICT,
            "DEVICE_CLAIM_REJECTED",
            "기기를 등록할 수 없습니다. 제품 코드와 기기의 등록 모드를 확인해 주세요.");
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }
}
