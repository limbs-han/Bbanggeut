package com.wj.server.video.api;

import java.util.List;

/**
 * 백그라운드 만화 작업의 상태. 워커(editor-api)의 응답을 그대로 옮긴다.
 *
 * @param videoId       원본 영상 id
 * @param status        none | queued | running | done | failed
 * @param error         실패 사유. 실패가 아니면 null
 * @param queuePosition 대기 순번. 0이면 지금 그리는 중이거나 이미 끝났다
 * @param imageUrl      다 됐으면 그림을 받을 단기 URL. 없으면 null
 * @param savedAt       그림을 저장한 시각. 없으면 null
 * @param cuts          저장해 둔 4컷 구성. 앱이 화면에 다시 들어올 때 구성을
 *                      새로 받지 않게 하려고 함께 준다 — 그 호출은 과금이고,
 *                      새로 받으면 사용자가 고친 대사가 서버 원문으로 덮인다.
 *                      만든 적이 없으면 null
 */
public record ComicJobResponse(
    String videoId,
    String status,
    String error,
    int queuePosition,
    String imageUrl,
    String savedAt,
    List<ComicCutPayload> cuts
) {
}
