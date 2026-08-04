package com.wj.server.video.persistence;

import java.util.List;
import java.util.UUID;

import com.wj.server.video.domain.VideoCommentRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

/**
 * 편집 영상 댓글. editor-api가 MinIO JSON 배열로 들고 있던 것을 옮겨 왔다 —
 * 그쪽은 읽고-붙이고-덮어쓰기라 동시 작성이 유실됐고, 작성자 이름이 앱
 * 자가 신고라 위조가 가능했다. 여기서는 INSERT 한 번이고 이름은 users에서
 * 조인해 온다.
 */
@Mapper
public interface VideoCommentMapper {
    @Insert("""
        INSERT INTO video_comments (id, video_id, author_id, body)
        VALUES (#{id}, #{videoId}, #{authorId}, #{body})
        """)
    int insert(
        @Param("id") UUID id,
        @Param("videoId") UUID videoId,
        @Param("authorId") UUID authorId,
        @Param("body") String body
    );

    @Select("""
        SELECT c.id, c.author_id AS authorId, u.display_name AS authorName,
               c.body, c.created_at AS createdAt
          FROM video_comments c
          JOIN users u ON u.id = c.author_id
         WHERE c.video_id = #{videoId}
         ORDER BY c.created_at, c.id
         LIMIT #{limit}
        """)
    List<VideoCommentRow> findForVideo(
        @Param("videoId") UUID videoId,
        @Param("limit") int limit
    );
}
