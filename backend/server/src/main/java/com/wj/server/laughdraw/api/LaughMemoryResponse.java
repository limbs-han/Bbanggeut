package com.wj.server.laughdraw.api;

import java.time.Instant;
import java.util.List;
import java.util.Map;

import com.wj.server.video.api.VideoResponse;

/**
 * 뽑힌 웃음 영상 한 건과 그 반응.
 *
 * <p>영상 부분은 기존 {@link VideoResponse}를 그대로 담는다. 뽑기 화면이 재생 URL을
 * {@code POST /api/videos/{id}/play-url}로 받고 썸네일도 기존 목록과 같은 방식으로
 * 만들기 때문에, 앱이 이미 가진 파서와 위젯을 그대로 쓸 수 있다.
 *
 * @param expiresAt 보관 만료 시각(retention_until). 보관 정책이 없으면 null.
 * @param familyReactions 이 영상에 반응을 남긴 구성원 목록. 반응이 없으면 빈 목록.
 */
public record LaughMemoryResponse(
    VideoResponse video,
    Instant expiresAt,
    Map<String, Integer> reactionCounts,
    String myReaction,
    List<LaughReactionMemberResponse> familyReactions
) {
}
