package com.wj.server.schedule.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
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

    private static ScheduleRow row(UUID id, UUID userId, UUID vaultId) {
        return new ScheduleRow(
            id, userId, vaultId, "엄마", "결혼기념일",
            LocalDate.of(2026, 5, 2), "", true, "❤️");
    }

    private static ScheduleRequest request(UUID vaultId) {
        return new ScheduleRequest(
            "  생일  ", LocalDate.of(2026, 9, 1), null, null, null, vaultId);
    }

    @Test
    void listShowsSchedulesOfEveryVaultTheUserBelongsTo() {
        UUID userId = UUID.randomUUID();
        UUID scheduleId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        when(mapper.findVisible(userId))
            .thenReturn(List.of(row(scheduleId, userId, vaultId)));

        var result = new ScheduleService(mapper).list(userId);

        assertThat(result).hasSize(1);
        assertThat(result.get(0).id()).isEqualTo(scheduleId);
        assertThat(result.get(0).authorId()).isEqualTo(userId);
        assertThat(result.get(0).authorName()).isEqualTo("엄마");
        assertThat(result.get(0).yearly()).isTrue();
    }

    @Test
    void createPutsScheduleInTheOnlyVaultWhenNoneRequested() {
        UUID userId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        UUID scheduleId = UUID.randomUUID();
        when(mapper.findActiveVaultIds(userId)).thenReturn(List.of(vaultId));
        when(mapper.countInScope(userId, vaultId)).thenReturn(0L);
        when(mapper.findById(any()))
            .thenReturn(Optional.of(row(scheduleId, userId, vaultId)));

        var result = new ScheduleService(mapper).create(userId, request(null));

        assertThat(result.id()).isEqualTo(scheduleId);
        verify(mapper).insert(
            any(), eq(userId), eq(vaultId), eq("생일"), eq(LocalDate.of(2026, 9, 1)),
            eq(""), eq(false), eq("❤️"));
    }

    @Test
    void createRejectsAVaultTheUserDoesNotBelongTo() {
        // 남의 가족 캘린더에 일정을 밀어 넣을 수 없어야 한다.
        UUID userId = UUID.randomUUID();
        UUID foreignVault = UUID.randomUUID();
        when(mapper.isActiveMember(userId, foreignVault)).thenReturn(false);

        assertThatThrownBy(
            () -> new ScheduleService(mapper).create(userId, request(foreignVault)))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "FORBIDDEN_ROLE");
        verify(mapper, never()).insert(
            any(), any(), any(), anyString(), any(), anyString(), anyBoolean(), anyString());
    }

    @Test
    void createAsksWhichVaultWhenTheUserBelongsToSeveral() {
        UUID userId = UUID.randomUUID();
        when(mapper.findActiveVaultIds(userId))
            .thenReturn(List.of(UUID.randomUUID(), UUID.randomUUID()));

        assertThatThrownBy(() -> new ScheduleService(mapper).create(userId, request(null)))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "VALIDATION_FAILED");
    }

    @Test
    void createKeepsWorkingForUsersWithoutAnyVault() {
        // 금고가 없으면 예전처럼 개인 일정이 된다.
        UUID userId = UUID.randomUUID();
        UUID scheduleId = UUID.randomUUID();
        when(mapper.findActiveVaultIds(userId)).thenReturn(List.of());
        when(mapper.countInScope(userId, null)).thenReturn(0L);
        when(mapper.findById(any()))
            .thenReturn(Optional.of(row(scheduleId, userId, null)));

        var result = new ScheduleService(mapper).create(userId, request(null));

        assertThat(result.id()).isEqualTo(scheduleId);
        verify(mapper).insert(
            any(), eq(userId), eq(null), eq("생일"), eq(LocalDate.of(2026, 9, 1)),
            eq(""), eq(false), eq("❤️"));
    }

    @Test
    void createRejectsWhenVaultReachedCap() {
        UUID userId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        when(mapper.findActiveVaultIds(userId)).thenReturn(List.of(vaultId));
        when(mapper.countInScope(userId, vaultId))
            .thenReturn((long) ScheduleService.MAX_SCHEDULES_PER_VAULT);

        assertThatThrownBy(() -> new ScheduleService(mapper).create(userId, request(null)))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "VALIDATION_FAILED");
        verify(mapper, never()).insert(
            any(), any(), any(), anyString(), any(), anyString(), anyBoolean(), anyString());
    }

    @Test
    void updatingSomeoneElsesScheduleSaysItIsForbidden() {
        // 목록에 보이는 일정이므로 존재를 숨길 이유가 없다 — 왜 안 되는지 알려준다.
        UUID userId = UUID.randomUUID();
        UUID author = UUID.randomUUID();
        UUID scheduleId = UUID.randomUUID();
        UUID vaultId = UUID.randomUUID();
        when(mapper.update(
            eq(scheduleId), eq(userId), anyString(), any(), anyString(),
            anyBoolean(), anyString())).thenReturn(0);
        when(mapper.findById(scheduleId))
            .thenReturn(Optional.of(row(scheduleId, author, vaultId)));
        when(mapper.findVisible(userId))
            .thenReturn(List.of(row(scheduleId, author, vaultId)));

        assertThatThrownBy(() -> new ScheduleService(mapper).update(userId, scheduleId,
            new ScheduleRequest("생일", LocalDate.of(2026, 9, 1), "메모", true, "🎂", null)))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "FORBIDDEN_ROLE");
    }

    @Test
    void updateOfMissingScheduleIsNotFound() {
        UUID userId = UUID.randomUUID();
        UUID scheduleId = UUID.randomUUID();
        when(mapper.update(
            eq(scheduleId), eq(userId), anyString(), any(), anyString(),
            anyBoolean(), anyString())).thenReturn(0);
        when(mapper.findById(scheduleId)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> new ScheduleService(mapper).update(userId, scheduleId,
            new ScheduleRequest("생일", LocalDate.of(2026, 9, 1), "메모", true, "🎂", null)))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "RESOURCE_NOT_FOUND");
    }

    @Test
    void deleteOfInvisibleScheduleStaysHidden() {
        // 다른 가족의 일정은 존재 자체를 알려주지 않는다.
        UUID userId = UUID.randomUUID();
        UUID scheduleId = UUID.randomUUID();
        when(mapper.delete(scheduleId, userId)).thenReturn(0);
        when(mapper.findById(scheduleId)).thenReturn(
            Optional.of(row(scheduleId, UUID.randomUUID(), UUID.randomUUID())));
        lenient().when(mapper.findVisible(userId)).thenReturn(List.of());

        assertThatThrownBy(() -> new ScheduleService(mapper).delete(userId, scheduleId))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "RESOURCE_NOT_FOUND");
    }
}
