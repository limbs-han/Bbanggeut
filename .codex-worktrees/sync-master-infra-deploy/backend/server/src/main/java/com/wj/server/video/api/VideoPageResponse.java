package com.wj.server.video.api;

import java.util.List;

public record VideoPageResponse(
    List<VideoResponse> items,
    String nextCursor,
    boolean hasNext
) {
}
