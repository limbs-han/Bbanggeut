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

/**
 * 금고 공유 일정.
 *
 * <p>일정은 가족이 함께 보는 것이다 — 기념일을 각자 따로 적을 이유가 없다.
 * 그래서 조회는 사용자가 속한 금고 전체를 훑고, 작성은 구성원 누구나 하며,
 * 수정·삭제는 작성자와 금고 OWNER에게만 연다(댓글·편집본과 같은 규칙).
 */
@Service
public class ScheduleService {
    /** 캘린더 화면이 전체 목록을 한 번에 그리므로 상한으로 폭주만 막는다. */
    static final int MAX_SCHEDULES_PER_VAULT = 200;

    private final ScheduleMapper mapper;

    public ScheduleService(ScheduleMapper mapper) {
        this.mapper = mapper;
    }

    @Transactional(readOnly = true)
    public List<ScheduleResponse> list(UUID userId) {
        return mapper.findVisible(userId).stream().map(ScheduleResponse::from).toList();
    }

    @Transactional
    public ScheduleResponse create(UUID userId, ScheduleRequest request) {
        UUID vaultId = resolveVaultId(userId, request.vaultId());
        if (mapper.countInScope(userId, vaultId) >= MAX_SCHEDULES_PER_VAULT) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED",
                "일정은 최대 " + MAX_SCHEDULES_PER_VAULT + "개까지 등록할 수 있습니다.");
        }
        UUID scheduleId = UUID.randomUUID();
        mapper.insert(
            scheduleId, userId, vaultId, request.title().strip(), request.date(),
            request.memoOrEmpty(), request.yearlyOrFalse(), request.emojiOrDefault());
        return ScheduleResponse.from(
            mapper.findById(scheduleId).orElseThrow(this::scheduleNotFound));
    }

    /**
     * 어느 금고에 넣을지 정한다.
     *
     * <p>앱이 고른 금고를 보내면 그 금고의 활성 구성원인지 확인한다 — 남의
     * 금고에 일정을 밀어 넣지 못하게 한다. 보내지 않으면 사용자가 속한 금고가
     * 하나일 때만 그것으로 정한다. 여러 곳에 속해 있으면 어느 가족의 일정인지
     * 서버가 대신 고를 수 없으므로 되묻는다.
     *
     * <p>금고가 하나도 없으면 {@code null}로 두어 예전처럼 개인 일정이 된다.
     */
    private UUID resolveVaultId(UUID userId, UUID requested) {
        if (requested != null) {
            if (!mapper.isActiveMember(userId, requested)) {
                throw new ApiException(
                    HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE", "이 금고의 구성원이 아닙니다.");
            }
            return requested;
        }
        List<UUID> vaults = mapper.findActiveVaultIds(userId);
        if (vaults.isEmpty()) {
            return null;
        }
        if (vaults.size() > 1) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED",
                "여러 금고에 속해 있어 일정을 넣을 금고(vaultId)를 지정해야 합니다.");
        }
        return vaults.get(0);
    }

    @Transactional
    public ScheduleResponse update(UUID userId, UUID scheduleId, ScheduleRequest request) {
        int updated = mapper.update(
            scheduleId, userId, request.title().strip(), request.date(),
            request.memoOrEmpty(), request.yearlyOrFalse(), request.emojiOrDefault());
        if (updated != 1) {
            throw forbiddenOrNotFound(userId, scheduleId);
        }
        return ScheduleResponse.from(
            mapper.findById(scheduleId).orElseThrow(this::scheduleNotFound));
    }

    @Transactional
    public void delete(UUID userId, UUID scheduleId) {
        if (mapper.delete(scheduleId, userId) != 1) {
            throw forbiddenOrNotFound(userId, scheduleId);
        }
    }

    /**
     * 권한이 없어 못 바꾼 것과 없는 일정을 구분한다.
     *
     * <p>남의 일정을 고치려 했을 때 404를 주면 "왜 안 되는지"를 알 수 없다.
     * 목록에서 보이는 일정이라 존재 자체는 이미 알고 있으므로 숨길 것도 없다.
     */
    private ApiException forbiddenOrNotFound(UUID userId, UUID scheduleId) {
        ScheduleRow row = mapper.findById(scheduleId).orElse(null);
        if (row == null) {
            return scheduleNotFound();
        }
        boolean visible = mapper.findVisible(userId).stream()
            .anyMatch(candidate -> candidate.id().equals(scheduleId));
        if (!visible) {
            return scheduleNotFound();
        }
        return new ApiException(
            HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE",
            "일정을 적은 사람이나 OWNER만 고치고 지울 수 있습니다.");
    }

    private ApiException scheduleNotFound() {
        return new ApiException(
            HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "일정을 찾을 수 없습니다.");
    }
}
