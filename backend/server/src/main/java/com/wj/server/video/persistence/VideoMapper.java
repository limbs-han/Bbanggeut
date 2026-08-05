package com.wj.server.video.persistence;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.domain.VideoCountRow;
import com.wj.server.video.domain.DailyVideoCountRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface VideoMapper {

    @Select("SELECT status IN ('ONLINE', 'OFFLINE') FROM devices WHERE id = #{deviceId}")
    boolean isClaimedDevice(@Param("deviceId") UUID deviceId);

    // --- 편집 완성본(EDIT_OUTPUT) ---
    //
    // 원본 영상 행에서 금고·기기·보관 기준을 물려받는다. 그래서 권한 검사·
    // 보관 만료·삭제 연쇄·목록이 원본과 같은 경로를 탄다.
    @Insert("""
        INSERT INTO videos (
            id, device_id, vault_id, device_binding_id, created_by,
            source_type, trigger_type, event_types, source_video_id,
            title, storage_key, content_type, duration_ms,
            captured_start_at, captured_end_at, status, retention_until
        )
        SELECT
            #{id}, o.device_id, o.vault_id, o.device_binding_id, #{userId},
            'EDIT_OUTPUT', o.trigger_type, o.event_types, o.id,
            #{title}, #{storageKey}, 'video/mp4', #{durationMs},
            #{capturedStartAt}, #{capturedEndAt}, 'UPLOADING',
            now() + make_interval(days =>
                CASE WHEN mv.subscription_active THEN #{premiumRetentionDays}
                     ELSE mv.retention_days END)
          FROM videos o
          JOIN memory_vaults mv ON mv.id = o.vault_id
         WHERE o.id = #{sourceVideoId}
        """)
    int insertEditOutput(
        @Param("id") UUID id,
        @Param("sourceVideoId") UUID sourceVideoId,
        @Param("userId") UUID userId,
        @Param("title") String title,
        @Param("storageKey") String storageKey,
        @Param("durationMs") Long durationMs,
        @Param("capturedStartAt") Instant capturedStartAt,
        @Param("capturedEndAt") Instant capturedEndAt,
        @Param("premiumRetentionDays") int premiumRetentionDays
    );

    /**
     * 금고의 편집 완성본. 도착을 기다리는 것({@code UPLOADING})과 끝내 오지
     * 못한 것({@code FAILED})도 함께 준다 — 업로드는 세션 없는 OS 백그라운드
     * 작업이 하고 진행 상황이 상단 알림으로만 나가서, 알림을 껐거나 권한을
     * 주지 않은 기기에서는 목록이 유일한 단서다. {@code READY}만 주면 올라가는
     * 중에는 아무것도 안 보이고 실패한 줄은 조용히 사라진다.
     */
    @Select("""
        SELECT v.id, v.device_id, v.source_type, v.trigger_type, v.source_event_id,
               v.title, v.description, v.content_type, v.size_bytes, v.checksum_sha256,
               v.duration_ms, v.captured_start_at, v.captured_end_at, v.storage_key,
               v.status, v.is_favorite AS favorite, v.created_at,
               array_to_string(v.event_types, ',') AS event_types_csv
          FROM videos v
          JOIN vault_memberships m ON m.vault_id = v.vault_id
         WHERE v.vault_id = #{vaultId} AND m.user_id = #{userId} AND m.status = 'ACTIVE'
           AND v.source_type = 'EDIT_OUTPUT'
           AND v.status IN ('READY', 'UPLOADING', 'FAILED')
           AND v.deleted_at IS NULL
         ORDER BY v.created_at DESC, v.id DESC
         LIMIT #{limit}
        """)
    List<VideoRow> findEditOutputsByVault(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId,
        @Param("limit") int limit
    );

    /**
     * 도착을 기다리는 편집본. 백그라운드 업로더는 세션이 없어 /complete를
     * 부를 수 없으므로 서버가 객체가 왔는지 훑어 승격한다.
     */
    @Select("""
        SELECT id, device_id, source_type, trigger_type, source_event_id, title, description,
               content_type, size_bytes, checksum_sha256, duration_ms,
               captured_start_at, captured_end_at, storage_key, status,
               is_favorite AS favorite, created_at,
               array_to_string(event_types, ',') AS event_types_csv
          FROM videos
         WHERE status = 'UPLOADING' AND source_type = 'EDIT_OUTPUT'
           AND deleted_at IS NULL
         ORDER BY updated_at, id
         LIMIT #{limit}
        """)
    List<VideoRow> findPendingEditUploads(@Param("limit") int limit);

    @Update("""
        UPDATE videos
           SET status = 'READY', size_bytes = #{sizeBytes}, uploaded_at = now(),
               updated_at = now()
         WHERE id = #{videoId} AND status = 'UPLOADING' AND source_type = 'EDIT_OUTPUT'
        """)
    int markEditOutputReady(
        @Param("videoId") UUID videoId,
        @Param("sizeBytes") long sizeBytes
    );

    @Insert("""
        INSERT INTO videos (
            id, device_id, vault_id, device_binding_id,
            source_type, trigger_type, event_types, source_event_id, title,
            storage_key, content_type, size_bytes, checksum_sha256, duration_ms,
            captured_start_at, captured_end_at, status
        )
        SELECT
            #{id}, #{deviceId}, b.vault_id, b.id,
            'IOT_CAPTURE', CAST(#{triggerType} AS video_trigger_type),
            string_to_array(#{eventTypesCsv}, ',')::video_trigger_type[],
            #{sourceEventId}, #{title},
            #{storageKey}, #{contentType}, #{sizeBytes}, #{checksumSha256}, #{durationMs},
            #{capturedStartAt}, #{capturedEndAt}, 'UPLOADING'
          FROM device_bindings b
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
        ON CONFLICT (device_id, source_event_id) WHERE source_event_id IS NOT NULL DO NOTHING
        """)
    int insertIotVideo(
        @Param("id") UUID id,
        @Param("deviceId") UUID deviceId,
        @Param("triggerType") String triggerType,
        @Param("eventTypesCsv") String eventTypesCsv,
        @Param("sourceEventId") String sourceEventId,
        @Param("title") String title,
        @Param("storageKey") String storageKey,
        @Param("contentType") String contentType,
        @Param("sizeBytes") long sizeBytes,
        @Param("checksumSha256") String checksumSha256,
        @Param("durationMs") long durationMs,
        @Param("capturedStartAt") Instant capturedStartAt,
        @Param("capturedEndAt") Instant capturedEndAt
    );

    @Select("""
        SELECT id, device_id, source_type, trigger_type, source_event_id, title, description,
               content_type, size_bytes, checksum_sha256, duration_ms,
               captured_start_at, captured_end_at, storage_key, status,
               is_favorite AS favorite, created_at,
               array_to_string(event_types, ',') AS event_types_csv
          FROM videos
         WHERE device_id = #{deviceId} AND source_event_id = #{sourceEventId}
        """)
    Optional<VideoRow> findByDeviceEvent(
        @Param("deviceId") UUID deviceId,
        @Param("sourceEventId") String sourceEventId
    );

    @Select("""
        SELECT id, device_id, source_type, trigger_type, source_event_id, title, description,
               content_type, size_bytes, checksum_sha256, duration_ms,
               captured_start_at, captured_end_at, storage_key, status,
               is_favorite AS favorite, created_at,
               array_to_string(event_types, ',') AS event_types_csv
          FROM videos
         WHERE id = #{videoId} AND device_id = #{deviceId}
        """)
    Optional<VideoRow> findOwnedVideo(
        @Param("deviceId") UUID deviceId,
        @Param("videoId") UUID videoId
    );

    /**
     * 이 영상을 만든 사람. 편집본 삭제 권한을 가리는 데 쓴다.
     *
     * {@link VideoRow}에 얹지 않은 이유는 이 값을 쓰는 곳이 삭제 한 군데뿐인데
     * record에 넣으면 영상을 읽는 모든 select를 함께 넓혀야 하기 때문이다.
     * 기기가 올린 원본은 이 값이 비어 있다(사람이 만든 것이 아니다).
     */
    @Select("SELECT created_by FROM videos WHERE id = #{videoId}")
    Optional<UUID> findCreatorId(@Param("videoId") UUID videoId);

    @Update("""
        UPDATE videos v
           SET status = 'READY', uploaded_at = now(),
               retention_until = now() + make_interval(days =>
                   CASE WHEN d.subscription_active THEN #{premiumRetentionDays} ELSE d.retention_days END),
               updated_at = now()
          FROM memory_vaults d
         WHERE v.id = #{videoId} AND v.device_id = #{deviceId}
           AND d.id = v.vault_id AND v.status = 'UPLOADING'
        """)
    int markReady(
        @Param("deviceId") UUID deviceId,
        @Param("videoId") UUID videoId,
        @Param("premiumRetentionDays") int premiumRetentionDays
    );

    @Update("""
        UPDATE videos
           SET status = 'UPLOADING', failure_code = NULL,
               retention_until = NULL, updated_at = now()
         WHERE id = #{videoId} AND device_id = #{deviceId} AND status = 'FAILED'
        """)
    int retryFailedUpload(
        @Param("deviceId") UUID deviceId,
        @Param("videoId") UUID videoId
    );

    /**
     * Turns abandoned upload reservations into recoverable FAILED rows. The
     * same sourceEventId may later reset the row to UPLOADING and receive a
     * fresh presigned URL.
     */
    @Select("""
        WITH stale AS (
            SELECT id
              FROM videos
             WHERE status = 'UPLOADING' AND updated_at < #{cutoff}
             ORDER BY updated_at
             LIMIT #{limit}
             FOR UPDATE SKIP LOCKED
        ),
        failed_videos AS (
            UPDATE videos v
               SET status = 'FAILED', failure_code = 'UPLOAD_TIMEOUT',
                   retention_until = COALESCE(retention_until, now() + interval '7 days'),
                   updated_at = now()
              FROM stale
             WHERE v.id = stale.id AND v.status = 'UPLOADING'
            RETURNING v.id
        ),
        event_updates AS (
            UPDATE device_events e
               SET upload_status = 'FAILED', updated_at = now()
              FROM failed_videos f
             WHERE e.video_id = f.id
            RETURNING e.id
        )
        SELECT id FROM failed_videos
        """)
    List<UUID> markStaleUploadsFailed(
        @Param("cutoff") Instant cutoff,
        @Param("limit") int limit
    );

    /**
     * Retention sweep: flips expired videos to DELETING and returns their ids so
     * the caller can enqueue deletion jobs in the same transaction.
     */
    @Select("""
        WITH due AS (
            SELECT id FROM videos
             WHERE retention_until IS NOT NULL AND retention_until <= now()
               AND status IN ('READY', 'FAILED')
             ORDER BY retention_until
             LIMIT #{limit}
             FOR UPDATE SKIP LOCKED
        )
        UPDATE videos v
           SET status = 'DELETING', delete_requested_at = now(), updated_at = now()
          FROM due
         WHERE v.id = due.id
        RETURNING v.id
        """)
    List<UUID> markRetentionExpiredDeleting(@Param("limit") int limit);

    @Select("""
        SELECT EXISTS (
            SELECT 1
              FROM device_bindings b
              JOIN vault_memberships vm ON vm.vault_id = b.vault_id
             WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
               AND vm.user_id = #{userId} AND vm.status = 'ACTIVE'
        )
        """)
    boolean hasActiveMembership(@Param("userId") UUID userId, @Param("deviceId") UUID deviceId);

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM vault_memberships
             WHERE user_id = #{userId} AND vault_id = #{vaultId}
               AND status = 'ACTIVE'
        )
        """)
    boolean hasVaultMembership(@Param("userId") UUID userId, @Param("vaultId") UUID vaultId);

    @Select("""
        <script>
        SELECT v.id, v.device_id, v.source_type, v.trigger_type, v.source_event_id, v.title, v.description,
               v.content_type, v.size_bytes, v.checksum_sha256, v.duration_ms,
               v.captured_start_at, v.captured_end_at, v.storage_key, v.status,
               v.is_favorite AS favorite, v.created_at,
               array_to_string(v.event_types, ',') AS event_types_csv
          FROM videos v
          JOIN vault_memberships m ON m.vault_id = v.vault_id
         WHERE v.device_id = #{deviceId}
           AND m.user_id = #{userId}
           AND m.status = 'ACTIVE'
           AND v.status NOT IN ('DELETING', 'DELETED')
        <if test="triggerType != null">
           AND CAST(#{triggerType} AS video_trigger_type) = ANY(v.event_types)
        </if>
        <if test="from != null">
           AND v.captured_start_at &gt;= #{from}
        </if>
        <if test="to != null">
           AND v.captured_start_at &lt; #{to}
        </if>
        <if test="cursorCreatedAt != null">
           AND (v.created_at, v.id) &lt; (#{cursorCreatedAt}, #{cursorId})
        </if>
         ORDER BY v.created_at DESC, v.id DESC
         LIMIT #{limit}
        </script>
        """)
    java.util.List<VideoRow> findAccessibleVideos(
        @Param("userId") UUID userId,
        @Param("deviceId") UUID deviceId,
        @Param("triggerType") String triggerType,
        @Param("from") Instant from,
        @Param("to") Instant to,
        @Param("cursorCreatedAt") Instant cursorCreatedAt,
        @Param("cursorId") UUID cursorId,
        @Param("limit") int limit
    );

    @Select("""
        <script>
        SELECT v.id, v.device_id, v.source_type, v.trigger_type, v.source_event_id, v.title, v.description,
               v.content_type, v.size_bytes, v.checksum_sha256, v.duration_ms,
               v.captured_start_at, v.captured_end_at, v.storage_key, v.status,
               v.is_favorite AS favorite, v.created_at,
               array_to_string(v.event_types, ',') AS event_types_csv
          FROM videos v
          JOIN vault_memberships m ON m.vault_id = v.vault_id
         WHERE v.vault_id = #{vaultId}
           AND m.user_id = #{userId} AND m.status = 'ACTIVE'
           AND v.status NOT IN ('DELETING', 'DELETED')
        <if test="triggerType != null">
           AND CAST(#{triggerType} AS video_trigger_type) = ANY(v.event_types)
        </if>
        <if test="from != null">
           AND v.captured_start_at &gt;= #{from}
        </if>
        <if test="to != null">
           AND v.captured_start_at &lt; #{to}
        </if>
        <if test="cursorCreatedAt != null">
           AND (v.created_at, v.id) &lt; (#{cursorCreatedAt}, #{cursorId})
        </if>
         ORDER BY v.created_at DESC, v.id DESC
         LIMIT #{limit}
        </script>
        """)
    List<VideoRow> findAccessibleVideosByVault(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId,
        @Param("triggerType") String triggerType,
        @Param("from") Instant from,
        @Param("to") Instant to,
        @Param("cursorCreatedAt") Instant cursorCreatedAt,
        @Param("cursorId") UUID cursorId,
        @Param("limit") int limit
    );

    @Select("""
        SELECT count(*)
          FROM videos
         WHERE device_id = #{deviceId} AND status = 'READY'
           AND captured_start_at >= #{from} AND captured_start_at < #{to}
        """)
    long countReadyVideos(
        @Param("deviceId") UUID deviceId,
        @Param("from") Instant from,
        @Param("to") Instant to
    );

    @Select("""
        SELECT count(*)
          FROM videos
         WHERE device_id = #{deviceId} AND status = 'READY'
           AND description IS NOT NULL AND btrim(description) <> ''
           AND captured_start_at >= #{from} AND captured_start_at < #{to}
        """)
    long countReadyVideosWithMemo(
        @Param("deviceId") UUID deviceId,
        @Param("from") Instant from,
        @Param("to") Instant to
    );

    @Select("""
        SELECT v.id, v.device_id, v.source_type, v.trigger_type, v.source_event_id, v.title, v.description,
               v.content_type, v.size_bytes, v.checksum_sha256, v.duration_ms,
               v.captured_start_at, v.captured_end_at, v.storage_key, v.status,
               v.is_favorite AS favorite, v.created_at,
               array_to_string(v.event_types, ',') AS event_types_csv
          FROM videos v
          JOIN vault_memberships m ON m.vault_id = v.vault_id
         WHERE v.device_id = #{deviceId}
           AND m.user_id = #{userId}
           AND m.status = 'ACTIVE'
           AND v.status = 'READY'
         ORDER BY v.is_favorite DESC, v.captured_start_at DESC NULLS LAST, v.created_at DESC
         LIMIT 1
        """)
    Optional<VideoRow> findLatestHighlight(
        @Param("userId") UUID userId,
        @Param("deviceId") UUID deviceId
    );

    @Select("""
        SELECT event_type::text AS label, count(*) AS count
          FROM videos
          CROSS JOIN LATERAL unnest(event_types) AS event_type
         WHERE device_id = #{deviceId} AND status = 'READY'
           AND captured_start_at >= #{from} AND captured_start_at < #{to}
         GROUP BY event_type
         ORDER BY count DESC, label
        """)
    List<VideoCountRow> countReadyVideosByTrigger(
        @Param("deviceId") UUID deviceId,
        @Param("from") Instant from,
        @Param("to") Instant to
    );

    @Select("""
        SELECT (captured_start_at AT TIME ZONE #{zoneId})::date AS date, count(*) AS count
          FROM videos
         WHERE device_id = #{deviceId} AND status = 'READY'
           AND captured_start_at >= #{from} AND captured_start_at < #{to}
         GROUP BY date
         ORDER BY date
        """)
    List<DailyVideoCountRow> countReadyVideosByDay(
        @Param("deviceId") UUID deviceId,
        @Param("from") Instant from,
        @Param("to") Instant to,
        @Param("zoneId") String zoneId
    );

    @Select("""
        SELECT extract(isodow FROM captured_start_at AT TIME ZONE #{zoneId})::int::text AS label,
               count(*) AS count
          FROM videos
         WHERE device_id = #{deviceId} AND status = 'READY'
           AND captured_start_at >= #{from} AND captured_start_at < #{to}
         GROUP BY label
         ORDER BY count DESC, label
        """)
    List<VideoCountRow> countReadyVideosByWeekday(
        @Param("deviceId") UUID deviceId,
        @Param("from") Instant from,
        @Param("to") Instant to,
        @Param("zoneId") String zoneId
    );

    @Select("""
        SELECT extract(hour FROM captured_start_at AT TIME ZONE #{zoneId})::int::text AS label,
               count(*) AS count
          FROM videos
         WHERE device_id = #{deviceId} AND status = 'READY'
           AND captured_start_at >= #{from} AND captured_start_at < #{to}
         GROUP BY label
         ORDER BY count DESC, label
        """)
    List<VideoCountRow> countReadyVideosByHour(
        @Param("deviceId") UUID deviceId,
        @Param("from") Instant from,
        @Param("to") Instant to,
        @Param("zoneId") String zoneId
    );

    @Select("""
        SELECT v.id, v.device_id, v.source_type, v.trigger_type, v.source_event_id, v.title, v.description,
               v.content_type, v.size_bytes, v.checksum_sha256, v.duration_ms,
               v.captured_start_at, v.captured_end_at, v.storage_key, v.status,
               v.is_favorite AS favorite, v.created_at,
               array_to_string(v.event_types, ',') AS event_types_csv
          FROM videos v
          JOIN vault_memberships m ON m.vault_id = v.vault_id
         WHERE v.id = #{videoId}
           AND m.user_id = #{userId}
           AND m.status = 'ACTIVE'
           AND v.status NOT IN ('DELETING', 'DELETED')
        """)
    Optional<VideoRow> findAccessibleVideo(
        @Param("userId") UUID userId,
        @Param("videoId") UUID videoId
    );

    @Select("""
        SELECT v.id, v.device_id, v.source_type, v.trigger_type, v.source_event_id, v.title, v.description,
               v.content_type, v.size_bytes, v.checksum_sha256, v.duration_ms,
               v.captured_start_at, v.captured_end_at, v.storage_key, v.status,
               v.is_favorite AS favorite, v.created_at,
               array_to_string(v.event_types, ',') AS event_types_csv
          FROM videos v
          JOIN vault_memberships m ON m.vault_id = v.vault_id
         WHERE v.id = #{videoId}
           AND m.user_id = #{userId}
           AND m.status = 'ACTIVE'
           AND v.status NOT IN ('DELETING', 'DELETED')
         FOR UPDATE OF v
        """)
    Optional<VideoRow> lockAccessibleVideo(
        @Param("userId") UUID userId,
        @Param("videoId") UUID videoId
    );

    @Select("""
        SELECT m.role::text
          FROM videos v
          JOIN vault_memberships m ON m.vault_id = v.vault_id
         WHERE v.id = #{videoId} AND m.user_id = #{userId} AND m.status = 'ACTIVE'
        """)
    Optional<String> findActiveRole(
        @Param("userId") UUID userId,
        @Param("videoId") UUID videoId
    );

    @Update("""
        UPDATE videos
           SET title = CASE WHEN #{titlePresent} THEN #{title} ELSE title END,
               description = CASE WHEN #{descriptionPresent} THEN #{description} ELSE description END,
               is_favorite = CASE WHEN #{favoritePresent} THEN #{favorite} ELSE is_favorite END,
               updated_at = now()
         WHERE id = #{videoId}
        """)
    int updateMetadata(
        @Param("videoId") UUID videoId,
        @Param("titlePresent") boolean titlePresent,
        @Param("title") String title,
        @Param("descriptionPresent") boolean descriptionPresent,
        @Param("description") String description,
        @Param("favoritePresent") boolean favoritePresent,
        @Param("favorite") Boolean favorite
    );

    @Update("""
        UPDATE videos
           SET status = 'DELETING', delete_requested_at = now(), deleted_by = #{userId}, updated_at = now()
         WHERE id = #{videoId} AND status NOT IN ('DELETING', 'DELETED')
        """)
    int markDeleting(@Param("videoId") UUID videoId, @Param("userId") UUID userId);

    @Insert("""
        INSERT INTO video_deletion_jobs (video_id)
        VALUES (#{videoId})
        ON CONFLICT (video_id) DO NOTHING
        """)
    int insertDeletionJob(@Param("videoId") UUID videoId);
}
