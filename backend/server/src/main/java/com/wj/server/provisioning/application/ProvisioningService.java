package com.wj.server.provisioning.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.HexFormat;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.provisioning.api.ProvisionDeviceRequest;
import com.wj.server.provisioning.api.ProvisionedDeviceResponse;
import com.wj.server.provisioning.persistence.ProvisioningMapper;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class ProvisioningService {
    private static final SecureRandom SECURE_RANDOM = new SecureRandom();

    private final ProvisioningMapper mapper;
    public ProvisioningService(ProvisioningMapper mapper) {
        this.mapper = mapper;
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
        return issueCredential(deviceId, request.serialNumber().trim());
    }

    @Transactional
    public ProvisionedDeviceResponse rotate(UUID deviceId) {
        String status = mapper.findDeviceStatus(deviceId).orElseThrow(this::notFound);
        if ("REVOKED".equals(status)) {
            throw new ApiException(HttpStatus.CONFLICT, "DEVICE_REVOKED", "해제된 기기에는 자격 증명을 발급할 수 없습니다.");
        }
        mapper.revokeActiveCredentials(deviceId);
        return issueCredential(deviceId, null);
    }

    @Transactional
    public void revoke(UUID deviceId) {
        mapper.findDeviceStatus(deviceId).orElseThrow(this::notFound);
        mapper.revokeActiveCredentials(deviceId);
    }

    private ProvisionedDeviceResponse issueCredential(UUID deviceId, String serialNumber) {
        String keyId = "wj_" + UUID.randomUUID().toString().replace("-", "");
        byte[] bytes = new byte[32];
        SECURE_RANDOM.nextBytes(bytes);
        String secret = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
        mapper.insertTokenCredential(deviceId, keyId, hash(secret));
        return new ProvisionedDeviceResponse(deviceId, serialNumber, keyId, keyId + "." + secret);
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
