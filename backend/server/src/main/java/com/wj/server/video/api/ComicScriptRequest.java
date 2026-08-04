package com.wj.server.video.api;

import java.util.List;

/**
 * Transcript the app produced on the device. The server never transcribes; it
 * only forwards these lines to the comic worker.
 */
public record ComicScriptRequest(List<TranscriptLine> lines) {
    public record TranscriptLine(Long startMs, String text) {
    }
}
