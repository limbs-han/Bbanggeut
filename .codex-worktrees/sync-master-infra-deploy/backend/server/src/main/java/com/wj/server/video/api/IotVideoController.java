package com.wj.server.video.api;

import com.wj.server.iot.auth.DevicePrincipal;
import com.wj.server.video.application.IotVideoService;
import jakarta.validation.Valid;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/iot/videos")
public class IotVideoController {
    private final IotVideoService iotVideoService;

    public IotVideoController(IotVideoService iotVideoService) {
        this.iotVideoService = iotVideoService;
    }

    @PostMapping("/upload-url")
    public IotUploadUrlResponse createUploadUrl(
        @AuthenticationPrincipal DevicePrincipal device,
        @RequestHeader("Idempotency-Key") String idempotencyKey,
        @Valid @RequestBody IotUploadUrlRequest request
    ) {
        return iotVideoService.createUploadUrl(device.deviceId(), idempotencyKey, request);
    }

    @PostMapping("/complete")
    public VideoResponse complete(
        @AuthenticationPrincipal DevicePrincipal device,
        @RequestHeader("Idempotency-Key") String idempotencyKey,
        @Valid @RequestBody IotUploadCompleteRequest request
    ) {
        return iotVideoService.complete(device.deviceId(), idempotencyKey, request);
    }
}
