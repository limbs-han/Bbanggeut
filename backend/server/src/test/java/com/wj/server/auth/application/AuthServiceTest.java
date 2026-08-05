package com.wj.server.auth.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.auth.api.LoginRequest;
import com.wj.server.auth.api.ChangePasswordRequest;
import com.wj.server.auth.api.ForgotPasswordRequest;
import com.wj.server.auth.api.RefreshTokenRequest;
import com.wj.server.auth.api.ResetPasswordRequest;
import com.wj.server.auth.api.SignUpRequest;
import com.wj.server.auth.api.UpdateProfileRequest;
import com.wj.server.auth.application.AuthService.ClientContext;
import com.wj.server.auth.domain.AuthSessionRow;
import com.wj.server.auth.domain.PasswordResetTokenRow;
import com.wj.server.auth.domain.UserRow;
import com.wj.server.auth.persistence.AuthMapper;
import com.wj.server.common.api.ApiException;
import com.wj.server.common.ratelimit.SlidingWindowRateLimiter;
import com.wj.server.config.AuthProperties;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;

@ExtendWith(MockitoExtension.class)
class AuthServiceTest {
    private static final Instant NOW = Instant.parse("2026-07-17T10:00:00Z");
    private static final ClientContext CLIENT = new ClientContext("android", "test-agent", "127.0.0.1");

    @Mock
    private AuthMapper authMapper;
    @Mock
    private JwtTokenService jwtTokenService;
    @Mock
    private LoginAttemptService loginAttemptService;
    @Mock
    private PasswordResetSender passwordResetSender;

    private PasswordEncoder passwordEncoder;
    private AuthService authService;

    @BeforeEach
    void setUp() {
        passwordEncoder = new BCryptPasswordEncoder(4);
        AuthProperties properties = new AuthProperties(
            Duration.ofMinutes(15), Duration.ofDays(14), "test-signing-key-at-least-thirty-two-bytes",
            5, Duration.ofMinutes(10));
        authService = new AuthService(
            authMapper,
            passwordEncoder,
            jwtTokenService,
            loginAttemptService,
            properties,
            passwordResetSender,
            Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void signUpNormalizesEmailAndStoresOnlyRefreshTokenHash() {
        UUID userId = UUID.randomUUID();
        UserRow user = new UserRow(userId, "user@example.com", "encoded", "사용자", "ACTIVE", 0);
        when(authMapper.insertUser(anyString(), anyString(), anyString())).thenReturn(user);
        when(authMapper.insertSession(any(), any(), anyString(), any(), any(), any(), any())).thenReturn(1);
        when(jwtTokenService.createAccessToken(any(), any())).thenReturn("access-token");

        var response = authService.signUp(
            new SignUpRequest("  USER@Example.COM ", "password-1234", " 사용자 "), CLIENT);

        verify(authMapper).insertUser(
            org.mockito.ArgumentMatchers.eq("user@example.com"), anyString(),
            org.mockito.ArgumentMatchers.eq("사용자"));
        ArgumentCaptor<String> hashCaptor = ArgumentCaptor.forClass(String.class);
        verify(authMapper).insertSession(
            any(), org.mockito.ArgumentMatchers.eq(userId), hashCaptor.capture(),
            any(), any(), any(), org.mockito.ArgumentMatchers.eq(NOW.plus(Duration.ofDays(14))));
        assertThat(hashCaptor.getValue()).matches("[0-9a-f]{64}");
        assertThat(hashCaptor.getValue()).isNotEqualTo(response.refreshToken());
        assertThat(response.accessToken()).isEqualTo("access-token");
        assertThat(response.expiresIn()).isEqualTo(900);
        assertThat(response.user().email()).isEqualTo("user@example.com");
    }

    @Test
    void loginRejectsWrongPasswordWithoutCreatingSession() {
        UserRow user = new UserRow(
            UUID.randomUUID(), "user@example.com", passwordEncoder.encode("correct-password"),
            "사용자", "ACTIVE", 0);
        when(authMapper.findUserByEmail("user@example.com")).thenReturn(Optional.of(user));

        assertThatThrownBy(() -> authService.login(
            new LoginRequest("user@example.com", "wrong-password"), CLIENT))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("INVALID_CREDENTIALS");

        verify(authMapper, never()).insertSession(any(), any(), any(), any(), any(), any(), any());
    }

    @Test
    void loginCompletesTheExactRedisReservationAfterSuccessfulPasswordCheck() {
        UUID userId = UUID.randomUUID();
        UserRow user = new UserRow(
            userId, "user@example.com", passwordEncoder.encode("correct-password"),
            "사용자", "ACTIVE", 0);
        SlidingWindowRateLimiter.Reservation reservation =
            new SlidingWindowRateLimiter.Reservation(
                "rl:login:email:test", "rl:login:ip:test", "member-id");
        when(loginAttemptService.reserveOrReject("user@example.com", CLIENT.ipAddress()))
            .thenReturn(reservation);
        when(authMapper.findUserByEmail("user@example.com")).thenReturn(Optional.of(user));
        when(authMapper.insertSession(any(), any(), anyString(), any(), any(), any(), any())).thenReturn(1);
        when(jwtTokenService.createAccessToken(any(), any())).thenReturn("access-token");

        authService.login(
            new LoginRequest("user@example.com", "correct-password"), CLIENT);

        verify(loginAttemptService).completeSuccess(reservation);
        verify(authMapper).updateLastLogin(userId);
    }

    @Test
    void refreshRotatesSessionAndRejectsReuse() {
        UUID userId = UUID.randomUUID();
        UUID oldSessionId = UUID.randomUUID();
        UserRow user = new UserRow(userId, "user@example.com", "encoded", "사용자", "ACTIVE", 0);
        AuthSessionRow oldSession = new AuthSessionRow(
            oldSessionId, userId, "hash", NOW.plusSeconds(60), null);
        when(authMapper.findActiveSession(anyString()))
            .thenReturn(Optional.of(oldSession))
            .thenReturn(Optional.empty());
        when(authMapper.findUserById(userId)).thenReturn(Optional.of(user));
        when(authMapper.revokeSession(oldSessionId)).thenReturn(1);
        when(authMapper.insertSession(any(), any(), anyString(), any(), any(), any(), any())).thenReturn(1);
        when(jwtTokenService.createAccessToken(any(), any())).thenReturn("new-access-token");

        var first = authService.refresh(new RefreshTokenRequest("a".repeat(32)), CLIENT);
        assertThat(first.accessToken()).isEqualTo("new-access-token");
        verify(authMapper).revokeSession(oldSessionId);

        assertThatThrownBy(() -> authService.refresh(new RefreshTokenRequest("a".repeat(32)), CLIENT))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("INVALID_REFRESH_TOKEN");
    }

    @Test
    void reuseOfRotatedTokenRevokesAllUserSessions() {
        UUID userId = UUID.randomUUID();
        when(authMapper.findActiveSession(anyString())).thenReturn(Optional.empty());
        when(authMapper.findRevokedSessionByHash(anyString())).thenReturn(Optional.of(
            new AuthSessionRow(UUID.randomUUID(), userId, "hash", NOW.plusSeconds(60), NOW)));
        when(authMapper.revokeAllSessionsForUser(userId)).thenReturn(3);

        assertThatThrownBy(() -> authService.refresh(new RefreshTokenRequest("a".repeat(32)), CLIENT))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("INVALID_REFRESH_TOKEN");

        verify(authMapper).revokeAllSessionsForUser(userId);
    }

    @Test
    void unknownRefreshTokenDoesNotRevokeAnything() {
        when(authMapper.findActiveSession(anyString())).thenReturn(Optional.empty());
        when(authMapper.findRevokedSessionByHash(anyString())).thenReturn(Optional.empty());

        assertThatThrownBy(() -> authService.refresh(new RefreshTokenRequest("a".repeat(32)), CLIENT))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("INVALID_REFRESH_TOKEN");

        verify(authMapper, never()).revokeAllSessionsForUser(any());
    }

    @Test
    void updateProfileTrimsDisplayNameAndReturnsUpdatedSummary() {
        UUID userId = UUID.randomUUID();
        UserRow user = new UserRow(userId, "user@example.com", "encoded", "이전 이름", "ACTIVE", 0);
        when(authMapper.findUserById(userId)).thenReturn(Optional.of(user));
        when(authMapper.updateDisplayName(userId, "새 이름")).thenReturn(1);

        var summary = authService.updateProfile(
            userId, new UpdateProfileRequest("  새 이름  "));

        verify(authMapper).updateDisplayName(userId, "새 이름");
        assertThat(summary.displayName()).isEqualTo("새 이름");
        assertThat(summary.email()).isEqualTo("user@example.com");
        assertThat(summary.id()).isEqualTo(userId);
    }

    @Test
    void updateProfileRejectsUnknownUserWithoutWriting() {
        UUID userId = UUID.randomUUID();
        when(authMapper.findUserById(userId)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> authService.updateProfile(
            userId, new UpdateProfileRequest("새 이름")))
            .isInstanceOf(ApiException.class)
            .hasMessageContaining("리소스를 찾을 수 없습니다");
        verify(authMapper, never()).updateDisplayName(any(), anyString());
    }

    @Test
    void withdrawalIsBlockedWhileUserOwnsADevice() {
        UUID userId = UUID.randomUUID();
        when(authMapper.hasActiveOwnerMembership(userId)).thenReturn(true);

        assertThatThrownBy(() -> authService.withdraw(userId))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("OWNER_MEMBERSHIP_EXISTS");
        verify(authMapper, never()).markUserWithdrawn(any());
    }

    @Test
    void withdrawalRevokesMembershipsAndSessions() {
        UUID userId = UUID.randomUUID();
        when(authMapper.hasActiveOwnerMembership(userId)).thenReturn(false);
        when(authMapper.markUserWithdrawn(userId)).thenReturn(1);

        authService.withdraw(userId);

        verify(authMapper).revokeAllMembershipsForUser(userId);
        verify(authMapper).revokeAllSessionsForUser(userId);
    }

    @Test
    void changePasswordVerifiesCurrentPasswordAndRevokesOtherSessions() {
        UUID userId = UUID.randomUUID();
        UUID sessionId = UUID.randomUUID();
        UserRow user = new UserRow(
            userId, "user@example.com", passwordEncoder.encode("current-password"),
            "사용자", "ACTIVE", 0);
        when(authMapper.findUserById(userId)).thenReturn(Optional.of(user));

        authService.changePassword(
            userId, sessionId,
            new ChangePasswordRequest("current-password", "new-password-123"));

        verify(authMapper).updatePassword(
            org.mockito.ArgumentMatchers.eq(userId), anyString());
        verify(authMapper).revokeOtherSessionsForUser(userId, sessionId);
    }

    @Test
    void forgotPasswordStoresOnlyHashAndSendsRawToken() {
        UUID userId = UUID.randomUUID();
        UserRow user = new UserRow(
            userId, "user@example.com", "encoded", "사용자", "ACTIVE", 0);
        when(authMapper.findUserByEmail("user@example.com")).thenReturn(Optional.of(user));

        authService.requestPasswordReset(
            new ForgotPasswordRequest(" USER@example.com "));

        ArgumentCaptor<String> hashCaptor = ArgumentCaptor.forClass(String.class);
        ArgumentCaptor<String> rawTokenCaptor = ArgumentCaptor.forClass(String.class);
        verify(authMapper).insertPasswordResetToken(
            any(), org.mockito.ArgumentMatchers.eq(userId), hashCaptor.capture(),
            org.mockito.ArgumentMatchers.eq(NOW.plus(Duration.ofMinutes(30))));
        verify(passwordResetSender).send(
            org.mockito.ArgumentMatchers.eq("user@example.com"), rawTokenCaptor.capture());
        assertThat(hashCaptor.getValue()).matches("[0-9a-f]{64}");
        assertThat(hashCaptor.getValue()).isNotEqualTo(rawTokenCaptor.getValue());
    }

    @Test
    void forgotPasswordDoesNotRevealUnknownEmail() {
        when(authMapper.findUserByEmail("unknown@example.com")).thenReturn(Optional.empty());

        authService.requestPasswordReset(
            new ForgotPasswordRequest("unknown@example.com"));

        verify(passwordResetSender, never()).send(anyString(), anyString());
        verify(authMapper, never()).insertPasswordResetToken(any(), any(), any(), any());
    }

    @Test
    void resetPasswordConsumesTokenAndRevokesEverySession() {
        UUID tokenId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        String rawToken = "r".repeat(43);
        when(authMapper.lockPasswordResetToken(anyString()))
            .thenReturn(Optional.of(new PasswordResetTokenRow(
                tokenId, userId, NOW.plusSeconds(60), null)));
        when(authMapper.consumePasswordResetToken(tokenId)).thenReturn(1);
        when(authMapper.updatePassword(
            org.mockito.ArgumentMatchers.eq(userId), anyString())).thenReturn(1);

        authService.resetPassword(
            new ResetPasswordRequest(rawToken, "new-password-123"));

        verify(authMapper).consumePasswordResetToken(tokenId);
        verify(authMapper).expirePasswordResetTokens(userId);
        verify(authMapper).revokeAllSessionsForUser(userId);
    }
}
