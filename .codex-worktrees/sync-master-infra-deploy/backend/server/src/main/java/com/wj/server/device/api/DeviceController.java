package com.wj.server.device.api;

import java.util.List;
import java.util.UUID;

import com.wj.server.device.application.DeviceService;
import jakarta.validation.Valid;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/devices")
public class DeviceController {
    private final DeviceService deviceService;

    public DeviceController(DeviceService deviceService) {
        this.deviceService = deviceService;
    }

    @GetMapping
    public List<DeviceSummaryResponse> list(@AuthenticationPrincipal Jwt jwt) {
        return deviceService.list(userId(jwt));
    }

    @PostMapping("/claim")
    public ResponseEntity<DeviceResponse> claim(
        @AuthenticationPrincipal Jwt jwt,
        @Valid @RequestBody ClaimDeviceRequest request,
        HttpServletRequest servletRequest
    ) {
        return ResponseEntity.status(HttpStatus.CREATED)
            .body(deviceService.claim(userId(jwt), request, servletRequest.getRemoteAddr()));
    }

    @GetMapping("/{deviceId}")
    public DeviceResponse get(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId
    ) {
        return deviceService.get(userId(jwt), deviceId);
    }

    @PatchMapping("/{deviceId}")
    public DeviceResponse update(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId,
        @Valid @RequestBody UpdateDeviceRequest request
    ) {
        return deviceService.update(userId(jwt), deviceId, request);
    }

    @GetMapping("/{deviceId}/status")
    public DeviceStatusResponse status(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId
    ) {
        return deviceService.status(userId(jwt), deviceId);
    }

    @PostMapping("/{deviceId}/transfer-ownership")
    public ResponseEntity<Void> transferOwnership(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId,
        @Valid @RequestBody TransferOwnershipRequest request
    ) {
        deviceService.transferOwnership(userId(jwt), deviceId, request);
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/{deviceId}")
    public ResponseEntity<Void> revoke(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId
    ) {
        deviceService.revoke(userId(jwt), deviceId);
        return ResponseEntity.noContent().build();
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
