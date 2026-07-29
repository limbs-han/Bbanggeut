package com.wj.server.auth.application;

import com.wj.server.auth.persistence.LoginAttemptMapper;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Writes the audit row for a rejected sign-in.
 *
 * <p>Separate from {@link LoginAttemptService} so the transaction boundary sits
 * where a failure can still be caught. Handling the error inside the
 * transactional method would not help: the interceptor would go on to commit a
 * transaction already marked for rollback and throw anyway.
 */
@Component
public class LoginAttemptAuditWriter {
    private final LoginAttemptMapper mapper;

    public LoginAttemptAuditWriter(LoginAttemptMapper mapper) {
        this.mapper = mapper;
    }

    /**
     * Runs in its own transaction because the sign-in transaction is rolled
     * back by the error that follows, which would otherwise discard this row
     * and leave the failure unrecorded.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void write(byte[] emailHash, byte[] ipHash) {
        mapper.insertFailure(emailHash, ipHash);
    }
}
