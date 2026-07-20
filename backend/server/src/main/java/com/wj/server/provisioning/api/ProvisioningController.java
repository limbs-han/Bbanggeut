package com.wj.server.provisioning.api;

import java.util.UUID;

import com.wj.server.provisioning.application.ProvisioningService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/internal/admin/devices")
public class ProvisioningController {
    private final ProvisioningService service;

    public ProvisioningController(ProvisioningService service) {
        this.service = service;
    }

    @PostMapping
    public ResponseEntity<ProvisionedDeviceResponse> provision(
        @Valid @RequestBody ProvisionDeviceRequest request
    ) {
        return ResponseEntity.status(HttpStatus.CREATED).body(service.provision(request));
    }

    @PostMapping("/{deviceId}/credentials/rotate")
    public ProvisionedDeviceResponse rotate(
        @PathVariable UUID deviceId
    ) {
        return service.rotate(deviceId);
    }

    @DeleteMapping("/{deviceId}/credentials")
    public ResponseEntity<Void> revoke(
        @PathVariable UUID deviceId
    ) {
        service.revoke(deviceId);
        return ResponseEntity.noContent().build();
    }
}
