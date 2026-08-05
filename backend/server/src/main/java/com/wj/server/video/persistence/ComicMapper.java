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
     */
    @Insert("""
        INSERT INTO comics (video_id) VALUES (#{videoId})
        ON CONFLICT (video_id) DO NOTHING
        """)
    int upsert(@Param("videoId") UUID videoId);

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
                   AS commentCount
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
                   AS commentCount
          FROM comics c
          JOIN videos v ON v.id = c.video_id
         WHERE c.video_id = #{videoId}
        """)
    Optional<ComicRow> find(
        @Param("userId") UUID userId,
        @Param("videoId") UUID videoId
    );

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
