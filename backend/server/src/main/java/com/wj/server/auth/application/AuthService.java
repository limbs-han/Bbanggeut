package com.wj.server.auth.application;

import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.util.Base64;
import java.util.HexFormat;
import java.util.Locale;
import java.util.UUID;

import com.wj.server.auth.api.AuthTokenResponse;
import com.wj.server.auth.api.ChangePasswordRequest;
import com.wj.server.auth.api.ForgotPasswordRequest;
import com.wj.server.auth.api.LoginRequest;
import com.wj.server.auth.api.RefreshTokenRequest;
import com.wj.server.auth.api.ResetPasswordRequest;
import com.wj.server.auth.api.SignUpRequest;
import com.wj.server.auth.api.UpdateProfileRequest;
import com.wj.server.auth.api.UserSummary;
import com.wj.server.auth.domain.AuthSessionRow;
import com.wj.server.auth.domain.UserRow;
import com.wj.server.auth.persistence.AuthMapper;
import com.wj.server.common.api.ApiException;
import com.wj.server.common.ratelimit.SlidingWindowRateLimiter;
import com.wj.server.config.AuthProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.beans.factory.annotation.Autowired;

@Service
public class AuthService {
    private static final Logger log = LoggerFactory.getLogger(AuthService.class);

    private static final SecureRandom SECURE_RANDOM = new SecureRandom();

    private final AuthMapper authMapper;
    private final PasswordEncoder passwordEncoder;
    private final JwtTokenService jwtTokenService;
    private final LoginAttemptService loginAttemptService;
    private final AuthProperties properties;
    private final PasswordResetSender passwordResetSender;
    private final Clock clock;

    @Autowired
    public AuthService(
        AuthMapper authMapper,
        PasswordEncoder passwordEncoder,
        JwtTokenService jwtTokenService,
        LoginAttemptService loginAttemptService,
        AuthProperties properties,
        PasswordResetSender passwordResetSender
    ) {
        this(authMapper, passwordEncoder, jwtTokenService, loginAttemptService,
            properties, passwordResetSender, Clock.systemUTC());
    }

    AuthService(
        AuthMapper authMapper,
        PasswordEncoder passwordEncoder,
        JwtTokenService jwtTokenService,
        LoginAttemptService loginAttemptService,
        AuthProperties properties,
        PasswordResetSender passwordResetSender,
        Clock clock
    ) {
        this.authMapper = authMapper;
        this.passwordEncoder = passwordEncoder;
        this.jwtTokenService = jwtTokenService;
        this.loginAttemptService = loginAttemptService;
        this.properties = properties;
        this.passwordResetSender = passwordResetSender;
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
        String email = normalizeEmail(request.email());
        // Claimed before the hash comparison below, which is deliberately slow.
        SlidingWindowRateLimiter.Reservation reservation =
            loginAttemptService.reserveOrReject(email, context.ipAddress());
        UserRow user = authMapper.findUserByEmail(email).filter(this::isActive).orElse(null);
        if (user == null || !passwordEncoder.matches(request.password(), user.passwordHash())) {
            loginAttemptService.recordFailure(email, context.ipAddress());
            throw invalidCredentials();
        }
        loginAttemptService.completeSuccess(reservation);
        authMapper.updateLastLogin(user.id());
        return issueTokens(user, context);
    }

    @Transactional
    public AuthTokenResponse refresh(RefreshTokenRequest request, ClientContext context) {
        String tokenHash = hash(request.refreshToken());
        AuthSessionRow oldSession = authMapper.findActiveSession(tokenHash)
            .orElseThrow(() -> reuseSuspectedOrInvalid(tokenHash));
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

    @Transactional
    public void changePassword(UUID userId, UUID sessionId, ChangePasswordRequest request) {
        UserRow user = authMapper.findUserById(userId)
            .filter(this::isActive)
            .orElseThrow(this::invalidCredentials);
        if (!passwordEncoder.matches(request.currentPassword(), user.passwordHash())) {
            throw invalidCredentials();
        }
        if (passwordEncoder.matches(request.newPassword(), user.passwordHash())) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY,
                "PASSWORD_UNCHANGED",
                "새 비밀번호는 현재 비밀번호와 달라야 합니다.");
        }
        authMapper.updatePassword(userId, passwordEncoder.encode(request.newPassword()));
        authMapper.expirePasswordResetTokens(userId);
        authMapper.revokeOtherSessionsForUser(userId, sessionId);
    }

    @Transactional
    public void requestPasswordReset(ForgotPasswordRequest request) {
        String email = normalizeEmail(request.email());
        UserRow user = authMapper.findUserByEmail(email).filter(this::isActive).orElse(null);
        if (user == null) {
            return;
        }
        String rawToken = newRefreshToken();
        authMapper.expirePasswordResetTokens(user.id());
        authMapper.insertPasswordResetToken(
            UUID.randomUUID(), user.id(), hash(rawToken), clock.instant().plusSeconds(30 * 60));
        passwordResetSender.send(user.email(), rawToken);
    }

    @Transactional
    public void resetPassword(ResetPasswordRequest request) {
        var token = authMapper.lockPasswordResetToken(hash(request.token()))
            .orElseThrow(this::invalidPasswordResetToken);
        if (token.usedAt() != null || !token.expiresAt().isAfter(clock.instant())
            || authMapper.consumePasswordResetToken(token.id()) != 1) {
            throw invalidPasswordResetToken();
        }
        if (authMapper.updatePassword(
            token.userId(), passwordEncoder.encode(request.newPassword())) != 1) {
            throw invalidPasswordResetToken();
        }
        authMapper.expirePasswordResetTokens(token.userId());
        authMapper.revokeAllSessionsForUser(token.userId());
    }

    /**
     * Account withdrawal. A user who still owns a device must release or
     * transfer it first — otherwise the device would end up ownerless, which
     * the one-active-OWNER constraint forbids.
     */
    /// 표시 이름을 바꾼다.
    ///
    /// 앱은 프로필 수정 화면에서 `PATCH /api/auth/me`로 이것만 보낸다. 이메일은
    /// 로그인 식별자라 여기서 바꾸지 않는다.
    @Transactional
    public UserSummary updateProfile(UUID userId, UpdateProfileRequest request) {
        // 가입과 같은 규칙으로 다듬는다. DB의 ck_users_display_name도 공백을
        // 다듬은 길이를 보므로, 다듬지 않으면 "  이름  "이 60자 제약에서
        // 엉뚱하게 걸린다.
        String displayName = request.displayName().trim();
        UserRow user = authMapper.findUserById(userId)
            .orElseThrow(() -> new ApiException(
                HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다."));
        if (authMapper.updateDisplayName(userId, displayName) != 1) {
            throw new ApiException(
                HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
        }
        return new UserSummary(user.id(), user.email(), displayName);
    }

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
        authMapper.revokeAllVaultMembershipsForUser(userId);
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

    /**
     * 활성 세션에 없는 refresh 토큰이 "이미 회전된" 토큰이면 탈취 신호로
     * 보고 그 사용자의 모든 세션을 회수한다 — 도둑이 먼저 회전시켰든
     * 정상 사용자가 늦게 도착했든, 같은 토큰을 두 주체가 쥐고 있었다는
     * 뜻이므로 양쪽 다 끊고 재로그인시키는 것이 안전하다. 응답은 탐지
     * 여부를 노출하지 않도록 일반 401 그대로다. 만료만 된 토큰(회전 안 됨)
     * 은 오래 쉰 정상 사용자일 수 있어 회수하지 않는다.
     */
    private ApiException reuseSuspectedOrInvalid(String tokenHash) {
        authMapper.findRevokedSessionByHash(tokenHash).ifPresent(stolen -> {
            int revoked = authMapper.revokeAllSessionsForUser(stolen.userId());
            log.warn(
                "Refresh token reuse detected — revoked all sessions userId={} sessions={}",
                stolen.userId(), revoked);
        });
        return invalidRefreshToken();
    }

    private ApiException invalidPasswordResetToken() {
        return new ApiException(
            HttpStatus.UNAUTHORIZED,
            "INVALID_PASSWORD_RESET_TOKEN",
            "비밀번호 재설정 토큰이 유효하지 않거나 만료되었습니다.");
    }

    public record ClientContext(String clientName, String userAgent, String ipAddress) {
    }
}
