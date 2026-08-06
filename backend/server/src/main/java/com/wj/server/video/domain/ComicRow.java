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
 * @param mine         지금 보는 사람이 만든 만화인가. V45 이전 만화는 만든 사람을
 *                     남기지 않았으므로 언제나 false다
 * @param myRole       지금 보는 사람의 금고 역할(OWNER·EDITOR·VIEWER). 삭제 권한을
 *                     가른다
 */
public record ComicRow(
    UUID videoId,
    String title,
    String sourceTitle,
    Instant madeAt,
    int likeCount,
    boolean likedByMe,
    int commentCount,
    boolean mine,
    String myRole
) {
    /**
     * 만든 사람 또는 금고 OWNER가 지운다.
     *
     * <p>만든 사람에게 여는 이유: 잘못 만든 만화를 자기 손으로 치울 수 있어야
     * 한다. OWNER에게도 여는 이유: 만든 사람이 나간 뒤에도, 그리고 V45 이전에
     * 만들어 만든 사람을 모르는 만화도 누군가는 정리할 수 있어야 한다.
     */
    public boolean canDelete() {
        return mine || "OWNER".equals(myRole);
    }
}
