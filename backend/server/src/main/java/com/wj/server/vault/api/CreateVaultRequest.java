package com.wj.server.vault.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record CreateVaultRequest(
    @NotBlank @Size(max = 80) String name
) {
}
