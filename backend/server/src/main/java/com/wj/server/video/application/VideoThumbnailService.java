package com.wj.server.video.application;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import com.wj.server.config.ComicProperties;
import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.domain.VideoRow;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.security.oauth2.jose.jws.MacAlgorithm;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

/**
 * 목록에 쓸 미리보기 그림을 editor-api에 만들게 시킨다.
 *
 * <p><b>왜 서버가 만드나</b>: 예전에는 앱이 원본을 열어 프레임을 뽑았다. 실측
 * (2026-08-06, 운영 nginx): 영상 299개에 안드로이드 미디어 스택 요청 1,732건,
 * <b>1,943MB</b> — 썸네일 한 장에 6.5MB다. 같은 기간 실제 재생이 1,604MB였으니
 * 목록을 그리는 데 보는 것보다 많이 받았다. 원본 옆에서 뽑아 20KB짜리 JPEG
 * 하나만 내려보내면 그 왕복이 사라진다.
 *
 * <p><b>왜 비동기인가</b>: 이 호출은 기기의 업로드 완료 요청 안에서 일어난다.
 * 워커가 원본을 읽어 ffmpeg를 도는 동안 기기를 붙잡아 두면, 그림 만들기가
 * 느리거나 실패하는 날 업로드까지 함께 느려지거나 실패한다. 그림은 없어도
 * 되는 것이므로(앱이 예전처럼 기기에서 뽑는다) 업로드 경로를 막지 않는다.
 *
 * <p>워커 주소·타임아웃은 만화 게이트웨이와 같은 설정을 쓴다 — 같은 워커다.
 */
@Service
public class VideoThumbnailService {
    private static final Logger LOGGER = LoggerFactory.getLogger(VideoThumbnailService.class);

    private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(5);

    /** 프레임 한 장을 뽑는 일이다. 만화(수십 초)와 달리 오래 걸릴 이유가 없다. */
    private static final Duration READ_TIMEOUT = Duration.ofSeconds(60);

    /** 서비스 토큰 수명. 호출 한 번에만 쓰므로 짧을수록 좋다. */
    private static final Duration TOKEN_TTL = Duration.ofSeconds(60);

    /**
     * 한 번에 몇 장까지 동시에 만들까. 워커는 만화·분석과 CPU를 나눠 쓰므로
     * 썸네일이 그것을 굶기면 안 된다. 업로드는 몰려 와도 그림은 늦게 생겨도
     * 되는 값이다.
     */
    private static final int WORKERS = 2;

    private final ObjectStorageService objectStorageService;
    private final JwtEncoder encoder;
    private final RestClient workerClient;
    private final ExecutorService executor;
    private final Clock clock;

    /**
     * 생성자가 둘이므로 스프링이 쓸 쪽을 표시해야 한다. 빠뜨리면 컨텍스트가
     * "No default constructor found"로 뜨고 배포가 롤백된다 — 2026-08-06
     * master 배포를 실제로 그렇게 깼다. 아래 것은 테스트가 실행자·시계를
     * 넣으려고 쓰는 패키지 전용 생성자다({@code LiveTokenService}와 같은 꼴).
     */
    @Autowired
    public VideoThumbnailService(
        ObjectStorageService objectStorageService,
        JwtEncoder encoder,
        ComicProperties properties,
        RestClient.Builder restClientBuilder
    ) {
        this(objectStorageService, encoder, properties, restClientBuilder,
            Executors.newFixedThreadPool(WORKERS), Clock.systemUTC());
    }

    VideoThumbnailService(
        ObjectStorageService objectStorageService,
        JwtEncoder encoder,
        ComicProperties properties,
        RestClient.Builder restClientBuilder,
        ExecutorService executor,
        Clock clock
    ) {
        this.objectStorageService = objectStorageService;
        this.encoder = encoder;
        this.executor = executor;
        this.clock = clock;
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(CONNECT_TIMEOUT);
        requestFactory.setReadTimeout(READ_TIMEOUT);
        this.workerClient = restClientBuilder
            .baseUrl(properties.workerBaseUrl())
            .requestFactory(requestFactory)
            .build();
    }

    /**
     * 이 영상의 미리보기를 만들라고 맡긴다. 곧바로 돌아온다.
     *
     * <p>실패는 로그로만 남긴다. 그림이 없으면 앱이 예전처럼 기기에서 뽑으므로
     * 사용자가 보는 것은 "느린 목록"이지 "깨진 목록"이 아니다.
     */
    public void requestAsync(VideoRow video) {
        executor.execute(() -> {
            try {
                request(video);
            } catch (RuntimeException failure) {
                LOGGER.warn("미리보기 생성 실패 videoId={}", video.id(), failure);
            }
        });
    }

    /** 워커를 실제로 부른다. 백필처럼 결과를 봐야 하는 호출이 직접 쓴다. */
    public void request(VideoRow video) {
        var signed = objectStorageService.createReadUrl(video.storageKey(), false);
        workerClient.method(HttpMethod.PUT)
            .uri("/v1/videos/{videoId}/thumbnail", video.id())
            .header(HttpHeaders.AUTHORIZATION, "Bearer " + serviceToken())
            .body(Map.of(
                "videoUrl", signed.url(),
                // 길이를 넘겨 주면 워커가 ffprobe를 한 번 덜 돈다. 가운데를
                // 집는 데 필요한 유일한 값이다.
                "durationMs", video.durationMs()))
            .retrieve()
            .toBodilessEntity();
    }

    /**
     * 사람 없이 워커를 부르기 위한 단기 토큰.
     *
     * <p>사용자 토큰을 쓸 수 없다 — 업로드가 끝난 순간에는 청한 사람이 없다.
     * 워커는 이 토큰을 보면 금고 범위를 묻지 않는다. 대신 <b>어느 영상을 읽을지는
     * 위에서 서명한 URL이 정한다</b>: 워커는 그 URL을 읽어 편집 버킷에 쓸 뿐이라
     * 이 경로로 남의 영상을 꺼낼 수 없다.
     */
    private String serviceToken() {
        Instant now = clock.instant();
        JwtClaimsSet claims = JwtClaimsSet.builder()
            .issuer("wj-server")
            .subject("wj-server")
            .issuedAt(now)
            .expiresAt(now.plus(TOKEN_TTL))
            .claim("typ", "editor-service")
            .build();
        return encoder.encode(JwtEncoderParameters.from(
            JwsHeader.with(MacAlgorithm.HS256).build(), claims)).getTokenValue();
    }

    @PreDestroy
    void shutdown() {
        executor.shutdown();
    }
}
