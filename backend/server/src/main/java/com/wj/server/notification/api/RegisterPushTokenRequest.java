package com.wj.server.notification.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

public record RegisterPushTokenRequest(
    @NotBlank @Size(max = 128) String installationId,
    @NotBlank @Size(max = 4096) String token,
    @NotNull PushPlatform platform
) {
}
