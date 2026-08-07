package com.wj.server.audit.application;

import java.util.List;
import java.util.UUID;

import com.wj.server.audit.api.AccessLogPageResponse;
import com.wj.server.audit.api.AccessLogResponse;
import com.wj.server.audit.domain.AccessLogRow;
import com.wj.server.audit.persistence.AccessLogMapper;
import com.wj.server.common.api.ApiException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class AccessLogQueryService {
    private final AccessLogMapper mapper;
    private final AccessLogCursorCodec cursorCodec;

    public AccessLogQueryService(AccessLogMapper mapper, AccessLogCursorCodec cursorCodec) {
        this.mapper = mapper;
        this.cursorCodec = cursorCodec;
    }

    @Transactional(readOnly = true)
    public AccessLogPageResponse list(UUID userId, UUID deviceId, String cursor, int size) {
        if (size < 1 || size > 100) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", "size는 1 이상 100 이하여야 합니다.");
        }
        String role = mapper.findActiveRole(userId, deviceId).orElseThrow(this::notFound);
        if (!"OWNER".equals(role)) {
            throw new ApiException(HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE", "OWNER 권한이 필요합니다.");
        }
        AccessLogCursorCodec.Cursor decoded = cursorCodec.decode(cursor);
        List<AccessLogRow> rows = mapper.findPage(deviceId, decoded.createdAt(), decoded.id(), size + 1);
        boolean hasNext = rows.size() > size;
        List<AccessLogRow> page = hasNext ? rows.subList(0, size) : rows;
        String nextCursor = hasNext
            ? cursorCodec.encode(page.get(page.size() - 1).createdAt(), page.get(page.size() - 1).id())
            : null;
        return new AccessLogPageResponse(page.stream().map(this::toResponse).toList(), nextCursor, hasNext);
    }

    private AccessLogResponse toResponse(AccessLogRow row) {
        return new AccessLogResponse(
            row.id(), row.deviceId(), row.actorUserId(), row.actorDeviceId(), row.action(),
            row.targetType(), row.targetId(), row.outcome(), row.reasonCode(), row.createdAt());
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }
}
