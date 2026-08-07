package com.wj.server.provisioning.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.never;

import java.util.Optional;
import java.util.UUID;
import java.time.Duration;

import com.wj.server.provisioning.api.ProvisionDeviceRequest;
import com.wj.server.provisioning.persistence.ProvisioningMapper;
import com.wj.server.config.DeviceCredentialProperties;
import com.wj.server.iot.mqtt.DeviceMqttIdentityManager;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class ProvisioningServiceTest {
    @Mock
    private ProvisioningMapper mapper;
    @Mock
    private DeviceMqttIdentityManager mqttIdentityManager;
    private ProvisioningService service;

    @BeforeEach
    void setUp() {
        service = new ProvisioningService(
            mapper, new DeviceCredentialProperties(Duration.ofMinutes(15), Duration.ofDays(30)),
            mqttIdentityManager);
    }

    @Test
    void provisionsDeviceAndReturnsPlaintextCredentialOnlyOnce() {
        UUID deviceId = UUID.randomUUID();
        when(mapper.insertDevice("SERIAL-001", "카메라", "WJ-01", null))
            .thenReturn(deviceId.toString());

        var response = service.provision(new ProvisionDeviceRequest("SERIAL-001", "카메라", "WJ-01", null));

        ArgumentCaptor<String> hash = ArgumentCaptor.forClass(String.class);
        verify(mapper).insertTokenCredential(
            org.mockito.ArgumentMatchers.eq(deviceId), anyString(), hash.capture(),
            org.mockito.ArgumentMatchers.eq("BOOTSTRAP"), org.mockito.ArgumentMatchers.any());
        assertThat(hash.getValue()).matches("[0-9a-f]{64}");
        assertThat(response.bearerToken()).startsWith(response.keyId() + ".");
        assertThat(response.bearerToken()).doesNotContain(hash.getValue());
    }

    @Test
    void rotatesCredentialTransactionally() {
        UUID deviceId = UUID.randomUUID();
        when(mapper.lockDeviceStatus(deviceId)).thenReturn(Optional.of("OFFLINE"));
        when(mapper.lockCurrentCredentialPurpose(deviceId)).thenReturn(Optional.of("OPERATING"));

        var response = service.rotate(deviceId);

        verify(mapper).revokeActiveCredentials(deviceId);
        verify(mapper).insertTokenCredential(
            org.mockito.ArgumentMatchers.eq(deviceId), anyString(), anyString(),
            org.mockito.ArgumentMatchers.eq("OPERATING"), org.mockito.ArgumentMatchers.any());
        assertThat(response.deviceId()).isEqualTo(deviceId);
    }

    @Test
    void exchangesBootstrapOnceAndCreatesDeviceScopedMqttIdentity() {
        UUID deviceId = UUID.randomUUID();
        when(mapper.lockDeviceStatus(deviceId)).thenReturn(Optional.of("UNCLAIMED"));
        when(mapper.lockActiveCredentialPurpose(deviceId, "bootstrap-key"))
            .thenReturn(Optional.of("BOOTSTRAP"));

        var response = service.enroll(deviceId, "bootstrap-key");

        verify(mapper).revokeActiveCredentials(deviceId);
        verify(mqttIdentityManager).create(deviceId, response.bearerToken());
        assertThat(response.purpose()).isEqualTo("OPERATING");
        assertThat(response.mqttUsername()).isEqualTo(deviceId.toString());
    }

    @Test
    void rejectsReplayedBootstrapCredentialBeforeIssuingAnotherSecret() {
        UUID deviceId = UUID.randomUUID();
        when(mapper.lockDeviceStatus(deviceId)).thenReturn(Optional.of("OFFLINE"));
        when(mapper.lockActiveCredentialPurpose(deviceId, "stale-key")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.enroll(deviceId, "stale-key"))
            .hasMessageContaining("no longer active");

        verify(mapper, never()).revokeActiveCredentials(deviceId);
        verify(mqttIdentityManager, never()).create(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyString());
    }
}
