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
    /**
     * 처리할 작업을 집어 온다.
     *
     * <p>{@code attempts < maxAttempts}로 막는 것이 재시도 상한이다. 상한이
     * 없던 동안 실서버의 삭제 작업 두 건이 각각 485회·470회까지 돌면서 5분마다
     * 같은 경고를 남겼다 — 권한이 없어 절대 성공할 수 없는 작업이었는데, 워커는
     * 그것을 일시 장애와 구분하지 못했다. 상한을 넘긴 행은 여기서 더 이상
     * 집히지 않고 {@code status='RETRY', attempts >= 상한}으로 남아 조회된다.
     */
    @Select("""
        WITH candidates AS (
            SELECT id
              FROM video_deletion_jobs
             WHERE attempts < #{maxAttempts}
               AND ((status IN ('PENDING', 'RETRY') AND next_attempt_at <= now())
                 OR (status = 'PROCESSING' AND locked_at < now() - interval '5 minutes'))
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
    List<VideoDeletionJob> claim(
        @Param("limit") int limit,
        @Param("maxAttempts") int maxAttempts
    );

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
