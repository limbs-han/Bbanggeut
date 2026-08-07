package com.wj.server.device.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.device.persistence.RegistrationCodeMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.dao.DuplicateKeyException;

@ExtendWith(MockitoExtension.class)
class RegistrationCodeServiceTest {
    private static final Instant NOW = Instant.parse("2026-07-17T10:00:00Z");
    private static final Instant EXPIRES = NOW.plusSeconds(120);

    @Mock
    private RegistrationCodeMapper mapper;

    private RegistrationCodeService service;

    @BeforeEach
    void setUp() {
        service = new RegistrationCodeService(
            mapper, new RegistrationCodeGenerator(), new RegistrationCodeHasher(),
            Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void issuesDisplayFormattedCodeWithTtlAndInvalidatesOldCodes() {
        UUID deviceId = UUID.randomUUID();
        when(mapper.refreshRegistrationMode(deviceId, EXPIRES)).thenReturn(1);
        when(mapper.hashExists(anyString())).thenReturn(false);
        when(mapper.insertCode(eq(deviceId), anyString(), eq(EXPIRES))).thenReturn(1);

        var response = service.issue(deviceId);

        verify(mapper).deleteUnusedCodes(deviceId);
        assertThat(response.registrationCode()).matches("[0-9A-Z]{4}-[0-9A-Z]{4}");
        assertThat(response.registrationCode()).doesNotContain("O", "I", "L", "U");
        assertThat(response.expiresAt()).isEqualTo(EXPIRES);
    }

    @Test
    void refusesClaimedDevice() {
        UUID deviceId = UUID.randomUUID();
        when(mapper.refreshRegistrationMode(deviceId, EXPIRES)).thenReturn(0);

        assertThatThrownBy(() -> service.issue(deviceId))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("DEVICE_ALREADY_CLAIMED");
        verify(mapper, org.mockito.Mockito.never()).insertCode(any(), anyString(), any());
    }

    @Test
    void retriesOnHashCollision() {
        UUID deviceId = UUID.randomUUID();
        when(mapper.refreshRegistrationMode(deviceId, EXPIRES)).thenReturn(1);
        when(mapper.hashExists(anyString())).thenReturn(true).thenReturn(false);
        when(mapper.insertCode(eq(deviceId), anyString(), eq(EXPIRES))).thenReturn(1);

        var response = service.issue(deviceId);

        assertThat(response.registrationCode()).isNotBlank();
        verify(mapper, org.mockito.Mockito.times(2)).hashExists(anyString());
        verify(mapper, org.mockito.Mockito.times(1)).insertCode(eq(deviceId), anyString(), eq(EXPIRES));
    }
}
