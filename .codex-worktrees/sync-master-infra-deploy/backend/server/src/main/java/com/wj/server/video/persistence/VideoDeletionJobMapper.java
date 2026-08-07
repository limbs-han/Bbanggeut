package com.wj.server.video.persistence;

import java.util.List;
import java.util.UUID;

import com.wj.server.video.domain.VideoDeletionJob;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface VideoDeletionJobMapper {
    @Select("""
        WITH candidates AS (
            SELECT id
              FROM video_deletion_jobs
             WHERE (status IN ('PENDING', 'RETRY') AND next_attempt_at <= now())
                OR (status = 'PROCESSING' AND locked_at < now() - interval '5 minutes')
             ORDER BY next_attempt_at, id
             FOR UPDATE SKIP LOCKED
             LIMIT #{limit}
        ), claimed AS (
            UPDATE video_deletion_jobs j
               SET status = 'PROCESSING', attempts = attempts + 1, locked_at = now()
              FROM candidates c
             WHERE j.id = c.id
         RETURNING j.id, j.video_id, j.attempts
        )
        SELECT c.id, c.video_id, v.storage_key, v.thumbnail_storage_key, c.attempts
          FROM claimed c
          JOIN videos v ON v.id = c.video_id
        """)
    List<VideoDeletionJob> claim(@Param("limit") int limit);

    @Update("""
        UPDATE videos
           SET status = 'DELETED', deleted_at = now(), updated_at = now()
         WHERE id = #{videoId} AND status = 'DELETING'
        """)
    int markVideoDeleted(@Param("videoId") UUID videoId);

    @Update("""
        UPDATE video_deletion_jobs
           SET status = 'COMPLETED', completed_at = now(), locked_at = NULL, last_error_code = NULL
         WHERE id = #{jobId} AND status = 'PROCESSING'
        """)
    int complete(@Param("jobId") long jobId);

    @Update("""
        UPDATE video_deletion_jobs
           SET status = 'RETRY',
               next_attempt_at = now() + CASE
                   WHEN attempts <= 1 THEN interval '5 seconds'
                   WHEN attempts = 2 THEN interval '30 seconds'
                   ELSE interval '5 minutes'
               END,
               locked_at = NULL,
               last_error_code = #{errorCode}
         WHERE id = #{jobId} AND status = 'PROCESSING'
        """)
    int retry(@Param("jobId") long jobId, @Param("errorCode") String errorCode);
}
