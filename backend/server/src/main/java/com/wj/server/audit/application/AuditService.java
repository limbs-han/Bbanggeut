package com.wj.server.audit.application;

import java.util.UUID;

import com.wj.server.audit.domain.AuditEvent;
import com.wj.server.common.web.RequestIdFilter;
import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

@Service
public class AuditService {
    private static final Logger log = LoggerFactory.getLogger(AuditService.class);
    private final AuditWriter writer;

    public AuditService(AuditWriter writer) {
        this.writer = writer;
    }

    public void success(
        UUID deviceId,
        UUID actorUserId,
        String action,
        String targetType,
        UUID targetId
    ) {
        AuditEvent event = event(deviceId, actorUserId, action, targetType, targetId, "SUCCESS", null);
        if (TransactionSynchronizationManager.isActualTransactionActive()
            && TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override
                public void afterCommit() {
                    writeSafely(event);
                }
            });
        } else {
            writeSafely(event);
        }
    }

    public void denied(
        UUID deviceId,
        UUID actorUserId,
        String action,
        String targetType,
        UUID targetId,
        String reasonCode
    ) {
        AuditEvent event = event(
            deviceId, actorUserId, action, targetType, targetId, "DENIED", reasonCode);
        if (TransactionSynchronizationManager.isActualTransactionActive()
            && TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override
                public void afterCompletion(int status) {
                    writeSafely(event);
                }
            });
        } else {
            writeSafely(event);
        }
    }

    public void successForVault(
        UUID vaultId,
        UUID deviceId,
        UUID actorUserId,
        String action,
        String targetType,
        UUID targetId
    ) {
        AuditEvent event = event(
            deviceId, vaultId, actorUserId, action, targetType, targetId,
            "SUCCESS", null);
        if (TransactionSynchronizationManager.isActualTransactionActive()
            && TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(
                new TransactionSynchronization() {
                    @Override
                    public void afterCommit() {
                        writeSafely(event);
                    }
                });
        } else {
            writeSafely(event);
        }
    }

    public void deniedForVault(
        UUID vaultId,
        UUID deviceId,
        UUID actorUserId,
        String action,
        String targetType,
        UUID targetId,
        String reasonCode
    ) {
        AuditEvent event = event(
            deviceId, vaultId, actorUserId, action, targetType, targetId,
            "DENIED", reasonCode);
        if (TransactionSynchronizationManager.isActualTransactionActive()
            && TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(
                new TransactionSynchronization() {
                    @Override
                    public void afterCompletion(int status) {
                        writeSafely(event);
                    }
                });
        } else {
            writeSafely(event);
        }
    }

    private AuditEvent event(
        UUID deviceId,
        UUID actorUserId,
        String action,
        String targetType,
        UUID targetId,
        String outcome,
        String reasonCode
    ) {
        return event(
            deviceId, null, actorUserId, action, targetType, targetId,
            outcome, reasonCode);
    }

    private AuditEvent event(
        UUID deviceId,
        UUID vaultId,
        UUID actorUserId,
        String action,
        String targetType,
        UUID targetId,
        String outcome,
        String reasonCode
    ) {
        HttpServletRequest request = currentRequest();
        String ipAddress = request == null ? null : truncate(request.getRemoteAddr(), 64);
        String userAgent = request == null ? null : truncate(request.getHeader("User-Agent"), 512);
        Object requestIdValue = request == null ? null : request.getAttribute(RequestIdFilter.ATTRIBUTE);
        String requestId = requestIdValue == null ? null : truncate(String.valueOf(requestIdValue), 100);
        return new AuditEvent(
            deviceId, vaultId, actorUserId, null, action, targetType, targetId,
            outcome, reasonCode,
            ipAddress, userAgent, requestId);
    }

    private HttpServletRequest currentRequest() {
        if (RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes attributes) {
            return attributes.getRequest();
        }
        return null;
    }

    private void writeSafely(AuditEvent event) {
        try {
            writer.write(event);
        } catch (RuntimeException exception) {
            log.error(
                "Audit log write failed deviceId={} action={} outcome={} requestId={}",
                event.deviceId(), event.action(), event.outcome(), event.requestId(), exception);
        }
    }

    private String truncate(String value, int maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, maxLength);
    }
}
