package com.wj.server.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * MediaMTX 관리 API 연동. api-base-url이 비어 있으면 유령 세션 대사
 * (reconcile)가 꺼진다 — 로컬 개발·테스트는 MediaMTX 없이도 돌아야 한다.
 *
 * <p>미확인 횟수를 두 단계로 센다. {@code missesBeforeFailure}는 "미디어가
 * 흐르지 않는다"를 판정하는 문턱이고, 여기서는 세션을 죽이지 않고 재연결
 * 대기로 내린다. {@code missesBeforeGiveUp}까지도 돌아오지 않으면 그때
 * 실패로 확정한다. 문턱이 하나였을 때는 모바일망의 몇 초짜리 끊김이 곧바로
 * 세션 종료가 되어, 사용자가 매번 라이브를 다시 시작해야 했다.
 *
 * @param missesBeforeFailure 재연결 대기로 내리기까지의 연속 미확인 횟수
 * @param missesBeforeGiveUp  실패로 확정하기까지의 연속 미확인 횟수
 */
@ConfigurationProperties(prefix = "app.mediamtx")
public record MediaMtxProperties(
    String apiBaseUrl,
    String pathPrefix,
    int missesBeforeFailure,
    int missesBeforeGiveUp
) {
    public MediaMtxProperties {
        if (pathPrefix == null || pathPrefix.isBlank()) {
            pathPrefix = "live";
        }
        if (missesBeforeFailure <= 0) {
            missesBeforeFailure = 2;
        }
        // 포기 문턱이 판정 문턱보다 크지 않으면 유예가 사라진다 — 설정을
        // 잘못 주더라도 최소 한 주기는 기다리게 둔다.
        if (missesBeforeGiveUp <= missesBeforeFailure) {
            missesBeforeGiveUp = missesBeforeFailure * 4;
        }
    }

    public boolean enabled() {
        return apiBaseUrl != null && !apiBaseUrl.isBlank();
    }
}
