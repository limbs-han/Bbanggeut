package com.wj.server.notification.persistence;

import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import com.wj.server.notification.domain.AnniversaryRow;
import com.wj.server.notification.domain.WeeklyReportRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface ReportNotificationMapper {
    /**
     * 오늘이 기념일인 일정 — 정확히 오늘이거나, 매년 반복이 월·일로 맞는 것.
     * 알림 설정(anniversary_alerts)을 끈 사용자는 제외하고, 행이 없으면
     * 켜진 것으로 본다.
     */
    @Select("""
        SELECT s.id AS scheduleId, s.user_id AS userId, s.title, s.memo, s.emoji
          FROM user_schedules s
          JOIN users u ON u.id = s.user_id
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
          LEFT JOIN user_notification_preferences p ON p.user_id = s.user_id
         WHERE COALESCE(p.anniversary_alerts, true)
           AND (
                s.schedule_date = #{today}
                OR (
                    s.yearly
                    AND EXTRACT(MONTH FROM s.schedule_date) = #{month}
                    AND EXTRACT(DAY FROM s.schedule_date) = #{day}
                )
           )
         ORDER BY s.user_id, s.id
        """)
    List<AnniversaryRow> findAnniversariesOn(
        @Param("today") LocalDate today,
        @Param("month") int month,
        @Param("day") int day
    );

    @Insert("""
        INSERT INTO notifications (id, user_id, type, title, body, resource_id, dedupe_key)
        VALUES (
            gen_random_uuid(), #{userId}, 'ANNIVERSARY', #{title}, #{body},
            #{scheduleId}, #{dedupeKey}
        )
        ON CONFLICT (user_id, dedupe_key) DO NOTHING
        """)
    int insertAnniversaryNotification(
        @Param("userId") UUID userId,
        @Param("scheduleId") UUID scheduleId,
        @Param("title") String title,
        @Param("body") String body,
        @Param("dedupeKey") String dedupeKey
    );

    /**
     * 주간 리포트 대상 — 활성 금고 멤버십과 활성 기기 Binding이 있는 사용자.
     * 웃음 수는 그 금고들에 지금 묶여 있는 기기의 지난주 LAUGHTER 이벤트 합계다.
     */
    @Select("""
        SELECT m.user_id AS userId, count(e.id) AS laughCount
          FROM vault_memberships m
          JOIN users u ON u.id = m.user_id
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
          LEFT JOIN user_notification_preferences p ON p.user_id = m.user_id
          JOIN device_bindings b ON b.vault_id = m.vault_id AND b.status = 'ACTIVE'
          LEFT JOIN device_events e
            ON e.device_id = b.device_id
           AND e.event_type = 'LAUGHTER'
           AND e.occurred_at >= #{from} AND e.occurred_at < #{to}
         WHERE m.status = 'ACTIVE'
           AND COALESCE(p.weekly_report, true)
         GROUP BY m.user_id
         ORDER BY m.user_id
        """)
    List<WeeklyReportRow> findWeeklyReportTargets(
        @Param("from") Instant from,
        @Param("to") Instant to
    );

    @Insert("""
        INSERT INTO notifications (id, user_id, type, title, body, dedupe_key)
        VALUES (gen_random_uuid(), #{userId}, 'WEEKLY_REPORT', #{title}, #{body}, #{dedupeKey})
        ON CONFLICT (user_id, dedupe_key) DO NOTHING
        """)
    int insertWeeklyReportNotification(
        @Param("userId") UUID userId,
        @Param("title") String title,
        @Param("body") String body,
        @Param("dedupeKey") String dedupeKey
    );
}
