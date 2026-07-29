package com.wj.server.device.api;

import java.util.UUID;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

public record ClaimDeviceRequest(
    @NotBlank @Size(min = 8, max = 12) String registrationCode,
    @Size(min = 1, max = 80)
    @Pattern(regexp = ".*\\S.*", message = "공백만 입력할 수 없습니다.")
    String name,
    UUID vaultId
) {
    public ClaimDeviceRequest(String registrationCode, String name) {
        this(registrationCode, name, null);
    }
}
