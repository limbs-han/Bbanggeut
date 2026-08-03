package com.wj.server.video.application;

import java.net.SocketTimeoutException;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.common.ratelimit.SlidingWindowRateLimiter;
import com.wj.server.config.ComicProperties;
import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.api.ComicCutPayload;
import com.wj.server.video.api.ComicImageRequest;
import com.wj.server.video.api.ComicImageResponse;
import com.wj.server.video.api.ComicScriptRequest;
import com.wj.server.video.api.ComicScriptResponse;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

/**
 * Fronts the Python comic worker, which has no authentication of its own and is
 * never exposed outside the server network.
 *
 * <p>The gateway carries the four things the worker deliberately does not: the
 * caller's identity, vault membership on the video, a short-lived read URL for
 * the original, and a per-user call budget. A generative image call costs real
 * credits, so an unbounded endpoint is a billing hole, not just a load problem.
 *
 * <p>Deliberately not {@code @Transactional}: the worker call takes minutes and
 * a transaction would pin a pooled connection for its whole duration. Both
 * routes read a single row, which needs no transaction of its own.
 */
@Service
public class ComicGatewayService {
    private static final Logger LOGGER = LoggerFactory.getLogger(ComicGatewayService.class);

    private static final int CUT_COUNT = 4;
    private static final int MAX_LINES = 400;
    private static final int MAX_TEXT_LENGTH = 200;
    private static final int MAX_STYLE_LENGTH = 40;
    private static final String DEFAULT_STYLE = "webtoon";
    private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(5);

    private final VideoMapper videoMapper;
    private final ObjectStorageService objectStorageService;
    private final AuditService auditService;
    private final SlidingWindowRateLimiter rateLimiter;
    private final ComicProperties properties;
    private final RestClient workerClient;

    public ComicGatewayService(
        VideoMapper videoMapper,
        ObjectStorageService objectStorageService,
        AuditService auditService,
        SlidingWindowRateLimiter rateLimiter,
        ComicProperties properties,
        RestClient.Builder restClientBuilder
    ) {
        this.videoMapper = videoMapper;
        this.objectStorageService = objectStorageService;
        this.auditService = auditService;
        this.rateLimiter = rateLimiter;
        this.properties = properties;
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(CONNECT_TIMEOUT);
        // 워커가 스스로 150초에 끊는다. 여기서 더 짧게 끊으면 워커의 한국어 실패
        // 사유를 잃고 전부 타임아웃으로 뭉개진다.
        requestFactory.setReadTimeout(properties.workerTimeout());
        this.workerClient = restClientBuilder
            .baseUrl(properties.workerBaseUrl())
            .requestFactory(requestFactory)
            .build();
    }

    public ComicScriptResponse createScript(UUID userId, UUID videoId, ComicScriptRequest request) {
        VideoRow video = readyVideo(userId, videoId, "COMIC_SCRIPT");
        List<ComicScriptRequest.TranscriptLine> lines = validLines(request);
        requireBudget(userId, videoId, video, "COMIC_SCRIPT");

        var signed = objectStorageService.createReadUrl(video.storageKey(), false);
        ComicScriptResponse response = callWorker(
            "/v1/comic/" + videoId + "/script",
            Map.of("videoUrl", signed.url(), "lines", lines),
            ComicScriptResponse.class);

        if (response == null || response.cuts() == null || response.cuts().size() != CUT_COUNT) {
            throw workerFailed();
        }
        auditService.success(video.deviceId(), userId, "COMIC_SCRIPT", "VIDEO", videoId);
        return response;
    }

    public ComicImageResponse createImage(UUID userId, UUID videoId, ComicImageRequest request) {
        VideoRow video = readyVideo(userId, videoId, "COMIC_IMAGE");
        List<ComicCutPayload> cuts = validCuts(request);
        requireBudget(userId, videoId, video, "COMIC_IMAGE");

        ComicImageResponse response = callWorker(
            "/v1/comic/" + videoId + "/image",
            Map.of("cuts", cuts, "style", style(request.style())),
            ComicImageResponse.class);

        if (response == null || response.image() == null || response.image().isBlank()) {
            throw workerFailed();
        }
        auditService.success(video.deviceId(), userId, "COMIC_IMAGE", "VIDEO", videoId);
        return response;
    }

    private VideoRow readyVideo(UUID userId, UUID videoId, String action) {
        VideoRow video = videoMapper.findAccessibleVideo(userId, videoId).orElseThrow(
            () -> new ApiException(
                HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다."));
        if (!"READY".equals(video.status())) {
            auditService.denied(
                video.deviceId(), userId, action, "VIDEO", videoId, "VIDEO_NOT_READY");
            throw new ApiException(
                HttpStatus.CONFLICT, "VIDEO_NOT_READY", "영상이 아직 사용 가능한 상태가 아닙니다.");
        }
        return video;
    }

    private void requireBudget(UUID userId, UUID videoId, VideoRow video, String action) {
        boolean admitted = rateLimiter.tryAcquire(
            "comic:user:" + userId,
            "comic:video:" + videoId,
            properties.rateWindow(),
            properties.rateLimit());
        if (!admitted) {
            auditService.denied(
                video.deviceId(), userId, action, "VIDEO", videoId, "COMIC_RATE_LIMITED");
            throw new ApiException(
                HttpStatus.TOO_MANY_REQUESTS,
                "COMIC_RATE_LIMITED",
                "만화 만들기 요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.");
        }
    }

    private List<ComicScriptRequest.TranscriptLine> validLines(ComicScriptRequest request) {
        List<ComicScriptRequest.TranscriptLine> lines =
            request == null ? null : request.lines();
        if (lines == null || lines.isEmpty()) {
            throw validation("전사문이 비어 있습니다.");
        }
        if (lines.size() > MAX_LINES) {
            throw validation("전사문 줄 수는 " + MAX_LINES + "개 이하여야 합니다.");
        }
        for (ComicScriptRequest.TranscriptLine line : lines) {
            if (line == null || line.text() == null || line.text().isBlank()) {
                throw validation("전사문 각 줄에는 text가 있어야 합니다.");
            }
            if (line.text().length() > MAX_TEXT_LENGTH) {
                throw validation("전사문 한 줄은 " + MAX_TEXT_LENGTH + "자 이하여야 합니다.");
            }
            if (line.startMs() == null || line.startMs() < 0) {
                throw validation("startMs는 0 이상이어야 합니다.");
            }
        }
        return lines;
    }

    private List<ComicCutPayload> validCuts(ComicImageRequest request) {
        List<ComicCutPayload> cuts = request == null ? null : request.cuts();
        if (cuts == null || cuts.size() != CUT_COUNT) {
            throw validation("cuts는 " + CUT_COUNT + "개여야 합니다.");
        }
        for (ComicCutPayload cut : cuts) {
            if (cut == null || cut.scene() == null || cut.scene().isBlank()) {
                throw validation("각 컷에는 scene이 있어야 합니다.");
            }
            if (cut.dialogue() != null && cut.dialogue().length() > MAX_TEXT_LENGTH) {
                throw validation("대사는 " + MAX_TEXT_LENGTH + "자 이하여야 합니다.");
            }
        }
        return cuts;
    }

    private String style(String requested) {
        if (requested == null || requested.isBlank()) {
            return DEFAULT_STYLE;
        }
        if (requested.length() > MAX_STYLE_LENGTH) {
            throw validation("style은 " + MAX_STYLE_LENGTH + "자 이하여야 합니다.");
        }
        return requested;
    }

    private <T> T callWorker(String path, Object body, Class<T> responseType) {
        try {
            return workerClient.post().uri(path).body(body).retrieve().body(responseType);
        } catch (RestClientResponseException exception) {
            if (exception.getStatusCode().value() == HttpStatus.UNPROCESSABLE_ENTITY.value()) {
                // 워커가 재료 부족으로 거절한 경우다. 다시 눌러도 같은 결과이므로
                // 사용자에게 다른 영상을 고르라고 알려야 한다.
                throw new ApiException(
                    HttpStatus.UNPROCESSABLE_ENTITY,
                    "COMIC_UNPROCESSABLE",
                    "이 영상으로는 만화를 만들 수 없습니다. 대화가 담긴 다른 영상을 골라 주세요.");
            }
            LOGGER.warn("Comic worker rejected {} status={}", path, exception.getStatusCode());
            throw workerFailed();
        } catch (ResourceAccessException exception) {
            // 워커가 꺼진 것과 오래 걸리는 것을 같은 문구로 알리면 사용자가 영원히
            // 다시 누른다. 원인을 나눠 알린다.
            LOGGER.warn("Comic worker unreachable or too slow {}", path, exception);
            if (exception.getCause() instanceof SocketTimeoutException) {
                throw new ApiException(
                    HttpStatus.GATEWAY_TIMEOUT,
                    "COMIC_WORKER_TIMEOUT",
                    "만화를 만드는 데 시간이 너무 오래 걸립니다. 잠시 후 다시 시도해 주세요.");
            }
            throw new ApiException(
                HttpStatus.SERVICE_UNAVAILABLE,
                "COMIC_WORKER_UNAVAILABLE",
                "만화 만들기 기능을 지금 사용할 수 없습니다.");
        }
    }

    private ApiException workerFailed() {
        return new ApiException(
            HttpStatus.BAD_GATEWAY, "COMIC_WORKER_FAILED", "만화를 만들지 못했습니다. 잠시 후 다시 시도해 주세요.");
    }

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }
}
