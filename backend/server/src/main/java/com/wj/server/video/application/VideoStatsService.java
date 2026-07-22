package com.wj.server.video.application;

import java.time.Clock;
import java.time.DateTimeException;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.video.api.VideoStatsResponse;
import com.wj.server.video.api.VideoStatsResponse.DailyCount;
import com.wj.server.video.api.VideoStatsResponse.NamedCount;
import com.wj.server.video.domain.VideoCountRow;
import com.wj.server.video.persistence.VideoMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class VideoStatsService {
    private static final String DEFAULT_ZONE = "Asia/Seoul";
    private static final String[] WEEKDAYS = {"MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"};

    private final VideoMapper mapper;
    private final Clock clock;

    @Autowired
    public VideoStatsService(VideoMapper mapper) {
        this(mapper, Clock.systemUTC());
    }

    VideoStatsService(VideoMapper mapper, Clock clock) {
        this.mapper = mapper;
        this.clock = clock;
    }

    @Transactional(readOnly = true)
    public VideoStatsResponse get(
        UUID userId, UUID deviceId, LocalDate requestedFrom, LocalDate requestedTo, String requestedZone
    ) {
        if (!mapper.hasActiveMembership(userId, deviceId)) {
            throw new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
        }
        ZoneId zone = parseZone(requestedZone);
        LocalDate to = requestedTo == null ? LocalDate.now(clock.withZone(zone)) : requestedTo;
        LocalDate from = requestedFrom == null ? to.minusDays(29) : requestedFrom;
        if (from.isAfter(to) || ChronoUnit.DAYS.between(from, to) > 365) {
            throw validation("조회 기간은 시작일이 종료일보다 빠른 최대 366일이어야 합니다.");
        }
        var fromInstant = from.atStartOfDay(zone).toInstant();
        var toExclusive = to.plusDays(1).atStartOfDay(zone).toInstant();
        List<VideoCountRow> triggerRows = mapper.countReadyVideosByTrigger(deviceId, fromInstant, toExclusive);
        List<DailyCount> daily = mapper.countReadyVideosByDay(deviceId, fromInstant, toExclusive, zone.getId())
            .stream().map(row -> new DailyCount(row.date(), row.count())).toList();
        return new VideoStatsResponse(
            deviceId, from, to, zone.getId(), mapper.countReadyVideos(deviceId, fromInstant, toExclusive),
            triggerRows.stream().map(row -> new NamedCount(row.label(), row.count())).toList(),
            daily,
            peakWeekday(mapper.countReadyVideosByWeekday(deviceId, fromInstant, toExclusive, zone.getId())),
            peakHour(mapper.countReadyVideosByHour(deviceId, fromInstant, toExclusive, zone.getId())));
    }

    private ZoneId parseZone(String value) {
        try {
            return ZoneId.of(value == null || value.isBlank() ? DEFAULT_ZONE : value);
        } catch (DateTimeException exception) {
            throw validation("지원하지 않는 timeZone입니다.");
        }
    }

    private NamedCount peakWeekday(List<VideoCountRow> rows) {
        if (rows.isEmpty()) {
            return null;
        }
        int index = Integer.parseInt(rows.get(0).label()) - 1;
        return new NamedCount(WEEKDAYS[index], rows.get(0).count());
    }

    private NamedCount peakHour(List<VideoCountRow> rows) {
        if (rows.isEmpty()) {
            return null;
        }
        return new NamedCount(String.format("%02d:00", Integer.parseInt(rows.get(0).label())), rows.get(0).count());
    }

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }
}
