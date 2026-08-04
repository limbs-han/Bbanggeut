package com.wj.server.schedule.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.schedule.api.ScheduleRequest;
import com.wj.server.schedule.domain.ScheduleRow;
import com.wj.server.schedule.persistence.ScheduleMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class ScheduleServiceTest {
    @Mock
    private ScheduleMapper mapper;

    @Test
    void listMapsRowsToResponses() {
        UUID userId = UUID.randomUUID();
        UUID scheduleId = UUID.randomUUID();
        when(mapper.findForUser(userId)).thenReturn(List.of(new ScheduleRow(
            scheduleId, userId, "결혼기념일", LocalDate.of(2026, 5, 2), "", true, "❤️")));

        var result = new ScheduleService(mapper).list(userId);

        assertThat(result).hasSize(1);
        assertThat(result.get(0).id()).isEqualTo(scheduleId);
        assertThat(result.get(0).yearly()).isTrue();
    }

    @Test
    void createFillsDefaultsAndTrimsTitle() {
        UUID userId = UUID.randomUUID();
        when(mapper.countForUser(userId)).thenReturn(0L);

        var result = new ScheduleService(mapper).create(userId, new ScheduleRequest(
            "  생일  ", LocalDate.of(2026, 9, 1), null, null, null));

        assertThat(result.title()).isEqualTo("생일");
        assertThat(result.memo()).isEmpty();
        assertThat(result.yearly()).isFalse();
        assertThat(result.emoji()).isEqualTo("❤️");
        verify(mapper).insert(
            eq(result.id()), eq(userId), eq("생일"), eq(LocalDate.of(2026, 9, 1)),
            eq(""), eq(false), eq("❤️"));
    }

    @Test
    void createRejectsWhenUserReachedCap() {
        UUID userId = UUID.randomUUID();
        when(mapper.countForUser(userId))
            .thenReturn((long) ScheduleService.MAX_SCHEDULES_PER_USER);

        assertThatThrownBy(() -> new ScheduleService(mapper).create(userId,
            new ScheduleRequest("생일", LocalDate.of(2026, 9, 1), null, null, null)))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "VALIDATION_FAILED");
        verify(mapper, never()).insert(
            any(), any(), anyString(), any(), anyString(), anyBoolean(), anyString());
    }

    @Test
    void updateOfMissingOrForeignScheduleIsNotFound() {
        UUID userId = UUID.randomUUID();
        UUID scheduleId = UUID.randomUUID();
        when(mapper.update(
            eq(scheduleId), eq(userId), anyString(), any(), anyString(),
            anyBoolean(), anyString())).thenReturn(0);

        assertThatThrownBy(() -> new ScheduleService(mapper).update(userId, scheduleId,
            new ScheduleRequest("생일", LocalDate.of(2026, 9, 1), "메모", true, "🎂")))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "RESOURCE_NOT_FOUND");
    }

    @Test
    void deleteOfMissingOrForeignScheduleIsNotFound() {
        UUID userId = UUID.randomUUID();
        UUID scheduleId = UUID.randomUUID();
        when(mapper.delete(scheduleId, userId)).thenReturn(0);

        assertThatThrownBy(() -> new ScheduleService(mapper).delete(userId, scheduleId))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "RESOURCE_NOT_FOUND");
    }
}
