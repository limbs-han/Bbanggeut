package com.wj.server.video.api;

import java.time.Instant;
import java.util.UUID;

/**
 * 만화를 만들어 둔 영상 한 건. 추억 탭 목록의 배지에 쓴다.
 *
 * @param videoId 원본 영상 id
 * @param madeAt  처음 완성된 시각
 */
public record VaultComicResponse(UUID videoId, Instant madeAt) {
}
