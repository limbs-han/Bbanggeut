package com.wj.server.auth.application;

import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.util.Base64;
import java.util.HexFormat;
import java.util.Locale;
import java.util.UUID;

import com.wj.server.auth.api.AuthTokenResponse;
import com.wj.server.auth.api.LoginRequest;
import com.wj.server.auth.api.RefreshTokenRequest;
import com.wj.server.auth.api.SignUpRequest;
import com.wj.server.auth.api.UserSummary;
import com.wj.server.auth.domain.AuthSessionRow;
import com.wj.server.auth.domain.UserRow;
import com.wj.server.auth.persistence.AuthMapper;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.AuthProperties;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.beans.factory.annotation.Autowired;

@Service
public class AuthService {
    private static final SecureRandom SECURE_RANDOM = new SecureRandom();

    private final AuthMapper authMapper;
    private final PasswordEncoder passwordEncoder;
    private final JwtTokenService jwtTokenService;
    private final AuthProperties properties;
    private final Clock clock;

    @Autowired
    public AuthService(
        AuthMapper authMapper,
        PasswordEncoder passwordEncoder,
        JwtTokenService jwtTokenService,
        AuthProperties properties
    ) {
        this(authMapper, passwordEncoder, jwtTokenService, properties, Clock.systemUTC());
    }

    AuthService(
        AuthMapper authMapper,
        PasswordEncoder passwordEncoder,
        JwtTokenService jwtTokenService,
        AuthProperties properties,
        Clock clock
    ) {
        this.authMapper = authMapper;
        this.passwordEncoder = passwordEncoder;
        this.jwtTokenService = jwtTokenService;
        this.properties = properties;
        this.clock = clock;
    }

    @Transactional
    public AuthTokenResponse signUp(SignUpRequest request, ClientContext context) {
        UserRow user;
        try {
            user = authMapper.insertUser(
                normalizeEmail(request.email()),
                passwordEncoder.encode(request.password()),
                request.displayName().trim());
        } catch (DuplicateKeyException exception) {
            throw new ApiException(HttpStatus.CONFLICT, "EMAIL_ALREADY_EXISTS", "이미 가입된 이메일입니다.");
        }
        return issueTokens(user, context);
    }

    @Transactional
    public AuthTokenResponse login(LoginRequest request, ClientContext context) {
        UserRow user = authMapper.findUserByEmail(normalizeEmail(request.email()))
            .filter(this::isActive)
            .filter(found -> passwordEncoder.matches(request.password(), found.passwordHash()))
            .orElseThrow(this::invalidCredentials);
        authMapper.updateLastLogin(user.id());
        return issueTokens(user, context);
    }

    @Transactional
    public AuthTokenResponse refresh(RefreshTokenRequest request, ClientContext context) {
        AuthSessionRow oldSession = authMapper.findActiveSession(hash(request.refreshToken()))
            .orElseThrow(this::invalidRefreshToken);
        UserRow user = authMapper.findUserById(oldSession.userId())
            .filter(this::isActive)
            .orElseThrow(this::invalidRefreshToken);
        if (authMapper.revokeSession(oldSession.id()) != 1) {
            throw invalidRefreshToken();
        }
        return issueTokens(user, context);
    }

    @Transactional
    public void logout(UUID userId, UUID sessionId) {
        authMapper.revokeOwnedSession(sessionId, userId);
    }

    /**
     * Account withdrawal. A user who still owns a device must release or
     * transfer it first — otherwise the device would end up ownerless, which
     * the one-active-OWNER constraint forbids.
     */
    @Transactional
    public void withdraw(UUID userId) {
        if (authMapper.hasActiveOwnerMembership(userId)) {
            throw new ApiException(
                HttpStatus.CONFLICT,
                "OWNER_MEMBERSHIP_EXISTS",
                "소유 중인 기기가 있습니다. 먼저 기기를 해제하거나 소유권을 넘긴 뒤 탈퇴할 수 있습니다.");
        }
        if (authMapper.markUserWithdrawn(userId) != 1) {
            throw new ApiException(
                HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
        }
        authMapper.revokeAllMembershipsForUser(userId);
        authMapper.revokeAllSessionsForUser(userId);
    }

    private AuthTokenResponse issueTokens(UserRow user, ClientContext context) {
        UUID sessionId = UUID.randomUUID();
        String refreshToken = newRefreshToken();
        Instant expiresAt = clock.instant().plus(properties.refreshTokenTtl());
        authMapper.insertSession(
            sessionId,
            user.id(),
            hash(refreshToken),
            truncate(context.clientName(), 120),
            truncate(context.userAgent(), 512),
            context.ipAddress(),
            expiresAt);
        return new AuthTokenResponse(
            jwtTokenService.createAccessToken(user, sessionId),
            refreshToken,
            "Bearer",
            properties.accessTokenTtl().toSeconds(),
            new UserSummary(user.id(), user.email(), user.displayName()));
    }

    private String normalizeEmail(String email) {
        return email.trim().toLowerCase(Locale.ROOT);
    }

    private boolean isActive(UserRow user) {
        return "ACTIVE".equals(user.status());
    }

    private String newRefreshToken() {
        byte[] bytes = new byte[32];
        SECURE_RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private String hash(String value) {
        try {
            byte[] digest = java.security.MessageDigest.getInstance("SHA-256")
                .digest(value.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (java.security.NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    private String truncate(String value, int maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, maxLength);
    }

    private ApiException invalidCredentials() {
        return new ApiException(HttpStatus.UNAUTHORIZED, "INVALID_CREDENTIALS", "이메일 또는 비밀번호가 올바르지 않습니다.");
    }

    private ApiException invalidRefreshToken() {
        return new ApiException(HttpStatus.UNAUTHORIZED, "INVALID_REFRESH_TOKEN", "갱신 토큰이 유효하지 않습니다.");
    }

    public record ClientContext(String clientName, String userAgent, String ipAddress) {
    }
}
