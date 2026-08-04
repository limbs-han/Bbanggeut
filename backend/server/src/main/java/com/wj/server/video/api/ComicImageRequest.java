package com.wj.server.video.api;

import java.util.List;

public record ComicImageRequest(List<ComicCutPayload> cuts, String style) {
}
