package com.wj.server.provisioning.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.Optional;
import java.util.UUID;

import com.wj.server.provisioning.api.ProvisionDeviceRequest;
import com.wj.server.provisioning.persistence.ProvisioningMapper;
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
    private ProvisioningService service;

    @BeforeEach
    void setUp() {
        service = new ProvisioningService(mapper);
    }

    @Test
    void provisionsDeviceAndReturnsPlaintextCredentialOnlyOnce() {
        UUID deviceId = UUID.randomUUID();
        when(mapper.insertDevice("SERIAL-001", "카메라", "WJ-01", null)).thenReturn(deviceId);

        var response = service.provision(new ProvisionDeviceRequest("SERIAL-001", "카메라", "WJ-01", null));

        ArgumentCaptor<String> hash = ArgumentCaptor.forClass(String.class);
        verify(mapper).insertTokenCredential(
            org.mockito.ArgumentMatchers.eq(deviceId), anyString(), hash.capture());
        assertThat(hash.getValue()).matches("[0-9a-f]{64}");
        assertThat(response.bearerToken()).startsWith(response.keyId() + ".");
        assertThat(response.bearerToken()).doesNotContain(hash.getValue());
    }

    @Test
    void rotatesCredentialTransactionally() {
        UUID deviceId = UUID.randomUUID();
        when(mapper.findDeviceStatus(deviceId)).thenReturn(Optional.of("OFFLINE"));

        var response = service.rotate(deviceId);

        verify(mapper).revokeActiveCredentials(deviceId);
        verify(mapper).insertTokenCredential(
            org.mockito.ArgumentMatchers.eq(deviceId), anyString(), anyString());
        assertThat(response.deviceId()).isEqualTo(deviceId);
    }
}
