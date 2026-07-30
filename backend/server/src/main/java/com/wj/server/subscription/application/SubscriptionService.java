package com.wj.server.subscription.application;

import java.time.Clock;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.SubscriptionProperties;
import com.wj.server.device.domain.DeviceViewRow;
import com.wj.server.device.persistence.DeviceMapper;
import com.wj.server.subscription.api.SubscriptionResponse;
import com.wj.server.subscription.domain.SubscriptionRow;
import com.wj.server.subscription.persistence.SubscriptionMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Device subscription (payment is out of MVP scope — activation is an OWNER
 * action). Active subscription keeps videos for the premium window; cancelling
 * never deletes immediately: every video falls back to the device baseline but
 * keeps at least the grace window, and the retention sweep does the rest.
 */
@Service
public class SubscriptionService {
    private final SubscriptionMapper subscriptionMapper;
    private final DeviceMapper deviceMapper;
    private final SubscriptionProperties properties;
    private final AuditService auditService;
    private final Clock clock;

    @Autowired
    public SubscriptionService(
        SubscriptionMapper subscriptionMapper,
        DeviceMapper deviceMapper,
        SubscriptionProperties properties,
        AuditService auditService
    ) {
        this(subscriptionMapper, deviceMapper, properties, auditService, Clock.systemUTC());
    }

    SubscriptionService(
        SubscriptionMapper subscriptionMapper,
        DeviceMapper deviceMapper,
        SubscriptionProperties properties,
        AuditService auditService,
        Clock clock
    ) {
        this.subscriptionMapper = subscriptionMapper;
        this.deviceMapper = deviceMapper;
        this.properties = properties;
        this.auditService = auditService;
        this.clock = clock;
    }

    @Transactional(readOnly = true)
    public SubscriptionResponse get(UUID userId, UUID deviceId) {
        SubscriptionRow row = subscriptionMapper.findAccessibleSubscription(userId, deviceId)
            .orElseThrow(this::notFound);
        return toResponse(deviceId, row.subscriptionActive(), row.subscriptionGraceUntil());
    }

    @Transactional
    public SubscriptionResponse activate(UUID userId, UUID deviceId) {
        requireOwner(userId, deviceId);
        subscriptionMapper.activate(deviceId);
        subscriptionMapper.extendRetentionToPremium(deviceId, properties.premiumRetentionDays());
        auditService.success(deviceId, userId, "DEVICE_UPDATE", "SUBSCRIPTION", deviceId);
        return toResponse(deviceId, true, null);
    }

    @Transactional
    public SubscriptionResponse cancel(UUID userId, UUID deviceId) {
        requireOwner(userId, deviceId);
        var graceUntil = clock.instant().plus(properties.grace());
        if (subscriptionMapper.cancel(deviceId, graceUntil) != 1) {
            throw new ApiException(
                HttpStatus.CONFLICT, "SUBSCRIPTION_NOT_ACTIVE", "활성 구독이 없습니다.");
        }
        subscriptionMapper.resetRetentionToBaseline(deviceId, graceUntil);
        auditService.success(deviceId, userId, "DEVICE_UPDATE", "SUBSCRIPTION", deviceId);
        return toResponse(deviceId, false, graceUntil);
    }

    @Transactional(readOnly = true)
    public SubscriptionResponse getForVault(UUID userId, UUID vaultId) {
        SubscriptionRow row = subscriptionMapper
            .findAccessibleVaultSubscription(userId, vaultId)
            .orElseThrow(this::notFound);
        return toVaultResponse(
            vaultId, row.subscriptionActive(), row.subscriptionGraceUntil());
    }

    @Transactional
    public SubscriptionResponse activateForVault(UUID userId, UUID vaultId) {
        requireVaultOwner(userId, vaultId);
        subscriptionMapper.activateVault(vaultId);
        subscriptionMapper.extendVaultRetentionToPremium(
            vaultId, properties.premiumRetentionDays());
        auditService.successForVault(
            vaultId, null, userId, "VAULT_UPDATE", "SUBSCRIPTION", vaultId);
        return toVaultResponse(vaultId, true, null);
    }

    @Transactional
    public SubscriptionResponse cancelForVault(UUID userId, UUID vaultId) {
        requireVaultOwner(userId, vaultId);
        var graceUntil = clock.instant().plus(properties.grace());
        if (subscriptionMapper.cancelVault(vaultId, graceUntil) != 1) {
            throw new ApiException(
                HttpStatus.CONFLICT, "SUBSCRIPTION_NOT_ACTIVE", "활성 구독이 없습니다.");
        }
        subscriptionMapper.resetVaultRetentionToBaseline(vaultId, graceUntil);
        auditService.successForVault(
            vaultId, null, userId, "VAULT_UPDATE", "SUBSCRIPTION", vaultId);
        return toVaultResponse(vaultId, false, graceUntil);
    }

    private void requireVaultOwner(UUID userId, UUID vaultId) {
        String role = subscriptionMapper.lockVaultRole(userId, vaultId)
            .orElseThrow(this::notFound);
        if (!"OWNER".equals(role)) {
            auditService.deniedForVault(
                vaultId, null, userId, "VAULT_UPDATE", "SUBSCRIPTION", vaultId,
                "FORBIDDEN_ROLE");
            throw new ApiException(
                HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE", "OWNER 권한이 필요합니다.");
        }
    }

    private SubscriptionResponse toVaultResponse(
        UUID vaultId, boolean active, java.time.Instant graceUntil
    ) {
        return new SubscriptionResponse(
            null, vaultId, active, graceUntil, properties.premiumRetentionDays());
    }

    private void requireOwner(UUID userId, UUID deviceId) {
        DeviceViewRow device = deviceMapper.lockAccessibleDevice(userId, deviceId)
            .orElseThrow(this::notFound);
        if (!"OWNER".equals(device.myRole())) {
            auditService.denied(deviceId, userId, "DEVICE_UPDATE", "SUBSCRIPTION", deviceId, "FORBIDDEN_ROLE");
            throw new ApiException(HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE", "OWNER 권한이 필요합니다.");
        }
    }

    private SubscriptionResponse toResponse(UUID deviceId, boolean active, java.time.Instant graceUntil) {
        return new SubscriptionResponse(deviceId, active, graceUntil, properties.premiumRetentionDays());
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }
}
