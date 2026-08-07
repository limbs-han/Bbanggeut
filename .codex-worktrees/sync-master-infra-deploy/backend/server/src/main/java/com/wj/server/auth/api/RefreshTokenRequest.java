package com.wj.server.auth.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record RefreshTokenRequest(
    @NotBlank @Size(min = 32, max = 2048) String refreshToken
) {
}
