package com.wj.server.vault.persistence;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.wj.server.vault.domain.VaultDeviceCountRow;
import com.wj.server.video.domain.DailyVideoCountRow;
import com.wj.server.video.domain.VideoCountRow;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

/**
 * 금고(가족) 단위 이벤트 집계. 이벤트에는 vault_id가 없으므로
 * device_bindings의 [bound_at, ended_at) 구간과 occurred_at을 겹쳐,
 * "이 금고에 묶여 있던 동안 그 기기에서 일어난 이벤트"만 센다 —
 * 기기가 다른 금고로 양도돼도 과거 금고의 통계는 오염되지 않는다.
 */
@Mapper
public interface VaultEventStatsMapper {
    String BOUND_EVENTS = """
          FROM device_events e
          JOIN device_bindings b
            ON b.device_id = e.device_id
           AND b.vault_id = #{vaultId}
           AND e.occurred_at &gt;= b.bound_at
           AND (b.ended_at IS NULL OR e.occurred_at &lt; b.ended_at)
         WHERE e.occurred_at &gt;= #{from} AND e.occurred_at &lt; #{to}
        """;

    @Select("""
        <script>
        SELECT count(*)
        """ + BOUND_EVENTS + """
        <if test="type != null">
           AND e.event_type = #{type}
        </if>
        </script>
        """)
    long countEvents(
        @Param("vaultId") UUID vaultId,
        @Param("from") Instant from,
        @Param("to") Instant to,
        @Param("type") String type
    );

    @Select("""
        <script>
        SELECT count(*)
        """ + BOUND_EVENTS + """
           AND e.upload_status = 'READY'
        </script>
        """)
    long countReadyUploads(
        @Param("vaultId") UUID vaultId,
        @Param("from") Instant from,
        @Param("to") Instant to
    );

    @Select("""
        <script>
        SELECT e.event_type AS label, count(*) AS count
        """ + BOUND_EVENTS + """
         GROUP BY e.event_type
         ORDER BY count DESC, label
        </script>
        """)
    List<VideoCountRow> countByType(
        @Param("vaultId") UUID vaultId,
        @Param("from") Instant from,
        @Param("to") Instant to
    );

    @Select("""
        <script>
        SELECT e.device_id AS deviceId, d.name AS name, count(*) AS count
          FROM device_events e
          JOIN device_bindings b
            ON b.device_id = e.device_id
           AND b.vault_id = #{vaultId}
           AND e.occurred_at &gt;= b.bound_at
           AND (b.ended_at IS NULL OR e.occurred_at &lt; b.ended_at)
          JOIN devices d ON d.id = e.device_id
         WHERE e.occurred_at &gt;= #{from} AND e.occurred_at &lt; #{to}
        <if test="type != null">
           AND e.event_type = #{type}
        </if>
         GROUP BY e.device_id, d.name
         ORDER BY count DESC, name
        </script>
        """)
    List<VaultDeviceCountRow> countByDevice(
        @Param("vaultId") UUID vaultId,
        @Param("from") Instant from,
        @Param("to") Instant to,
        @Param("type") String type
    );

    @Select("""
        <script>
        SELECT (e.occurred_at AT TIME ZONE #{zoneId})::date AS date, count(*) AS count
        """ + BOUND_EVENTS + """
        <if test="type != null">
           AND e.event_type = #{type}
        </if>
         GROUP BY date
         ORDER BY date
        </script>
        """)
    List<DailyVideoCountRow> countByDay(
        @Param("vaultId") UUID vaultId,
        @Param("from") Instant from,
        @Param("to") Instant to,
        @Param("zoneId") String zoneId,
        @Param("type") String type
    );
}
