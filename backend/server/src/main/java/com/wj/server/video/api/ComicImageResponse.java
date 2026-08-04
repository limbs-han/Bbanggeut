package com.wj.server.video.api;

/**
 * {@code image} is bare base64 PNG. A {@code data:} prefix would break the
 * app's decoder, so the gateway passes the worker's value through untouched.
 */
public record ComicImageResponse(String image) {
}
