package com.wj.server.iot.event;

import java.time.Clock;
import java.time.DateTimeException;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.temporal.ChronoUnit;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class EventStatsService {
    private static final String DEFAULT_ZONE = "Asia/Seoul";
    private final DeviceEventMapper mapper;
    private final Clock clock;

    @Autowired
    public EventStatsService(DeviceEventMapper mapper) {
        this(mapper, Clock.systemUTC());
    }

    EventStatsService(DeviceEventMapper mapper, Clock clock) {
        this.mapper = mapper;
        this.clock = clock;
    }

    @Transactional(readOnly = true)
    public EventStatsResponse get(
        UUID userId,
        UUID deviceId,
        LocalDate requestedFrom,
        LocalDate requestedTo,
        String requestedZone
    ) {
        if (!mapper.hasActiveMembership(userId, deviceId)) {
            throw new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
        }
        ZoneId zone = parseZone(requestedZone);
        LocalDate to = requestedTo == null ? LocalDate.now(clock.withZone(zone)) : requestedTo;
        LocalDate from = requestedFrom == null ? to.minusDays(29) : requestedFrom;
        if (from.isAfter(to) || ChronoUnit.DAYS.between(from, to) > 365) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED",
                "조회 기간은 시작일이 종료일보다 빠른 최대 366일이어야 합니다.");
        }
        var fromInstant = from.atStartOfDay(zone).toInstant();
        var toExclusive = to.plusDays(1).atStartOfDay(zone).toInstant();
        return new EventStatsResponse(
            deviceId, from, to, zone.getId(),
            mapper.countEvents(deviceId, fromInstant, toExclusive),
            mapper.countReadyUploads(deviceId, fromInstant, toExclusive),
            mapper.countByType(deviceId, fromInstant, toExclusive).stream()
                .map(row -> new EventStatsResponse.NamedCount(row.label(), row.count())).toList(),
            mapper.countByDay(deviceId, fromInstant, toExclusive, zone.getId()).stream()
                .map(row -> new EventStatsResponse.DailyCount(row.date(), row.count())).toList());
    }

    private ZoneId parseZone(String value) {
        try {
            return ZoneId.of(value == null || value.isBlank() ? DEFAULT_ZONE : value);
        } catch (DateTimeException exception) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", "지원하지 않는 timeZone입니다.");
        }
    }
}
