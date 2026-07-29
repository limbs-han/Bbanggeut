package com.wj.server.audit.application;

import com.wj.server.audit.domain.AuditEvent;
import com.wj.server.audit.persistence.AccessLogMapper;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@Component
public class AuditWriter {
    private final AccessLogMapper mapper;

    public AuditWriter(AccessLogMapper mapper) {
        this.mapper = mapper;
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void write(AuditEvent event) {
        mapper.insert(
            event.deviceId(), event.vaultId(), event.actorUserId(),
            event.actorDeviceId(), event.action(),
            event.targetType(), event.targetId(), event.outcome(), event.reasonCode(),
            event.ipAddress(), event.userAgent(), event.requestId());
    }
}
