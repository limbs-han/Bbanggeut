package com.wj.server.notification.application;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

import com.wj.server.notification.domain.AnniversaryRow;
import com.wj.server.notification.domain.WeeklyReportRow;
import com.wj.server.notification.persistence.ReportNotificationMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class ReportNotificationSchedulerTest {
    // 2026-08-04 화요일 09:00 KST = 00:00 UTC
    private static final Clock TUESDAY =
        Clock.fixed(Instant.parse("2026-08-04T00:00:00Z"), ZoneOffset.UTC);
    // 2026-08-03 월요일
    private static final Clock MONDAY =
        Clock.fixed(Instant.parse("2026-08-03T00:00:00Z"), ZoneOffset.UTC);

    @Mock
    private ReportNotificationMapper mapper;
    @Mock
    private PushNotificationDispatcher pushDispatcher;

    @Test
    void anniversaryPushGoesOnlyWhenInsertHappened() {
        UUID scheduleId = UUID.randomUUID();
        UUID duplicated = UUID.randomUUID();
        UUID userA = UUID.randomUUID();
        UUID userB = UUID.randomUUID();
        when(mapper.findAnniversariesOn(any(), eq(8), eq(4))).thenReturn(List.of(
            new AnniversaryRow(scheduleId, userA, "결혼기념일", "", "❤️"),
            new AnniversaryRow(duplicated, userB, "생일", "미역국 먹는 날", "🎂")));
        when(mapper.insertAnniversaryNotification(
            eq(userA), eq(scheduleId), anyString(), anyString(), anyString())).thenReturn(1);
        when(mapper.insertAnniversaryNotification(
            eq(userB), eq(duplicated), anyString(), anyString(), anyString())).thenReturn(0);

        new ReportNotificationScheduler(mapper, pushDispatcher, TUESDAY).sendAnniversaries();

        verify(pushDispatcher).anniversary(
            eq(userA), eq(scheduleId), contains("결혼기념일"), anyString());
        verify(pushDispatcher, never()).anniversary(eq(userB), any(), any(), any());
    }

    @Test
    void anniversaryUsesMemoAsBodyWhenPresent() {
        UUID scheduleId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        when(mapper.findAnniversariesOn(any(), eq(8), eq(4))).thenReturn(List.of(
            new AnniversaryRow(scheduleId, userId, "생일", "미역국 먹는 날", "🎂")));
        when(mapper.insertAnniversaryNotification(
            eq(userId), eq(scheduleId), anyString(), eq("미역국 먹는 날"), anyString()))
            .thenReturn(1);

        new ReportNotificationScheduler(mapper, pushDispatcher, TUESDAY).sendAnniversaries();

        verify(pushDispatcher).anniversary(
            eq(userId), eq(scheduleId), anyString(), eq("미역국 먹는 날"));
    }

    @Test
    void weeklyReportAggregatesPreviousWeekAndDedupes() {
        UUID userA = UUID.randomUUID();
        UUID userB = UUID.randomUUID();
        // 2026-08-03(월) 실행 → 지난주 7/27(월)~8/2(일) KST
        Instant expectedFrom = Instant.parse("2026-07-26T15:00:00Z");
        Instant expectedTo = Instant.parse("2026-08-02T15:00:00Z");
        when(mapper.findWeeklyReportTargets(expectedFrom, expectedTo)).thenReturn(List.of(
            new WeeklyReportRow(userA, 12),
            new WeeklyReportRow(userB, 0)));
        when(mapper.insertWeeklyReportNotification(
            eq(userA), anyString(), contains("12번"), contains("2026-W31"))).thenReturn(1);
        when(mapper.insertWeeklyReportNotification(
            eq(userB), anyString(), anyString(), anyString())).thenReturn(0);

        new ReportNotificationScheduler(mapper, pushDispatcher, MONDAY).sendWeeklyReports();

        verify(pushDispatcher).weeklyReport(eq(userA), contains("12번"));
        verify(pushDispatcher, never()).weeklyReport(eq(userB), anyString());
    }

    @Test
    void startupCatchUpSkipsBeforeSendTime() {
        // 2026-08-04 07:00 KST = 08-03 22:00 UTC — 발송 시각 전 재시작
        Clock beforeNine = Clock.fixed(Instant.parse("2026-08-03T22:00:00Z"), ZoneOffset.UTC);

        new ReportNotificationScheduler(mapper, pushDispatcher, beforeNine)
            .catchUpAfterStartup();

        verifyNoInteractions(mapper, pushDispatcher);
    }

    @Test
    void startupCatchUpRunsBothSendsAfterSendTime() {
        // 2026-08-04 화요일 10:00 KST = 01:00 UTC — 09:00을 지난 재시작
        Clock afterNine = Clock.fixed(Instant.parse("2026-08-04T01:00:00Z"), ZoneOffset.UTC);
        when(mapper.findAnniversariesOn(any(), eq(8), eq(4))).thenReturn(List.of());
        when(mapper.findWeeklyReportTargets(any(), any())).thenReturn(List.of());

        new ReportNotificationScheduler(mapper, pushDispatcher, afterNine)
            .catchUpAfterStartup();

        verify(mapper).findAnniversariesOn(any(), eq(8), eq(4));
        verify(mapper).findWeeklyReportTargets(any(), any());
    }

    @Test
    void noTargetsMeansNoPush() {
        when(mapper.findAnniversariesOn(any(), eq(8), eq(4))).thenReturn(List.of());

        new ReportNotificationScheduler(mapper, pushDispatcher, TUESDAY).sendAnniversaries();

        verifyNoInteractions(pushDispatcher);
    }
}
