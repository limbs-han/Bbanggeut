package com.wj.server.vault.application;

import java.time.Clock;
import java.time.DateTimeException;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.temporal.ChronoUnit;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.vault.api.VaultEventStatsResponse;
import com.wj.server.vault.persistence.VaultEventStatsMapper;
import com.wj.server.vault.persistence.VaultMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 금고(가족) 단위 이벤트 통계. 기기 단위 API-46과 같은 계약(from/to/timeZone/
 * type)에 기기별 분해(byDevice)를 더했다 — 한 금고에 기기 여러 대를 묶은
 * 가족이 리포트를 합산으로 본다.
 */
@Service
public class VaultEventStatsService {
    private static final String DEFAULT_ZONE = "Asia/Seoul";
    private final VaultEventStatsMapper mapper;
    private final VaultMapper vaultMapper;
    private final Clock clock;

    @Autowired
    public VaultEventStatsService(VaultEventStatsMapper mapper, VaultMapper vaultMapper) {
        this(mapper, vaultMapper, Clock.systemUTC());
    }

    VaultEventStatsService(
        VaultEventStatsMapper mapper, VaultMapper vaultMapper, Clock clock
    ) {
        this.mapper = mapper;
        this.vaultMapper = vaultMapper;
        this.clock = clock;
    }

    @Transactional(readOnly = true)
    public VaultEventStatsResponse get(
        UUID userId,
        UUID vaultId,
        LocalDate requestedFrom,
        LocalDate requestedTo,
        String requestedZone,
        String requestedType
    ) {
        if (vaultMapper.findActiveRole(userId, vaultId).isEmpty()) {
            throw new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
        }
        ZoneId zone = parseZone(requestedZone);
        String type = parseType(requestedType);
        LocalDate to = requestedTo == null ? LocalDate.now(clock.withZone(zone)) : requestedTo;
        LocalDate from = requestedFrom == null ? to.minusDays(29) : requestedFrom;
        if (from.isAfter(to) || ChronoUnit.DAYS.between(from, to) > 365) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED",
                "조회 기간은 시작일이 종료일보다 빠른 최대 366일이어야 합니다.");
        }
        var fromInstant = from.atStartOfDay(zone).toInstant();
        var toExclusive = to.plusDays(1).atStartOfDay(zone).toInstant();
        return new VaultEventStatsResponse(
            vaultId, from, to, zone.getId(),
            mapper.countEvents(vaultId, fromInstant, toExclusive, type),
            mapper.countReadyUploads(vaultId, fromInstant, toExclusive),
            mapper.countByType(vaultId, fromInstant, toExclusive).stream()
                .map(row -> new VaultEventStatsResponse.NamedCount(row.label(), row.count()))
                .toList(),
            mapper.countByDevice(vaultId, fromInstant, toExclusive, type).stream()
                .map(row -> new VaultEventStatsResponse.DeviceCount(
                    row.deviceId(), row.name(), row.count()))
                .toList(),
            mapper.countByDay(vaultId, fromInstant, toExclusive, zone.getId(), type).stream()
                .map(row -> new VaultEventStatsResponse.DailyCount(row.date(), row.count()))
                .toList());
    }

    private ZoneId parseZone(String value) {
        try {
            return ZoneId.of(value == null || value.isBlank() ? DEFAULT_ZONE : value);
        } catch (DateTimeException exception) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", "지원하지 않는 timeZone입니다.");
        }
    }

    private String parseType(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        String normalized = value.strip().toUpperCase();
        if (!normalized.matches("[A-Z_]{1,32}")) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", "지원하지 않는 이벤트 타입입니다.");
        }
        return normalized;
    }
}
