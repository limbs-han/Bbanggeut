package com.wj.server.video.api;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record CreateVideoEditRequest(
    @Min(0) long startMs,
    @Min(1) long endMs,
    @NotBlank @Size(max = 120) String title
) {
}
