package com.wj.server.video.persistence;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.video.domain.VideoRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface VideoMapper {

    @Insert("""
        INSERT INTO videos (
            id, device_id, source_type, trigger_type, source_event_id, title,
            storage_key, content_type, size_bytes, checksum_sha256, duration_ms,
            captured_start_at, captured_end_at, status
        ) VALUES (
            #{id}, #{deviceId}, 'IOT_CAPTURE', CAST(#{triggerType} AS video_trigger_type), #{sourceEventId}, #{title},
            #{storageKey}, #{contentType}, #{sizeBytes}, #{checksumSha256}, #{durationMs},
            #{capturedStartAt}, #{capturedEndAt}, 'UPLOADING'
        )
        ON CONFLICT (device_id, source_event_id) WHERE source_event_id IS NOT NULL DO NOTHING
        """)
    int insertIotVideo(
        @Param("id") UUID id,
        @Param("deviceId") UUID deviceId,
        @Param("triggerType") String triggerType,
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
               is_favorite AS favorite, created_at
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
               is_favorite AS favorite, created_at
          FROM videos
         WHERE id = #{videoId} AND device_id = #{deviceId}
        """)
    Optional<VideoRow> findOwnedVideo(
        @Param("deviceId") UUID deviceId,
        @Param("videoId") UUID videoId
    );

    @Update("""
        UPDATE videos
           SET status = 'READY', uploaded_at = now(), updated_at = now()
         WHERE id = #{videoId} AND device_id = #{deviceId} AND status = 'UPLOADING'
        """)
    int markReady(@Param("deviceId") UUID deviceId, @Param("videoId") UUID videoId);

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM device_memberships
             WHERE user_id = #{userId} AND device_id = #{deviceId} AND status = 'ACTIVE'
        )
        """)
    boolean hasActiveMembership(@Param("userId") UUID userId, @Param("deviceId") UUID deviceId);

    @Select("""
        <script>
        SELECT v.id, v.device_id, v.source_type, v.trigger_type, v.source_event_id, v.title, v.description,
               v.content_type, v.size_bytes, v.checksum_sha256, v.duration_ms,
               v.captured_start_at, v.captured_end_at, v.storage_key, v.status,
               v.is_favorite AS favorite, v.created_at
          FROM videos v
          JOIN device_memberships m ON m.device_id = v.device_id
         WHERE v.device_id = #{deviceId}
           AND m.user_id = #{userId}
           AND m.status = 'ACTIVE'
           AND v.status NOT IN ('DELETING', 'DELETED')
        <if test="triggerType != null">
           AND v.trigger_type = CAST(#{triggerType} AS video_trigger_type)
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
        @Param("cursorCreatedAt") Instant cursorCreatedAt,
        @Param("cursorId") UUID cursorId,
        @Param("limit") int limit
    );

    @Select("""
        SELECT v.id, v.device_id, v.source_type, v.trigger_type, v.source_event_id, v.title, v.description,
               v.content_type, v.size_bytes, v.checksum_sha256, v.duration_ms,
               v.captured_start_at, v.captured_end_at, v.storage_key, v.status,
               v.is_favorite AS favorite, v.created_at
          FROM videos v
          JOIN device_memberships m ON m.device_id = v.device_id
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
               v.is_favorite AS favorite, v.created_at
          FROM videos v
          JOIN device_memberships m ON m.device_id = v.device_id
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
          JOIN device_memberships m ON m.device_id = v.device_id
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
