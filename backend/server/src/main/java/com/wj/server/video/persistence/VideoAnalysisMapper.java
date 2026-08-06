package com.wj.server.video.persistence;

import java.util.Optional;
import java.util.UUID;

import com.wj.server.video.domain.VideoAnalysisRow;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

/**
 * 영상 분석 상태.
 *
 * <p>영상 접근 권한은 부르는 쪽(서비스)이 먼저 확인한다 — 질의에 권한 조건을
 * 섞으면 "권한이 없다"와 "분석한 적이 없다"를 구분할 수 없다(만화 매퍼와 같은
 * 판단).
 */
@Mapper
public interface VideoAnalysisMapper {
    @Select("""
        SELECT video_id AS videoId, status, stage, progress, error,
               requested_by AS requestedBy, started_at AS startedAt,
               finished_at AS finishedAt
          FROM video_analyses
         WHERE video_id = #{videoId}
        """)
    Optional<VideoAnalysisRow> find(@Param("videoId") UUID videoId);

    /**
     * 분석이 시작됐다. 다시 돌리면 같은 행을 처음 상태로 되돌린다 — 실패했던
     * 분석을 다시 걸었는데 예전 error가 남아 있으면 앱이 실패로 읽는다.
     *
     * <p>{@code requestedBy}는 비어 있으면 덮지 않는다. 워커가 토큰 없이 부른
     * 경로에서 null이 와도, 먼저 걸어 둔 사람을 지우지 않기 위해서다.
     */
    @Update("""
        INSERT INTO video_analyses
               (video_id, status, stage, progress, error, requested_by,
                started_at, finished_at, updated_at)
        VALUES (#{videoId}, 'RUNNING', #{stage}, 0, NULL, #{requestedBy},
                now(), NULL, now())
        ON CONFLICT (video_id) DO UPDATE
           SET status = 'RUNNING',
               stage = EXCLUDED.stage,
               progress = 0,
               error = NULL,
               requested_by =
                   COALESCE(EXCLUDED.requested_by, video_analyses.requested_by),
               started_at = now(),
               finished_at = NULL,
               updated_at = now()
        """)
    int started(
        @Param("videoId") UUID videoId,
        @Param("stage") String stage,
        @Param("requestedBy") UUID requestedBy
    );

    /**
     * 단계가 넘어갔다. **진행 중인 행만** 건드린다 — 늦게 도착한 진행 보고가
     * 이미 끝난 분석을 다시 RUNNING으로 되돌리면 앱이 영원히 "분석 중"을 본다.
     */
    @Update("""
        UPDATE video_analyses
           SET stage = #{stage}, progress = #{progress}, updated_at = now()
         WHERE video_id = #{videoId} AND status = 'RUNNING'
        """)
    int progressed(
        @Param("videoId") UUID videoId,
        @Param("stage") String stage,
        @Param("progress") float progress
    );

    /**
     * 분석이 끝났다(성공 또는 실패). 행이 없으면 세운다 — 백엔드를 재배포하는
     * 사이에 시작 보고를 놓쳤어도 완료는 남아야 한다.
     */
    @Update("""
        INSERT INTO video_analyses
               (video_id, status, stage, progress, error, requested_by,
                started_at, finished_at, updated_at)
        VALUES (#{videoId}, #{status}, NULL, #{progress}, #{error},
                #{requestedBy}, now(), now(), now())
        ON CONFLICT (video_id) DO UPDATE
           SET status = EXCLUDED.status,
               progress = EXCLUDED.progress,
               error = EXCLUDED.error,
               requested_by =
                   COALESCE(EXCLUDED.requested_by, video_analyses.requested_by),
               finished_at = now(),
               updated_at = now()
        """)
    int finished(
        @Param("videoId") UUID videoId,
        @Param("status") String status,
        @Param("progress") float progress,
        @Param("error") String error,
        @Param("requestedBy") UUID requestedBy
    );
}
