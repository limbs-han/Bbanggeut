package com.wj.server.stream.persistence;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.stream.domain.DeviceStreamRow;
import com.wj.server.stream.domain.StreamSessionRow;
import com.wj.server.stream.domain.TalkbackRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface StreamMapper {
    @Select("SELECT pg_advisory_xact_lock(hashtextextended(CAST(#{deviceId} AS text), 0))")
    String lockDevice(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT m.role::text
          FROM device_memberships m JOIN devices d ON d.id = m.device_id
         WHERE m.device_id = #{deviceId} AND m.user_id = #{userId}
           AND m.status = 'ACTIVE' AND d.status != 'REVOKED'
        """)
    Optional<String> findActiveRole(@Param("userId") UUID userId, @Param("deviceId") UUID deviceId);

    @Select("""
        SELECT d.status::text FROM devices d
        JOIN device_memberships m ON m.device_id = d.id
         WHERE d.id = #{deviceId} AND m.user_id = #{userId} AND m.status = 'ACTIVE'
        """)
    Optional<String> findAccessibleDeviceStatus(
        @Param("userId") UUID userId,
        @Param("deviceId") UUID deviceId
    );

    @Select("""
        SELECT id, device_id, status::text, edge_hard_expires_at, stop_deadline_at, failure_code
          FROM device_streams
         WHERE device_id = #{deviceId} AND status IN ('STARTING', 'RUNNING', 'STOP_PENDING')
         FOR UPDATE
        """)
    Optional<DeviceStreamRow> findReusableStream(@Param("deviceId") UUID deviceId);

    @Insert("""
        INSERT INTO device_streams (id, device_id, status, edge_hard_expires_at)
        VALUES (#{streamId}, #{deviceId}, 'STARTING', #{edgeHardExpiresAt})
        """)
    int insertStream(
        @Param("streamId") UUID streamId,
        @Param("deviceId") UUID deviceId,
        @Param("edgeHardExpiresAt") Instant edgeHardExpiresAt
    );

    @Update("""
        UPDATE device_streams
           SET status = CASE WHEN status = 'STOP_PENDING' THEN 'RUNNING' ELSE status END,
               stop_deadline_at = NULL, edge_hard_expires_at = #{edgeHardExpiresAt}, updated_at = now()
         WHERE id = #{streamId} AND status IN ('STARTING', 'RUNNING', 'STOP_PENDING')
        """)
    int reuseStream(@Param("streamId") UUID streamId, @Param("edgeHardExpiresAt") Instant edgeHardExpiresAt);

    @Insert("""
        INSERT INTO stream_sessions (
            id, stream_id, device_id, user_id, status, last_activity_at, viewer_expires_at
        ) VALUES (
            #{sessionId}, #{streamId}, #{deviceId}, #{userId}, CAST(#{status} AS stream_session_status),
            #{now}, #{viewerExpiresAt}
        )
        """)
    int insertSession(
        @Param("sessionId") UUID sessionId,
        @Param("streamId") UUID streamId,
        @Param("deviceId") UUID deviceId,
        @Param("userId") UUID userId,
        @Param("status") String status,
        @Param("now") Instant now,
        @Param("viewerExpiresAt") Instant viewerExpiresAt
    );

    @Select("""
        SELECT s.id, s.stream_id, s.device_id, s.user_id, s.status::text,
               s.last_activity_at, s.viewer_expires_at, e.edge_hard_expires_at,
               s.failure_code, s.created_at
          FROM stream_sessions s
          JOIN device_streams e ON e.id = s.stream_id
          JOIN device_memberships m ON m.device_id = s.device_id
          JOIN devices d ON d.id = s.device_id
         WHERE s.id = #{sessionId} AND s.user_id = #{userId}
           AND m.user_id = #{userId} AND m.status = 'ACTIVE' AND d.status != 'REVOKED'
        """)
    Optional<StreamSessionRow> findAccessibleSession(
        @Param("userId") UUID userId,
        @Param("sessionId") UUID sessionId
    );

    @Update("""
        UPDATE stream_sessions
           SET last_activity_at = #{now}, viewer_expires_at = #{viewerExpiresAt}, updated_at = now()
         WHERE id = #{sessionId} AND user_id = #{userId}
           AND status IN ('PENDING', 'READY') AND viewer_expires_at > #{now}
        """)
    int heartbeatSession(
        @Param("sessionId") UUID sessionId,
        @Param("userId") UUID userId,
        @Param("now") Instant now,
        @Param("viewerExpiresAt") Instant viewerExpiresAt
    );

    @Update("""
        UPDATE stream_sessions
           SET status = 'CLOSED', last_activity_at = #{now}, closed_at = #{now}, updated_at = now()
         WHERE id = #{sessionId} AND user_id = #{userId} AND status IN ('PENDING', 'READY')
        """)
    int closeSession(
        @Param("sessionId") UUID sessionId,
        @Param("userId") UUID userId,
        @Param("now") Instant now
    );

    @Update("""
        UPDATE device_streams
           SET edge_hard_expires_at = #{edgeHardExpiresAt}, stop_deadline_at = NULL,
               status = CASE WHEN status = 'STOP_PENDING' THEN 'RUNNING' ELSE status END,
               updated_at = now()
         WHERE id = #{streamId} AND status IN ('STARTING', 'RUNNING', 'STOP_PENDING')
        """)
    int extendStream(@Param("streamId") UUID streamId, @Param("edgeHardExpiresAt") Instant edgeHardExpiresAt);

    @Update("""
        UPDATE stream_sessions SET status = 'EXPIRED', closed_at = now(), updated_at = now()
         WHERE status IN ('PENDING', 'READY') AND viewer_expires_at <= now()
        """)
    int expireStaleSessions();

    @Update("""
        UPDATE device_streams e
           SET status = 'STOP_PENDING',
               stop_deadline_at = COALESCE((
                   SELECT max(s.last_activity_at) + (#{idleMillis} * interval '1 millisecond')
                     FROM stream_sessions s WHERE s.stream_id = e.id
               ), now()),
               updated_at = now()
         WHERE e.status IN ('STARTING', 'RUNNING')
           AND NOT EXISTS (
               SELECT 1 FROM stream_sessions s
                WHERE s.stream_id = e.id AND s.status IN ('PENDING', 'READY')
                  AND s.viewer_expires_at > now()
           )
        """)
    int scheduleStopsWithoutViewers(@Param("idleMillis") long idleMillis);

    @Select("""
        UPDATE device_streams
           SET status = 'STOPPING', updated_at = now()
         WHERE id = (
             SELECT id FROM device_streams
              WHERE status = 'STOP_PENDING' AND stop_deadline_at <= now()
              ORDER BY stop_deadline_at FOR UPDATE SKIP LOCKED LIMIT 1
         )
     RETURNING id, device_id, status::text, edge_hard_expires_at, stop_deadline_at, failure_code
        """)
    Optional<DeviceStreamRow> claimDueStop();

    @Update("UPDATE device_streams SET status = 'STOPPED', updated_at = now() WHERE id = #{streamId} AND status = 'STOPPING'")
    int completeStop(@Param("streamId") UUID streamId);

    @Update("""
        UPDATE device_streams SET status = 'STOP_PENDING', stop_deadline_at = now() + interval '5 seconds', updated_at = now()
         WHERE id = #{streamId} AND status = 'STOPPING'
        """)
    int retryStop(@Param("streamId") UUID streamId);

    @Update("""
        UPDATE device_streams SET status = 'RUNNING', stop_deadline_at = NULL,
               edge_hard_expires_at = #{edgeHardExpiresAt}, failure_code = NULL, updated_at = now()
         WHERE id = #{streamId} AND device_id = #{deviceId} AND status IN ('STARTING', 'RUNNING')
        """)
    int markStreamReady(
        @Param("deviceId") UUID deviceId,
        @Param("streamId") UUID streamId,
        @Param("edgeHardExpiresAt") Instant edgeHardExpiresAt
    );

    @Update("""
        UPDATE stream_sessions SET status = 'READY', updated_at = now()
         WHERE stream_id = #{streamId} AND status = 'PENDING' AND viewer_expires_at > now()
        """)
    int markSessionsReady(@Param("streamId") UUID streamId);

    @Update("""
        UPDATE device_streams SET status = 'FAILED', failure_code = #{failureCode}, updated_at = now()
         WHERE id = #{streamId} AND device_id = #{deviceId}
           AND status IN ('STARTING', 'RUNNING', 'STOP_PENDING')
        """)
    int markStreamFailed(
        @Param("deviceId") UUID deviceId,
        @Param("streamId") UUID streamId,
        @Param("failureCode") String failureCode
    );

    @Update("""
        UPDATE stream_sessions SET status = 'FAILED', failure_code = #{failureCode}, updated_at = now()
         WHERE stream_id = #{streamId} AND status IN ('PENDING', 'READY')
        """)
    int markSessionsFailed(@Param("streamId") UUID streamId, @Param("failureCode") String failureCode);

    @Update("""
        UPDATE device_streams SET status = 'STOPPED', stop_deadline_at = NULL, updated_at = now()
         WHERE id = #{streamId} AND device_id = #{deviceId}
           AND status IN ('STARTING', 'RUNNING', 'STOP_PENDING', 'STOPPING')
        """)
    int markStreamStopped(@Param("deviceId") UUID deviceId, @Param("streamId") UUID streamId);

    @Update("""
        UPDATE stream_sessions SET status = 'CLOSED', closed_at = now(), updated_at = now()
         WHERE stream_id = #{streamId} AND status IN ('PENDING', 'READY')
        """)
    int closeSessionsForStoppedStream(@Param("streamId") UUID streamId);

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM stream_sessions s
            JOIN device_memberships m ON m.device_id = s.device_id AND m.user_id = s.user_id
            JOIN devices d ON d.id = s.device_id
             WHERE s.id = #{sessionId} AND s.user_id = #{userId}
               AND s.status = 'READY' AND s.viewer_expires_at > now()
               AND m.status = 'ACTIVE' AND d.status != 'REVOKED'
        )
        """)
    boolean isPlayable(@Param("sessionId") UUID sessionId, @Param("userId") UUID userId);

    /**
     * 기기당 발화자 한 명을 원자적으로 확정한다. 이미 다른 세션이 유효한 권한을
     * 쥐고 있으면 WHERE 절이 갱신을 막아 아무 행도 돌려주지 않는다. 같은 세션이
     * 다시 호출하면 만료 시각만 밀려 heartbeat 연장으로 동작한다.
     */
    @Select("""
        INSERT INTO device_talkbacks (device_id, session_id, stream_id, user_id, expires_at)
        VALUES (#{deviceId}, #{sessionId}, #{streamId}, #{userId}, #{expiresAt})
        ON CONFLICT (device_id) DO UPDATE
           SET session_id = EXCLUDED.session_id,
               stream_id = EXCLUDED.stream_id,
               user_id = EXCLUDED.user_id,
               expires_at = EXCLUDED.expires_at,
               updated_at = now()
         WHERE device_talkbacks.expires_at <= now()
            OR device_talkbacks.session_id = EXCLUDED.session_id
     RETURNING device_id, session_id, stream_id, user_id, expires_at
        """)
    Optional<TalkbackRow> acquireTalkback(
        @Param("deviceId") UUID deviceId,
        @Param("sessionId") UUID sessionId,
        @Param("streamId") UUID streamId,
        @Param("userId") UUID userId,
        @Param("expiresAt") Instant expiresAt
    );

    @Update("""
        UPDATE device_talkbacks SET expires_at = #{expiresAt}, updated_at = now()
         WHERE device_id = #{deviceId} AND session_id = #{sessionId} AND expires_at > now()
        """)
    int extendTalkback(
        @Param("deviceId") UUID deviceId,
        @Param("sessionId") UUID sessionId,
        @Param("expiresAt") Instant expiresAt
    );

    @Select("""
        DELETE FROM device_talkbacks
         WHERE device_id = #{deviceId} AND session_id = #{sessionId}
     RETURNING device_id, session_id, stream_id, user_id, expires_at
        """)
    Optional<TalkbackRow> releaseTalkback(
        @Param("deviceId") UUID deviceId,
        @Param("sessionId") UUID sessionId
    );

    @Select("""
        DELETE FROM device_talkbacks
         WHERE device_id IN (
             SELECT device_id FROM device_talkbacks
              WHERE expires_at <= now()
              ORDER BY expires_at FOR UPDATE SKIP LOCKED LIMIT 20
         )
     RETURNING device_id, session_id, stream_id, user_id, expires_at
        """)
    List<TalkbackRow> claimExpiredTalkbacks();

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM device_talkbacks t
            JOIN stream_sessions s ON s.id = t.session_id
            JOIN device_memberships m ON m.device_id = s.device_id AND m.user_id = s.user_id
            JOIN devices d ON d.id = s.device_id
             WHERE t.session_id = #{sessionId} AND t.user_id = #{userId}
               AND t.expires_at > now()
               AND s.status = 'READY' AND s.viewer_expires_at > now()
               AND m.status = 'ACTIVE' AND d.status != 'REVOKED'
        )
        """)
    boolean isTalkable(@Param("sessionId") UUID sessionId, @Param("userId") UUID userId);
}
