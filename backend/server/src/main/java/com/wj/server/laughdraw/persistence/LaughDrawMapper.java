package com.wj.server.laughdraw.persistence;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.laughdraw.domain.LaughMemoryRow;
import com.wj.server.laughdraw.domain.LaughReactionCountRow;
import com.wj.server.laughdraw.domain.LaughReactionMemberRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface LaughDrawMapper {
    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM vault_memberships
             WHERE vault_id = #{vaultId} AND user_id = #{userId} AND status = 'ACTIVE'
        )
        """)
    boolean isFamilyMember(@Param("vaultId") UUID vaultId, @Param("userId") UUID userId);

    /**
     * 뽑기 후보 중 하나를 무작위로 고른다.
     *
     * <p>후보 조건은 모두 SQL에서 걸러 다른 가족·삭제·만료·재생 불가 영상이
     * 애플리케이션까지 올라오지 않게 한다. 시간 기준은 촬영 시각이지만 예전 데이터에는
     * {@code captured_start_at}이 비어 있을 수 있어 저장 시각으로 대신한다.
     *
     * <p>{@code ORDER BY random()}은 후보 수가 최근 3일치(수십~수백 건)라 부담이 없고,
     * 무작위 선택을 한 번의 질의로 끝낼 수 있어 후보 전체를 앱으로 끌어올리지 않는다.
     */
    @Select("""
        <script>
        SELECT v.id, v.device_id, v.vault_id, v.source_type, v.trigger_type,
               v.title, v.description, v.content_type, v.size_bytes, v.duration_ms,
               v.captured_start_at, v.captured_end_at, v.status,
               v.is_favorite AS favorite, v.retention_until, v.created_at,
               array_to_string(v.event_types, ',') AS event_types_csv
          FROM videos v
         WHERE v.vault_id = #{vaultId}
           AND CAST('LAUGHTER' AS video_trigger_type) = ANY(v.event_types)
           AND v.status = 'READY'
           AND v.deleted_at IS NULL
           AND v.delete_requested_at IS NULL
           AND (v.retention_until IS NULL OR v.retention_until &gt; now())
           AND COALESCE(v.captured_start_at, v.created_at) &gt;= #{since}
        <if test="excludeIds != null and excludeIds.size() > 0">
           AND v.id NOT IN
           <foreach item="excludeId" collection="excludeIds" open="(" separator="," close=")">
               #{excludeId}
           </foreach>
        </if>
         ORDER BY random()
         LIMIT 1
        </script>
        """)
    Optional<LaughMemoryRow> findRandomCandidate(
        @Param("vaultId") UUID vaultId,
        @Param("since") Instant since,
        @Param("excludeIds") List<UUID> excludeIds
    );

    /** 반응을 남기려는 영상이 이 사용자가 볼 수 있는 웃음 영상인지 확인한다. */
    @Select("""
        SELECT v.id, v.device_id, v.vault_id, v.source_type, v.trigger_type,
               v.title, v.description, v.content_type, v.size_bytes, v.duration_ms,
               v.captured_start_at, v.captured_end_at, v.status,
               v.is_favorite AS favorite, v.retention_until, v.created_at,
               array_to_string(v.event_types, ',') AS event_types_csv
          FROM videos v
          JOIN vault_memberships m ON m.vault_id = v.vault_id
         WHERE v.id = #{videoId}
           AND m.user_id = #{userId}
           AND m.status = 'ACTIVE'
        """)
    Optional<LaughMemoryRow> findAccessibleMemory(
        @Param("userId") UUID userId,
        @Param("videoId") UUID videoId
    );

    @Select("""
        SELECT reaction_type, COUNT(*)::int AS count
          FROM laugh_memory_reactions
         WHERE video_id = #{videoId}
         GROUP BY reaction_type
        """)
    List<LaughReactionCountRow> countReactions(@Param("videoId") UUID videoId);

    @Select("""
        SELECT reaction_type
          FROM laugh_memory_reactions
         WHERE video_id = #{videoId} AND member_id = #{memberId}
        """)
    Optional<String> findMyReaction(
        @Param("videoId") UUID videoId,
        @Param("memberId") UUID memberId
    );

    /**
     * 이 영상에 반응을 남긴 구성원 목록.
     *
     * <p>반응이 없는 구성원은 나오지 않는다 — 화면이 "누가 반응했는지"만 보여 주기
     * 때문이다. 남긴 순서대로 정렬해 방금 누른 사람이 늘 같은 자리에 오게 한다.
     */
    @Select("""
        SELECT r.member_id, u.display_name, r.reaction_type
          FROM laugh_memory_reactions r
          JOIN users u ON u.id = r.member_id
         WHERE r.video_id = #{videoId}
         ORDER BY r.created_at, r.member_id
        """)
    List<LaughReactionMemberRow> findReactionMembers(@Param("videoId") UUID videoId);

    /**
     * 반응을 남기거나 바꾼다.
     *
     * <p>UNIQUE(video_id, member_id) 위에서 upsert하므로 같은 사람이 여러 번 눌러도
     * 행이 늘지 않는다. 같은 이모지를 다시 눌렀을 때도 {@code updated_at}만 갱신되고
     * 개수는 그대로다 — 연속 탭이 개수를 부풀리지 않는다.
     */
    @Insert("""
        INSERT INTO laugh_memory_reactions (video_id, member_id, reaction_type)
        VALUES (#{videoId}, #{memberId}, #{reactionType})
        ON CONFLICT (video_id, member_id)
        DO UPDATE SET reaction_type = EXCLUDED.reaction_type, updated_at = now()
        """)
    int upsertReaction(
        @Param("videoId") UUID videoId,
        @Param("memberId") UUID memberId,
        @Param("reactionType") String reactionType
    );
}
