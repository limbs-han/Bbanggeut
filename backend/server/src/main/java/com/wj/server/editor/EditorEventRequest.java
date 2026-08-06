package com.wj.server.editor;

import java.util.UUID;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * 편집 서버(editor-api)가 보내는 서비스 이벤트.
 *
 * @param type      ANALYSIS_STARTED | ANALYSIS_PROGRESS | ANALYSIS_READY |
 *                  ANALYSIS_FAILED | COMIC_READY | COMMENT_ADDED
 * @param videoId   원본 영상 id
 * @param userId    행위자(분석 요청자·댓글 작성자). editor-api가 앱 토큰의 sub에서 뽑는다
 * @param commentId 댓글 이벤트의 멱등 키 조각
 * @param body      댓글 본문 미리보기. 분석 실패 이벤트에서는 실패 사유다
 * @param stage     분석 단계(download·audio·yamnet·video·expression). 분석 이벤트만
 * @param progress  분석 진행률 0.0~1.0. 분석 이벤트만
 */
public record EditorEventRequest(
    @NotBlank String type,
    @NotNull UUID videoId,
    UUID userId,
    @Size(max = 100) String commentId,
    @Size(max = 500) String body,
    @Size(max = 32) String stage,
    Float progress
) {
}
