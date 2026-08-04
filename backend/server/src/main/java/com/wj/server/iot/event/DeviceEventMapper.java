package com.wj.server.iot.event;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.wj.server.video.domain.DailyVideoCountRow;
import com.wj.server.video.domain.VideoCountRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface DeviceEventMapper {
    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM device_memberships
             WHERE device_id = #{deviceId} AND user_id = #{userId} AND status = 'ACTIVE'
        )
        """)
    boolean hasActiveMembership(@Param("userId") UUID userId, @Param("deviceId") UUID deviceId);

    @Insert("""
        INSERT INTO device_events (
            id, device_id, event_type, occurred_at, confidence, local_clip_state,
            before_ms, after_ms, merge_window_ms, source_node_id, source_component,
            source_model_version
        )
        SELECT
            #{event.id}, #{event.deviceId}, #{event.type}, #{event.occurredAt},
            #{event.confidence}, #{event.localClipState}, #{event.beforeMs},
            #{event.afterMs}, #{event.mergeWindowMs}, #{event.sourceNodeId},
            #{event.sourceComponent}, #{event.sourceModelVersion}
          FROM devices
         WHERE id = #{event.deviceId} AND status IN ('ONLINE', 'OFFLINE')
        ON CONFLICT (id) DO NOTHING
        """)
    int insert(@Param("event") DeviceEvent event);

    @Insert("""
        INSERT INTO device_events (
            id, device_id, event_type, occurred_at, source_component, upload_status
        ) VALUES (
            #{eventId}, #{deviceId}, #{eventType}, #{occurredAt}, 'HTTP_UPLOAD_RECOVERY', 'UPLOADING'
        )
        ON CONFLICT (id) DO NOTHING
        """)
    int insertUploadRecovery(
        @Param("eventId") UUID eventId,
        @Param("deviceId") UUID deviceId,
        @Param("eventType") String eventType,
        @Param("occurredAt") Instant occurredAt
    );

    @Update("""
        UPDATE device_events
           SET video_id = #{videoId}, upload_status = #{status}, updated_at = now()
         WHERE id = #{eventId} AND device_id = #{deviceId}
        """)
    int linkVideo(
        @Param("deviceId") UUID deviceId,
        @Param("eventId") UUID eventId,
        @Param("videoId") UUID videoId,
        @Param("status") String status
    );

    @Select("""
        <script>
        SELECT count(*)
          FROM device_events
         WHERE device_id = #{deviceId}
           AND occurred_at &gt;= #{from} AND occurred_at &lt; #{to}
        <if test="type != null">
           AND event_type = #{type}
        </if>
        </script>
        """)
    long countEvents(
        @Param("deviceId") UUID deviceId,
        @Param("from") Instant from,
        @Param("to") Instant to,
        @Param("type") String type
    );

    @Select("""
        SELECT count(*)
          FROM device_events
         WHERE device_id = #{deviceId} AND upload_status = 'READY'
           AND occurred_at >= #{from} AND occurred_at < #{to}
        """)
    long countReadyUploads(
        @Param("deviceId") UUID deviceId,
        @Param("from") Instant from,
        @Param("to") Instant to
    );

    @Select("""
        SELECT event_type AS label, count(*) AS count
          FROM device_events
         WHERE device_id = #{deviceId}
           AND occurred_at >= #{from} AND occurred_at < #{to}
         GROUP BY event_type
         ORDER BY count DESC, label
        """)
    List<VideoCountRow> countByType(
        @Param("deviceId") UUID deviceId,
        @Param("from") Instant from,
        @Param("to") Instant to
    );

    @Select("""
        <script>
        SELECT (occurred_at AT TIME ZONE #{zoneId})::date AS date, count(*) AS count
          FROM device_events
         WHERE device_id = #{deviceId}
           AND occurred_at &gt;= #{from} AND occurred_at &lt; #{to}
        <if test="type != null">
           AND event_type = #{type}
        </if>
         GROUP BY date
         ORDER BY date
        </script>
        """)
    List<DailyVideoCountRow> countByDay(
        @Param("deviceId") UUID deviceId,
        @Param("from") Instant from,
        @Param("to") Instant to,
        @Param("zoneId") String zoneId,
        @Param("type") String type
    );

}
