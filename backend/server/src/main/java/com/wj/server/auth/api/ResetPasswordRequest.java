package com.wj.server.auth.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record ResetPasswordRequest(
    @NotBlank @Size(min = 32, max = 200) String token,
    @NotBlank @Size(min = 10, max = 72) String newPassword
) {
}
