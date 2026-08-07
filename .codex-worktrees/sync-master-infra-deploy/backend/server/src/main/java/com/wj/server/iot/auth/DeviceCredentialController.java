package com.wj.server.iot.auth;

import com.wj.server.provisioning.api.ProvisionedDeviceResponse;
import com.wj.server.provisioning.application.ProvisioningService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/iot")
public class DeviceCredentialController {
    private final ProvisioningService provisioningService;

    public DeviceCredentialController(ProvisioningService provisioningService) {
        this.provisioningService = provisioningService;
    }

    /** Exchanges the short-lived, one-use factory credential for an operating credential. */
    @PostMapping("/enrollment")
    public ProvisionedDeviceResponse enroll(@AuthenticationPrincipal DevicePrincipal device) {
        return provisioningService.enroll(device.deviceId(), device.keyId());
    }

    /** Rotates an operating credential while the currently valid credential proves possession. */
    @PostMapping("/credentials/rotate")
    public ProvisionedDeviceResponse rotate(@AuthenticationPrincipal DevicePrincipal device) {
        return provisioningService.rotateSelf(device.deviceId(), device.keyId());
    }
}
