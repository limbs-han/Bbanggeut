package com.wj.server.video.api;

import java.time.Instant;
import java.util.UUID;

/**
 * 만화 한 장. 추억 탭의 만화 피드가 이 목록을 그대로 그린다.
 *
 * <p>그림 주소는 여기 없다. 만화 PNG는 워커 저장소에 있고 단기 서명 URL로만
 * 받을 수 있어서, 목록에 담으면 화면에 보이지도 않는 만화의 URL까지 발급하고
 * 그 사이 만료된다. 앱이 화면에 들어온 카드만 {@code GET
 * /api/videos/{videoId}/comic/image}로 받는다.
 *
 * @param videoId      원본 영상 id. 만화의 식별자이기도 하다
 * @param title        보여 줄 제목. 붙인 제목이 없으면 원본 영상 제목이다
 * @param customTitle  사용자가 제목을 붙였는가. 제목 고치기 창의 기본값을 가른다
 * @param madeAt       처음 완성된 시각
 * @param likeCount    좋아요 수
 * @param likedByMe    지금 보는 사람이 눌렀는가
 * @param commentCount 댓글 수
 * @param canDelete    지금 보는 사람이 이 만화를 지울 수 있는가(만든 사람 또는
 *                     금고 OWNER). 앱은 이 값으로 삭제 버튼을 보이고 감춘다 —
 *                     규칙을 앱이 다시 계산하면 서버와 어긋난다
 */
public record VaultComicResponse(
    UUID videoId,
    String title,
    boolean customTitle,
    Instant madeAt,
    int likeCount,
    boolean likedByMe,
    int commentCount,
    boolean canDelete
) {
}
