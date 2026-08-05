package com.wj.server.video.domain;

import java.time.Instant;
import java.util.UUID;

/**
 * 피드 한 장에 필요한 만화 정보.
 *
 * <p>좋아요 개수와 댓글 개수를 목록 질의에서 함께 센다 — 만화마다 따로 물으면
 * 피드가 스무 장일 때 왕복이 예순 번이 된다.
 *
 * @param videoId      원본 영상 id. 만화의 식별자이기도 하다
 * @param title        사용자가 붙인 제목. 없으면 null이고 앱이 원본 제목을 쓴다
 * @param sourceTitle  원본 영상 제목. 제목을 붙이지 않은 만화의 기본값이다
 * @param madeAt       처음 완성된 시각
 * @param likeCount    좋아요 수
 * @param likedByMe    지금 보는 사람이 눌렀는가
 * @param commentCount 댓글 수
 */
public record ComicRow(
    UUID videoId,
    String title,
    String sourceTitle,
    Instant madeAt,
    int likeCount,
    boolean likedByMe,
    int commentCount
) {
}
