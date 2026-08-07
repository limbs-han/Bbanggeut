package com.wj.server.provisioning.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record ProvisionDeviceRequest(
    @NotBlank @Size(max = 80) String serialNumber,
    @NotBlank @Size(max = 80) String name,
    @NotBlank @Size(max = 80) String model,
    @Size(max = 40) String firmwareVersion
) {
}
