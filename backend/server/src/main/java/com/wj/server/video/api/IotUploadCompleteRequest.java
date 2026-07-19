package com.wj.server.video.api;

import java.util.UUID;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

public record IotUploadCompleteRequest(
    @NotNull UUID videoId,
    @Size(max = 200) String objectETag
) {
}
