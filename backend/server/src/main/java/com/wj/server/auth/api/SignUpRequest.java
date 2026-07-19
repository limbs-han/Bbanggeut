package com.wj.server.auth.api;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record SignUpRequest(
    @NotBlank @Email @Size(max = 320) String email,
    @NotBlank @Size(min = 10, max = 72) String password,
    @NotBlank @Size(max = 60) String displayName
) {
}
