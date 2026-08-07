package com.wj.server.home.application;

import java.time.Clock;
import java.time.DateTimeException;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.home.api.HomeSummaryResponse;
import com.wj.server.video.api.VideoResponse;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class HomeSummaryService {
    private static final String DEFAULT_ZONE = "Asia/Seoul";

    private final VideoMapper mapper;
    private final Clock clock;

    @Autowired
    public HomeSummaryService(VideoMapper mapper) {
        this(mapper, Clock.systemUTC());
    }

    HomeSummaryService(VideoMapper mapper, Clock clock) {
        this.mapper = mapper;
        this.clock = clock;
    }

    @Transactional(readOnly = true)
    public HomeSummaryResponse get(UUID userId, UUID deviceId, String requestedZone) {
        if (!mapper.hasActiveMembership(userId, deviceId)) {
            throw new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
        }
        ZoneId zone = parseZone(requestedZone);
        LocalDate today = LocalDate.now(clock.withZone(zone));
        Instant from = today.atStartOfDay(zone).toInstant();
        Instant to = today.plusDays(1).atStartOfDay(zone).toInstant();

        // Every captured moment becomes a saved video in the current model, so
        // capture and saved share one query; they diverge once the edge reports
        // raw event counts separately.
        long saved = mapper.countReadyVideos(deviceId, from, to);
        long memo = mapper.countReadyVideosWithMemo(deviceId, from, to);
        VideoResponse highlight = mapper.findLatestHighlight(userId, deviceId)
            .map(this::toResponse)
            .orElse(null);
        return new HomeSummaryResponse(deviceId, today, zone.getId(), saved, saved, memo, highlight);
    }

    private ZoneId parseZone(String value) {
        try {
            return ZoneId.of(value == null || value.isBlank() ? DEFAULT_ZONE : value);
        } catch (DateTimeException exception) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", "지원하지 않는 timeZone입니다.");
        }
    }

    private VideoResponse toResponse(VideoRow video) {
        return new VideoResponse(
            video.id(), video.deviceId(), video.sourceType(), video.triggerType(),
            video.sourceEventId(), video.title(), video.description(), video.contentType(), video.sizeBytes(),
            video.checksumSha256(), video.durationMs(), video.capturedStartAt(),
            video.capturedEndAt(), video.status(), video.favorite(), null, video.createdAt());
    }
}
