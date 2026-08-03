package com.wj.server.video.api;

/**
 * One panel of the four-cut comic. {@code dialogue} is drawn by the app as a
 * subtitle band, never by the image model.
 */
public record ComicCutPayload(String beat, String scene, String dialogue) {
}
