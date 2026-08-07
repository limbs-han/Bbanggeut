package com.wj.server.device.application;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.device.api.RegistrationCodeResponse;
import com.wj.server.device.persistence.RegistrationCodeMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class RegistrationCodeService {
    static final Duration CODE_TTL = Duration.ofSeconds(120);
    private static final int MAX_GENERATION_ATTEMPTS = 5;

    private final RegistrationCodeMapper registrationCodeMapper;
    private final RegistrationCodeGenerator generator;
    private final RegistrationCodeHasher hasher;
    private final Clock clock;

    @Autowired
    public RegistrationCodeService(
        RegistrationCodeMapper registrationCodeMapper,
        RegistrationCodeGenerator generator,
        RegistrationCodeHasher hasher
    ) {
        this(registrationCodeMapper, generator, hasher, Clock.systemUTC());
    }

    RegistrationCodeService(
        RegistrationCodeMapper registrationCodeMapper,
        RegistrationCodeGenerator generator,
        RegistrationCodeHasher hasher,
        Clock clock
    ) {
        this.registrationCodeMapper = registrationCodeMapper;
        this.generator = generator;
        this.hasher = hasher;
        this.clock = clock;
    }

    /**
     * Issues a fresh one-time code when the device enters registration mode.
     * The plaintext exists only in the returned response; the database keeps the hash.
     */
    @Transactional
    public RegistrationCodeResponse issue(UUID deviceId) {
        Instant expiresAt = clock.instant().plus(CODE_TTL);
        if (registrationCodeMapper.refreshRegistrationMode(deviceId, expiresAt) != 1) {
            throw new ApiException(
                HttpStatus.CONFLICT,
                "DEVICE_ALREADY_CLAIMED",
                "이미 등록된 기기입니다. 등록 코드를 발급할 수 없습니다.");
        }
        registrationCodeMapper.deleteUnusedCodes(deviceId);
        for (int attempt = 0; attempt < MAX_GENERATION_ATTEMPTS; attempt++) {
            String code = generator.generate();
            String codeHash = hasher.hash(code);
            // Pre-check instead of catching the unique violation: a violation
            // would abort the whole PostgreSQL transaction.
            if (registrationCodeMapper.hashExists(codeHash)) {
                continue;
            }
            registrationCodeMapper.insertCode(deviceId, codeHash, expiresAt);
            return new RegistrationCodeResponse(generator.display(code), expiresAt);
        }
        throw new IllegalStateException("Could not generate a unique registration code");
    }
}
