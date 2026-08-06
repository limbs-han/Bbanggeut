package com.wj.server.video.persistence;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.video.domain.ComicRow;
import com.wj.server.video.domain.VideoCommentRow;
import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

/**
 * 만화 행과 그에 달린 좋아요·댓글.
 *
 * <p>영상 접근 권한은 부르는 쪽(서비스)이 {@code VideoMapper.findAccessibleVideo}로
 * 먼저 확인한다 — 여기 질의에 권한 조건을 섞으면 "권한이 없다"와 "만화가 없다"를
 * 구분할 수 없다.
 */
@Mapper
public interface ComicMapper {
    /**
     * 만화가 완성될 때 부른다. 이미 있으면 만든 시각을 덮지 않는다 — 다시 그린
     * 것도 같은 만화이고, 피드 순서가 재생성 때마다 맨 위로 튀어 오르면
     * 사용자가 만든 순서를 잃는다.
     *
     * <p>만든 사람도 같은 이유로 덮지 않는다. 가족이 남의 만화를 다시 그렸다고
     * 만든 사람이 넘어가면, 원래 만든 사람이 자기 만화를 지울 수 없게 된다.
     * 다만 비어 있으면 채운다 — V45 이전에 만들어 만든 사람을 모르는 만화가
     * 다시 그려지면 그때 주인을 갖는다.
     */
    @Insert("""
        INSERT INTO comics (video_id, created_by) VALUES (#{videoId}, #{createdBy})
        ON CONFLICT (video_id) DO UPDATE
           SET created_by = COALESCE(comics.created_by, EXCLUDED.created_by)
        """)
    int upsert(
        @Param("videoId") UUID videoId,
        @Param("createdBy") UUID createdBy
    );

    /**
     * 금고의 만화를 최신순으로. 좋아요·댓글 수를 함께 센다.
     *
     * <p>세는 것을 스칼라 부질의로 두는 이유: LEFT JOIN + GROUP BY로 두 테이블을
     * 함께 세면 행이 곱해져 개수가 서로 부풀려진다.
     */
    @Select("""
        SELECT c.video_id AS videoId, c.title, v.title AS sourceTitle,
               c.made_at AS madeAt,
               (SELECT COUNT(*) FROM comic_likes l WHERE l.video_id = c.video_id)
                   AS likeCount,
               EXISTS (SELECT 1 FROM comic_likes l
                        WHERE l.video_id = c.video_id AND l.user_id = #{userId})
                   AS likedByMe,
               (SELECT COUNT(*) FROM comic_comments m WHERE m.video_id = c.video_id)
                   AS commentCount,
               -- created_by가 null인 옛 만화는 비교 결과도 null이다. 그대로
               -- 두면 boolean 컬럼에 null이 실린다.
               COALESCE(c.created_by = #{userId}, false) AS mine,
               vm.role AS myRole
          FROM comics c
          JOIN videos v ON v.id = c.video_id
          JOIN vault_memberships vm ON vm.vault_id = v.vault_id
         WHERE v.vault_id = #{vaultId}
           AND vm.user_id = #{userId} AND vm.status = 'ACTIVE'
         ORDER BY c.made_at DESC
         LIMIT #{limit}
        """)
    List<ComicRow> findByVault(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId,
        @Param("limit") int limit
    );

    @Select("""
        SELECT c.video_id AS videoId, c.title, v.title AS sourceTitle,
               c.made_at AS madeAt,
               (SELECT COUNT(*) FROM comic_likes l WHERE l.video_id = c.video_id)
                   AS likeCount,
               EXISTS (SELECT 1 FROM comic_likes l
                        WHERE l.video_id = c.video_id AND l.user_id = #{userId})
                   AS likedByMe,
               (SELECT COUNT(*) FROM comic_comments m WHERE m.video_id = c.video_id)
                   AS commentCount,
               COALESCE(c.created_by = #{userId}, false) AS mine,
               -- 역할은 없을 수도 있다(멤버십이 끊긴 사이). 접근 권한은 부르는
               -- 쪽이 이미 봤으므로 여기서는 null을 그대로 두고, 삭제 판정이
               -- OWNER가 아닌 것으로 다룬다.
               (SELECT vm.role FROM vault_memberships vm
                 WHERE vm.vault_id = v.vault_id AND vm.user_id = #{userId}
                   AND vm.status = 'ACTIVE') AS myRole
          FROM comics c
          JOIN videos v ON v.id = c.video_id
         WHERE c.video_id = #{videoId}
        """)
    Optional<ComicRow> find(
        @Param("userId") UUID userId,
        @Param("videoId") UUID videoId
    );

    /**
     * 만화 행을 지운다. 좋아요와 댓글은 {@code comics(video_id)}를 참조하므로
     * FK CASCADE로 함께 사라진다 — 여기서 따로 지우지 않는다.
     *
     * <p>원본 영상은 건드리지 않는다. 만화를 지우는 것은 "이 영상으로 만든 만화를
     * 없앤다"이지 영상을 없애는 일이 아니다.
     */
    @Delete("DELETE FROM comics WHERE video_id = #{videoId}")
    int delete(@Param("videoId") UUID videoId);

    /** 빈 제목은 null로 넣는다 — 그래야 앱이 원본 제목으로 되돌아간다. */
    @Update("""
        UPDATE comics SET title = #{title}, updated_at = now()
         WHERE video_id = #{videoId}
        """)
    int updateTitle(
        @Param("videoId") UUID videoId,
        @Param("title") String title
    );

    @Insert("""
        INSERT INTO comic_likes (video_id, user_id) VALUES (#{videoId}, #{userId})
        ON CONFLICT (video_id, user_id) DO NOTHING
        """)
    int like(@Param("videoId") UUID videoId, @Param("userId") UUID userId);

    @Delete("""
        DELETE FROM comic_likes WHERE video_id = #{videoId} AND user_id = #{userId}
        """)
    int unlike(@Param("videoId") UUID videoId, @Param("userId") UUID userId);

    /** 만화 댓글. 이름은 users에서 조인해 온다 — 앱 자가 신고를 믿지 않는다. */
    @Select("""
        SELECT m.id, m.author_id AS authorId, u.display_name AS authorName,
               m.body, m.created_at AS createdAt
          FROM comic_comments m
          JOIN users u ON u.id = m.author_id
         WHERE m.video_id = #{videoId}
         ORDER BY m.created_at, m.id
         LIMIT #{limit}
        """)
    List<VideoCommentRow> findComments(
        @Param("videoId") UUID videoId,
        @Param("limit") int limit
    );

    /**
     * 댓글 한 줄. 쓰거나 고친 뒤 **저장된 것을 그대로** 돌려주려고 쓴다.
     *
     * 예전에는 응답을 손으로 조립하면서 이름을 null로, 시각을 서버 시계로
     * 채웠다. 앱은 그 응답을 목록에 그대로 붙이므로, 방금 쓴 댓글만 이름이
     * '가족'으로 보이고 시각도 DB와 어긋났다.
     */
    @Select("""
        SELECT m.id, m.author_id AS authorId, u.display_name AS authorName,
               m.body, m.created_at AS createdAt
          FROM comic_comments m
          JOIN users u ON u.id = m.author_id
         WHERE m.id = #{commentId} AND m.video_id = #{videoId}
        """)
    Optional<VideoCommentRow> findComment(
        @Param("commentId") UUID commentId,
        @Param("videoId") UUID videoId
    );

    @Insert("""
        INSERT INTO comic_comments (id, video_id, author_id, body)
        VALUES (#{id}, #{videoId}, #{authorId}, #{body})
        """)
    int insertComment(
        @Param("id") UUID id,
        @Param("videoId") UUID videoId,
        @Param("authorId") UUID authorId,
        @Param("body") String body
    );

    /**
     * 댓글 작성자. {@code video_id}까지 함께 보는 이유는 다른 만화의 댓글 id를
     * 들고 와도 통과하지 않게 하기 위해서다(영상 댓글과 같은 판단).
     */
    @Select("""
        SELECT author_id FROM comic_comments
         WHERE id = #{commentId} AND video_id = #{videoId}
        """)
    Optional<UUID> findCommentAuthorId(
        @Param("commentId") UUID commentId,
        @Param("videoId") UUID videoId
    );

    @Update("""
        UPDATE comic_comments SET body = #{body}, updated_at = now()
         WHERE id = #{commentId} AND video_id = #{videoId}
        """)
    int updateCommentBody(
        @Param("commentId") UUID commentId,
        @Param("videoId") UUID videoId,
        @Param("body") String body
    );

    @Delete("""
        DELETE FROM comic_comments WHERE id = #{commentId} AND video_id = #{videoId}
        """)
    int deleteComment(
        @Param("commentId") UUID commentId,
        @Param("videoId") UUID videoId
    );
}
