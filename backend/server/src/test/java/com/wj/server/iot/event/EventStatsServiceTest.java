package com.wj.server.iot.event;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class EventStatsServiceTest {
    private static final Clock FIXED =
        Clock.fixed(Instant.parse("2026-08-04T00:00:00Z"), ZoneOffset.UTC);

    @Mock
    private DeviceEventMapper mapper;

    @Test
    void typeFilterIsNormalizedAndPassedToCounts() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.hasActiveMembership(userId, deviceId)).thenReturn(true);
        when(mapper.countEvents(eq(deviceId), any(), any(), eq("LAUGHTER"))).thenReturn(3L);
        when(mapper.countByType(eq(deviceId), any(), any())).thenReturn(List.of());
        when(mapper.countByDay(eq(deviceId), any(), any(), any(), eq("LAUGHTER")))
            .thenReturn(List.of());

        var result = new EventStatsService(mapper, FIXED)
            .get(userId, deviceId, null, null, null, " laughter ");

        assertThat(result.detectedCount()).isEqualTo(3L);
    }

    @Test
    void blankTypeMeansNoFilter() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.hasActiveMembership(userId, deviceId)).thenReturn(true);
        when(mapper.countEvents(eq(deviceId), any(), any(), eq((String) null))).thenReturn(7L);
        when(mapper.countByType(eq(deviceId), any(), any())).thenReturn(List.of());
        when(mapper.countByDay(eq(deviceId), any(), any(), any(), eq((String) null)))
            .thenReturn(List.of());

        var result = new EventStatsService(mapper, FIXED)
            .get(userId, deviceId, null, null, null, "  ");

        assertThat(result.detectedCount()).isEqualTo(7L);
    }

    @Test
    void malformedTypeIsRejected() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.hasActiveMembership(userId, deviceId)).thenReturn(true);

        assertThatThrownBy(() -> new EventStatsService(mapper, FIXED)
            .get(userId, deviceId, null, null, null, "laughter; drop table"))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "VALIDATION_FAILED");
    }
}
