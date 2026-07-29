package com.wj.server.device.application;

import java.util.UUID;

import com.wj.server.device.persistence.ClaimAttemptMapper;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Writes the audit row for a rejected device claim. Kept apart from
 * {@link ClaimAttemptService} so the transaction boundary sits where a write
 * failure can still be caught rather than inside a transaction that is already
 * doomed to roll back.
 */
@Component
public class ClaimAttemptAuditWriter {
    private final ClaimAttemptMapper mapper;

    public ClaimAttemptAuditWriter(ClaimAttemptMapper mapper) {
        this.mapper = mapper;
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void write(UUID userId, byte[] ipHash) {
        mapper.insertFailure(userId, ipHash);
    }
}
