package com.wj.server.video.api;

import java.util.List;
import java.util.UUID;

import com.wj.server.notification.application.NotificationService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

/**
 * 금고에서 만화를 만들어 둔 영상 목록. 추억 탭 목록이 배지를 그리는 데 쓴다.
 *
 * <p>영상마다 워커에 "만화 있냐"고 묻지 않는다 — 목록이 100건이면 왕복도 100번이다.
 * 만화가 완성될 때마다 남는 COMIC_READY 알림 행을 기록으로 쓴다.
 */
@RestController
public class VaultComicController {
    private final NotificationService notifications;

    public VaultComicController(NotificationService notifications) {
        this.notifications = notifications;
    }

    @GetMapping("/api/vaults/{vaultId}/comics")
    public List<VaultComicResponse> list(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId
    ) {
        return notifications
            .listVaultComics(UUID.fromString(jwt.getSubject()), vaultId)
            .stream()
            .map(row -> new VaultComicResponse(row.videoId(), row.madeAt()))
            .toList();
    }
}
