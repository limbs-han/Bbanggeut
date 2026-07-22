package com.wj.server.provisioning.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.HexFormat;
import java.util.UUID;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;

import com.wj.server.common.api.ApiException;
import com.wj.server.provisioning.api.ProvisionDeviceRequest;
import com.wj.server.provisioning.api.ProvisionedDeviceResponse;
import com.wj.server.provisioning.persistence.ProvisioningMapper;
import com.wj.server.config.DeviceCredentialProperties;
import com.wj.server.iot.mqtt.DeviceMqttIdentityManager;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.beans.factory.annotation.Autowired;

@Service
public class ProvisioningService {
    private static final SecureRandom SECURE_RANDOM = new SecureRandom();

    private final ProvisioningMapper mapper;
    private final DeviceCredentialProperties properties;
    private final Clock clock;
    private final DeviceMqttIdentityManager mqttIdentityManager;

    @Autowired
    public ProvisioningService(
        ProvisioningMapper mapper,
        DeviceCredentialProperties properties,
        DeviceMqttIdentityManager mqttIdentityManager
    ) {
        this(mapper, properties, mqttIdentityManager, Clock.systemUTC());
    }

    ProvisioningService(
        ProvisioningMapper mapper,
        DeviceCredentialProperties properties,
        DeviceMqttIdentityManager mqttIdentityManager,
        Clock clock
    ) {
        this.mapper = mapper;
        this.properties = properties;
        this.mqttIdentityManager = mqttIdentityManager;
        this.clock = clock;
    }

    @Transactional
    public ProvisionedDeviceResponse provision(ProvisionDeviceRequest request) {
        UUID deviceId;
        try {
            deviceId = mapper.insertDevice(
                request.serialNumber().trim(), request.name().trim(), request.model().trim(),
                trimToNull(request.firmwareVersion()));
        } catch (DuplicateKeyException exception) {
            throw new ApiException(
                HttpStatus.CONFLICT, "DEVICE_SERIAL_ALREADY_ACTIVE", "사용 중인 기기 시리얼입니다.");
        }
        return issueCredential(
            deviceId, request.serialNumber().trim(), "BOOTSTRAP", properties.bootstrapTtl());
    }

    @Transactional
    public ProvisionedDeviceResponse rotate(UUID deviceId) {
        String status = mapper.lockDeviceStatus(deviceId).orElseThrow(this::notFound);
        if ("REVOKED".equals(status)) {
            throw new ApiException(HttpStatus.CONFLICT, "DEVICE_REVOKED", "해제된 기기에는 자격 증명을 발급할 수 없습니다.");
        }
        String currentPurpose = mapper.lockCurrentCredentialPurpose(deviceId).orElse("BOOTSTRAP");
        return replaceWithOperatingCredential(deviceId, "BOOTSTRAP".equals(currentPurpose));
    }

    @Transactional
    public ProvisionedDeviceResponse enroll(UUID deviceId, String keyId) {
        mapper.lockDeviceStatus(deviceId).orElseThrow(this::notFound);
        requirePresentedCredential(deviceId, keyId, "BOOTSTRAP");
        return replaceWithOperatingCredential(deviceId, true);
    }

    @Transactional
    public ProvisionedDeviceResponse rotateSelf(UUID deviceId, String keyId) {
        mapper.lockDeviceStatus(deviceId).orElseThrow(this::notFound);
        requirePresentedCredential(deviceId, keyId, "OPERATING");
        return replaceWithOperatingCredential(deviceId, false);
    }

    @Transactional
    public void revoke(UUID deviceId) {
        mapper.lockDeviceStatus(deviceId).orElseThrow(this::notFound);
        String currentPurpose = mapper.lockCurrentCredentialPurpose(deviceId).orElse(null);
        mapper.revokeActiveCredentials(deviceId);
        if ("OPERATING".equals(currentPurpose)) {
            mqttIdentityManager.revoke(deviceId);
        }
    }

    private ProvisionedDeviceResponse replaceWithOperatingCredential(UUID deviceId, boolean createMqtt) {
        mapper.revokeActiveCredentials(deviceId);
        ProvisionedDeviceResponse credential = issueCredential(
            deviceId, null, "OPERATING", properties.operatingTtl());
        if (createMqtt) {
            mqttIdentityManager.create(deviceId, credential.bearerToken());
        } else {
            mqttIdentityManager.rotate(deviceId, credential.bearerToken());
        }
        return credential;
    }

    private void requirePresentedCredential(UUID deviceId, String keyId, String expectedPurpose) {
        String actualPurpose = mapper.lockActiveCredentialPurpose(deviceId, keyId)
            .orElseThrow(() -> new ApiException(
                HttpStatus.UNAUTHORIZED,
                "DEVICE_CREDENTIAL_STALE",
                "The presented device credential is no longer active."));
        if (!expectedPurpose.equals(actualPurpose)) {
            throw new ApiException(
                HttpStatus.FORBIDDEN,
                "DEVICE_CREDENTIAL_PURPOSE_INVALID",
                "The device credential cannot be used for this operation.");
        }
    }

    private ProvisionedDeviceResponse issueCredential(
        UUID deviceId,
        String serialNumber,
        String purpose,
        Duration ttl
    ) {
        String keyId = "wj_" + UUID.randomUUID().toString().replace("-", "");
        byte[] bytes = new byte[32];
        SECURE_RANDOM.nextBytes(bytes);
        String secret = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
        Instant expiresAt = clock.instant().plus(ttl);
        mapper.insertTokenCredential(deviceId, keyId, hash(secret), purpose, expiresAt);
        return new ProvisionedDeviceResponse(
            deviceId, serialNumber, keyId, keyId + "." + secret, purpose, expiresAt,
            "OPERATING".equals(purpose) ? deviceId.toString() : null);
    }

    private String hash(String value) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    private String trimToNull(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }
}
