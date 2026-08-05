package com.wj.server.video.api;

/**
 * 좋아요를 누르거나 취소한 뒤의 상태.
 *
 * <p>개수를 함께 돌려주는 이유: 앱이 자기 화면의 숫자를 ±1 하는 것만으로는
 * 가족이 그 사이에 누른 것을 반영하지 못한다.
 *
 * @param likeCount 좋아요 수
 * @param likedByMe 지금 보는 사람이 누른 상태인가
 */
public record ComicLikeResponse(int likeCount, boolean likedByMe) {
}
