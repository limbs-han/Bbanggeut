package com.wj.server.stream.infrastructure;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.config.MediaMtxProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * MediaMTX v3 관리 API. GET /v3/paths/get/{name} — 경로가 없으면 404,
 * 있으면 {"ready": true|false, ...}.
 */
@Component
public class HttpMediaMtxClient implements MediaMtxClient {
    private static final Logger log = LoggerFactory.getLogger(HttpMediaMtxClient.class);

    private final MediaMtxProperties properties;
    private final HttpClient httpClient;
    private final ObjectMapper objectMapper;

    public HttpMediaMtxClient(MediaMtxProperties properties, ObjectMapper objectMapper) {
        this.properties = properties;
        this.objectMapper = objectMapper;
        this.httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(2))
            .build();
    }

    @Override
    public PathState pathState(String name) {
        if (!properties.enabled()) {
            return PathState.UNKNOWN;
        }
        String base = properties.apiBaseUrl().replaceAll("/+$", "");
        HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create(base + "/v3/paths/get/" + name))
            .timeout(Duration.ofSeconds(3))
            .GET()
            .build();
        try {
            HttpResponse<String> response =
                httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() == 404) {
                return PathState.NOT_READY;
            }
            if (response.statusCode() != 200) {
                log.warn("MediaMTX API unexpected status={} path={}",
                    response.statusCode(), name);
                return PathState.UNKNOWN;
            }
            JsonNode body = objectMapper.readTree(response.body());
            return body.path("ready").asBoolean(false)
                ? PathState.READY
                : PathState.NOT_READY;
        } catch (IOException exception) {
            log.warn("MediaMTX API unreachable path={}", name, exception);
            return PathState.UNKNOWN;
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            return PathState.UNKNOWN;
        }
    }
}
