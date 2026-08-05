package com.wj.server.notification.domain;

import java.time.Instant;
import java.util.UUID;

/**
 * 만화를 만들어 둔 영상 한 건.
 *
 * @param videoId 원본 영상 id
 * @param madeAt  처음 완성된 시각(COMIC_READY 알림이 남은 시각)
 */
public record ComicMadeRow(UUID videoId, Instant madeAt) {
}
