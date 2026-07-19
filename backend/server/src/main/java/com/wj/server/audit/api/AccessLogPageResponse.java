package com.wj.server.audit.api;

import java.util.List;

public record AccessLogPageResponse(
    List<AccessLogResponse> items,
    String nextCursor,
    boolean hasNext
) {
}
