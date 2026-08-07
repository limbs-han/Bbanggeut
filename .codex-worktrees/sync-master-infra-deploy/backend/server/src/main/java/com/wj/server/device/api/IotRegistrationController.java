package com.wj.server.device.api;

import com.wj.server.device.application.RegistrationCodeService;
import com.wj.server.iot.auth.DevicePrincipal;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/iot/registration-codes")
public class IotRegistrationController {
    private final RegistrationCodeService registrationCodeService;

    public IotRegistrationController(RegistrationCodeService registrationCodeService) {
        this.registrationCodeService = registrationCodeService;
    }

    @PostMapping
    public RegistrationCodeResponse issue(@AuthenticationPrincipal DevicePrincipal device) {
        return registrationCodeService.issue(device.deviceId());
    }
}
