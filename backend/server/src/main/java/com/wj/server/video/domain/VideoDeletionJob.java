package com.wj.server.video.domain;

import java.util.UUID;

public record VideoDeletionJob(
    long id,
    UUID videoId,
    String storageKey,
    String thumbnailStorageKey,
    int attempts
) {
}
