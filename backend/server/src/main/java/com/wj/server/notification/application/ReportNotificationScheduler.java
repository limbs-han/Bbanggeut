package com.wj.server.notification.application;

import java.time.Clock;
import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.temporal.TemporalAdjusters;
import java.time.temporal.WeekFields;

import com.wj.server.notification.domain.AnniversaryRow;
import com.wj.server.notification.domain.WeeklyReportRow;
import com.wj.server.notification.persistence.ReportNotificationMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * 기념일(일정 D-day)과 주간 웃음 리포트 발송기. 알림 설정(API-78·79)의
 * 토글은 저장만 되고 실제 발송기가 없었다.
 *
 * <p>이중화에도 안전하다 — 알림 INSERT가 (user_id, dedupe_key)로 유일하고
 * 푸시는 삽입이 실제로 일어난 행에만 나가므로, 인스턴스 두 대가 같은
 * 시각에 돌아도 사용자당 한 번만 발송된다.
 */
@Component
public class ReportNotificationScheduler {
    private static final Logger log = LoggerFactory.getLogger(ReportNotificationScheduler.class);
    private static final ZoneId ZONE = ZoneId.of("Asia/Seoul");

    private final ReportNotificationMapper mapper;
    private final PushNotificationDispatcher pushDispatcher;
    private final Clock clock;

    @Autowired
    public ReportNotificationScheduler(
        ReportNotificationMapper mapper, PushNotificationDispatcher pushDispatcher
    ) {
        this(mapper, pushDispatcher, Clock.systemUTC());
    }

    ReportNotificationScheduler(
        ReportNotificationMapper mapper,
        PushNotificationDispatcher pushDispatcher,
        Clock clock
    ) {
        this.mapper = mapper;
        this.pushDispatcher = pushDispatcher;
        this.clock = clock;
    }

    /** 매일 09:00 KST — 오늘이 기념일인 일정을 사용자에게 알린다. */
    @Scheduled(cron = "0 0 9 * * *", zone = "Asia/Seoul")
    @Transactional
    public void sendAnniversaries() {
        LocalDate today = LocalDate.now(clock.withZone(ZONE));
        int sent = 0;
        for (AnniversaryRow row : mapper.findAnniversariesOn(
            today, today.getMonthValue(), today.getDayOfMonth())) {
            String title = row.emoji() + " 오늘은 " + row.title() + " 이에요";
            String body = row.memo() == null || row.memo().isBlank()
                ? "등록해 둔 기념일이 돌아왔어요. 오늘의 순간을 남겨 보세요."
                : row.memo();
            String dedupeKey = "anniversary:" + row.scheduleId() + ":" + today.getYear();
            if (mapper.insertAnniversaryNotification(
                row.userId(), row.scheduleId(), title, body, dedupeKey) > 0) {
                pushDispatcher.anniversary(row.userId(), row.scheduleId(), title, body);
                sent++;
            }
        }
        if (sent > 0) {
            log.info("Anniversary notifications sent count={} date={}", sent, today);
        }
    }

    /** 매주 월요일 09:00 KST — 지난주(월~일) 가족 웃음 합계를 알린다. */
    @Scheduled(cron = "0 0 9 * * MON", zone = "Asia/Seoul")
    @Transactional
    public void sendWeeklyReports() {
        LocalDate today = LocalDate.now(clock.withZone(ZONE));
        LocalDate thisMonday = today.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY));
        LocalDate lastMonday = thisMonday.minusWeeks(1);
        var from = lastMonday.atStartOfDay(ZONE).toInstant();
        var to = thisMonday.atStartOfDay(ZONE).toInstant();
        int week = lastMonday.get(WeekFields.ISO.weekOfWeekBasedYear());
        int weekYear = lastMonday.get(WeekFields.ISO.weekBasedYear());

        int sent = 0;
        for (WeeklyReportRow row : mapper.findWeeklyReportTargets(from, to)) {
            String body = row.laughCount() > 0
                ? "지난주 우리 가족이 " + row.laughCount() + "번 웃었어요. 리포트에서 확인해 보세요!"
                : "지난주에는 기록된 웃음이 없었어요. 이번 주엔 빵긋 웃어 봐요!";
            String dedupeKey = "weekly-report:" + row.userId() + ":" + weekYear + "-W" + week;
            if (mapper.insertWeeklyReportNotification(
                row.userId(), "주간 웃음 리포트", body, dedupeKey) > 0) {
                pushDispatcher.weeklyReport(row.userId(), body);
                sent++;
            }
        }
        if (sent > 0) {
            log.info("Weekly report notifications sent count={} week={}-W{}", sent, weekYear, week);
        }
    }
}
