package com.wj.server.device.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

public record ClaimDeviceRequest(
    @NotBlank @Size(max = 80) String serialNumber,
    @NotBlank @Size(min = 8, max = 100) String productCode,
    @Size(min = 1, max = 80)
    @Pattern(regexp = ".*\\S.*", message = "공백만 입력할 수 없습니다.")
    String name
) {
}
