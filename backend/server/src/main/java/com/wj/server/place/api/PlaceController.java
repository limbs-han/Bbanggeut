package com.wj.server.place.api;

import java.util.UUID;

import com.wj.server.place.application.PlaceService;
import jakarta.validation.Valid;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class PlaceController {
    private final PlaceService service;

    public PlaceController(PlaceService service) {
        this.service = service;
    }

    /** 금고의 장소 배치와 부른 사람의 기기 순서. */
    @GetMapping("/api/vaults/{vaultId}/places")
    public PlaceLayoutResponse getLayout(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId
    ) {
        return service.get(userId(jwt), vaultId);
    }

    /** 장소 이름과 기기 배정을 통째로 바꾼다. 금고 구성원 누구나. */
    @PutMapping("/api/vaults/{vaultId}/places")
    public PlaceLayoutResponse replaceLayout(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId,
        @Valid @RequestBody UpdatePlaceLayoutRequest request
    ) {
        return service.replaceLayout(userId(jwt), vaultId, request);
    }

    /** 기기 순서를 바꾼다. 부른 사람에게만 적용된다. */
    @PutMapping("/api/vaults/{vaultId}/device-order")
    public PlaceLayoutResponse replaceDeviceOrder(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId,
        @Valid @RequestBody UpdateDeviceOrderRequest request
    ) {
        return service.replaceDeviceOrder(userId(jwt), vaultId, request);
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
