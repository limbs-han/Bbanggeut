package com.wj.server.video.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

import com.wj.server.video.domain.DailyVideoCountRow;
import com.wj.server.video.domain.VideoCountRow;
import com.wj.server.video.persistence.VideoMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class VideoStatsServiceTest {
    @Mock
    private VideoMapper mapper;

    @Test
    void returnsMembershipScopedAggregatesInRequestedTimeZone() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.hasActiveMembership(userId, deviceId)).thenReturn(true);
        when(mapper.countReadyVideos(eq(deviceId), any(), any())).thenReturn(3L);
        when(mapper.countReadyVideosByTrigger(eq(deviceId), any(), any()))
            .thenReturn(List.of(new VideoCountRow("TOUCH", 3)));
        when(mapper.countReadyVideosByDay(eq(deviceId), any(), any(), eq("Asia/Seoul")))
            .thenReturn(List.of(new DailyVideoCountRow(LocalDate.of(2026, 7, 20), 3)));
        when(mapper.countReadyVideosByWeekday(eq(deviceId), any(), any(), eq("Asia/Seoul")))
            .thenReturn(List.of(new VideoCountRow("1", 3)));
        when(mapper.countReadyVideosByHour(eq(deviceId), any(), any(), eq("Asia/Seoul")))
            .thenReturn(List.of(new VideoCountRow("14", 3)));
        VideoStatsService service = new VideoStatsService(
            mapper, Clock.fixed(Instant.parse("2026-07-20T12:00:00Z"), ZoneOffset.UTC));

        var response = service.get(
            userId, deviceId, LocalDate.of(2026, 7, 1), LocalDate.of(2026, 7, 20), "Asia/Seoul");

        assertThat(response.totalCount()).isEqualTo(3);
        assertThat(response.byTriggerType()).extracting(item -> item.name()).containsExactly("TOUCH");
        assertThat(response.peakWeekday().name()).isEqualTo("MONDAY");
        assertThat(response.peakHour().name()).isEqualTo("14:00");
    }
}
