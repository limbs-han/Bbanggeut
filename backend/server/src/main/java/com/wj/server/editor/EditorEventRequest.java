package com.wj.server.editor;

import java.util.UUID;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * 편집 서버(editor-api)가 보내는 서비스 이벤트.
 *
 * @param type      ANALYSIS_READY | COMIC_READY | COMMENT_ADDED
 * @param videoId   원본 영상 id
 * @param userId    행위자(분석 요청자·댓글 작성자). editor-api가 앱 토큰의 sub에서 뽑는다
 * @param commentId 댓글 이벤트의 멱등 키 조각
 * @param body      댓글 본문 미리보기
 */
public record EditorEventRequest(
    @NotBlank String type,
    @NotNull UUID videoId,
    UUID userId,
    @Size(max = 100) String commentId,
    @Size(max = 500) String body
) {
}
