package com.wj.server.video.persistence;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.video.domain.VideoEditRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface VideoEditMapper {
    @Insert("""
        INSERT INTO video_edits
            (id, device_id, source_video_id, requested_by, start_ms, end_ms, title)
        VALUES
            (#{id}, #{deviceId}, #{sourceVideoId}, #{userId}, #{startMs}, #{endMs}, #{title})
        """)
    int insert(
        @Param("id") UUID id,
        @Param("deviceId") UUID deviceId,
        @Param("sourceVideoId") UUID sourceVideoId,
        @Param("userId") UUID userId,
        @Param("startMs") long startMs,
        @Param("endMs") long endMs,
        @Param("title") String title
    );

    @Select("""
        SELECT e.id, e.device_id, e.source_video_id, e.result_video_id, e.requested_by,
               e.start_ms, e.end_ms, e.title, e.status::text, e.error_code,
               e.requested_at, e.completed_at,
               v.storage_key AS source_storage_key, v.content_type AS source_content_type,
               v.captured_start_at AS source_captured_start_at
          FROM video_edits e
          JOIN videos v ON v.id = e.source_video_id
          JOIN device_memberships m ON m.device_id = e.device_id
          JOIN devices d ON d.id = e.device_id
         WHERE e.id = #{editId} AND m.user_id = #{userId}
           AND m.status = 'ACTIVE' AND d.status != 'REVOKED'
        """)
    Optional<VideoEditRow> findAccessible(
        @Param("userId") UUID userId,
        @Param("editId") UUID editId
    );

    @Select("""
        WITH candidate AS (
            SELECT id
              FROM video_edits
             WHERE status = 'PENDING'
                OR (status = 'PROCESSING' AND started_at < now() - interval '15 minutes')
             ORDER BY requested_at, id
             FOR UPDATE SKIP LOCKED
             LIMIT 1
        ), claimed AS (
            UPDATE video_edits e
               SET status = 'PROCESSING', started_at = now(), error_code = NULL, updated_at = now()
              FROM candidate c
             WHERE e.id = c.id
         RETURNING e.*
        )
        SELECT e.id, e.device_id, e.source_video_id, e.result_video_id, e.requested_by,
               e.start_ms, e.end_ms, e.title, e.status::text, e.error_code,
               e.requested_at, e.completed_at,
               v.storage_key AS source_storage_key, v.content_type AS source_content_type,
               v.captured_start_at AS source_captured_start_at
          FROM claimed e
          JOIN videos v ON v.id = e.source_video_id
        """)
    Optional<VideoEditRow> claimNext();

    @Insert("""
        INSERT INTO videos (
            id, device_id, created_by, source_type, trigger_type, title, storage_key,
            content_type, size_bytes, checksum_sha256, duration_ms,
            captured_start_at, captured_end_at, status, uploaded_at, retention_until
        )
        SELECT #{resultVideoId}, #{deviceId}, #{requestedBy}, 'EDIT_OUTPUT', 'EDIT', #{title},
               #{storageKey}, 'video/mp4', #{sizeBytes}, #{checksumSha256}, #{durationMs},
               #{capturedStartAt}, #{capturedEndAt}, 'READY', now(),
               now() + make_interval(days =>
                   CASE WHEN d.subscription_active THEN #{premiumRetentionDays} ELSE d.retention_days END)
          FROM devices d WHERE d.id = #{deviceId}
        """)
    int insertResultVideo(
        @Param("resultVideoId") UUID resultVideoId,
        @Param("deviceId") UUID deviceId,
        @Param("requestedBy") UUID requestedBy,
        @Param("title") String title,
        @Param("storageKey") String storageKey,
        @Param("sizeBytes") long sizeBytes,
        @Param("checksumSha256") String checksumSha256,
        @Param("durationMs") long durationMs,
        @Param("capturedStartAt") Instant capturedStartAt,
        @Param("capturedEndAt") Instant capturedEndAt,
        @Param("premiumRetentionDays") int premiumRetentionDays
    );

    @Update("""
        UPDATE video_edits
           SET status = 'COMPLETED', result_video_id = #{resultVideoId},
               completed_at = now(), error_code = NULL, updated_at = now()
         WHERE id = #{editId} AND status = 'PROCESSING'
        """)
    int complete(@Param("editId") UUID editId, @Param("resultVideoId") UUID resultVideoId);

    @Update("""
        UPDATE video_edits
           SET status = 'FAILED', result_video_id = NULL, completed_at = now(),
               error_code = #{errorCode}, updated_at = now()
         WHERE id = #{editId} AND status = 'PROCESSING'
        """)
    int fail(@Param("editId") UUID editId, @Param("errorCode") String errorCode);
}
