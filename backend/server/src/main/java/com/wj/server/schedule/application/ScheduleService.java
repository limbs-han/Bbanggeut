package com.wj.server.schedule.application;

import java.util.List;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.schedule.api.ScheduleRequest;
import com.wj.server.schedule.api.ScheduleResponse;
import com.wj.server.schedule.domain.ScheduleRow;
import com.wj.server.schedule.persistence.ScheduleMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class ScheduleService {
    /** 캘린더 화면이 전체 목록을 한 번에 그리므로 상한으로 폭주만 막는다. */
    static final int MAX_SCHEDULES_PER_USER = 200;

    private final ScheduleMapper mapper;

    public ScheduleService(ScheduleMapper mapper) {
        this.mapper = mapper;
    }

    @Transactional(readOnly = true)
    public List<ScheduleResponse> list(UUID userId) {
        return mapper.findForUser(userId).stream().map(ScheduleResponse::from).toList();
    }

    @Transactional
    public ScheduleResponse create(UUID userId, ScheduleRequest request) {
        if (mapper.countForUser(userId) >= MAX_SCHEDULES_PER_USER) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED",
                "일정은 최대 " + MAX_SCHEDULES_PER_USER + "개까지 등록할 수 있습니다.");
        }
        ScheduleRow row = new ScheduleRow(
            UUID.randomUUID(), userId, request.title().strip(), request.date(),
            request.memoOrEmpty(), request.yearlyOrFalse(), request.emojiOrDefault());
        mapper.insert(
            row.id(), row.userId(), row.title(), row.scheduleDate(),
            row.memo(), row.yearly(), row.emoji());
        return ScheduleResponse.from(row);
    }

    @Transactional
    public ScheduleResponse update(UUID userId, UUID scheduleId, ScheduleRequest request) {
        int updated = mapper.update(
            scheduleId, userId, request.title().strip(), request.date(),
            request.memoOrEmpty(), request.yearlyOrFalse(), request.emojiOrDefault());
        if (updated != 1) {
            throw scheduleNotFound();
        }
        return new ScheduleResponse(
            scheduleId, request.title().strip(), request.date(),
            request.memoOrEmpty(), request.yearlyOrFalse(), request.emojiOrDefault());
    }

    @Transactional
    public void delete(UUID userId, UUID scheduleId) {
        if (mapper.delete(scheduleId, userId) != 1) {
            throw scheduleNotFound();
        }
    }

    private ApiException scheduleNotFound() {
        return new ApiException(
            HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "일정을 찾을 수 없습니다.");
    }
}
