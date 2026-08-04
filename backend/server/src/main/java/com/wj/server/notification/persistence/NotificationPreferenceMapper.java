package com.wj.server.notification.persistence;

import java.util.Optional;
import java.util.UUID;

import com.wj.server.notification.domain.NotificationPreferenceRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface NotificationPreferenceMapper {
    @Select("""
        SELECT anniversary_alerts AS anniversaryAlerts,
               weekly_report AS weeklyReport,
               new_memory_alerts AS newMemoryAlerts
          FROM user_notification_preferences
         WHERE user_id = #{userId}
        """)
    Optional<NotificationPreferenceRow> findForUser(@Param("userId") UUID userId);

    @Insert("""
        INSERT INTO user_notification_preferences (
            user_id, anniversary_alerts, weekly_report, new_memory_alerts
        ) VALUES (
            #{userId}, #{anniversaryAlerts}, #{weeklyReport}, #{newMemoryAlerts}
        )
        ON CONFLICT (user_id) DO UPDATE
            SET anniversary_alerts = EXCLUDED.anniversary_alerts,
                weekly_report = EXCLUDED.weekly_report,
                new_memory_alerts = EXCLUDED.new_memory_alerts,
                updated_at = now()
        """)
    int upsert(
        @Param("userId") UUID userId,
        @Param("anniversaryAlerts") boolean anniversaryAlerts,
        @Param("weeklyReport") boolean weeklyReport,
        @Param("newMemoryAlerts") boolean newMemoryAlerts
    );
}
