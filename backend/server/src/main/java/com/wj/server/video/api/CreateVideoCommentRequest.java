package com.wj.server.video.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record CreateVideoCommentRequest(
    @NotBlank @Size(max = 500) String body
) {
}
