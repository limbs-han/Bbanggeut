package com.wj.server.auth.application;

import java.util.UUID;

import com.wj.server.auth.domain.SessionAuthStateRow;
import com.wj.server.auth.persistence.AuthMapper;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2ErrorCodes;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Component;

/**
 * Binds an access token to server-side state on every request. Signature and
 * expiry alone are not enough: a token whose session was revoked (logout,
 * password change, withdrawal) or whose {@code tv} claim is behind
 * {@code users.token_version} must stop working at once rather than at the end
 * of its 15-minute lifetime.
 *
 * <p>Also pins the issuer to {@code wj-server}, so a live-stream token — signed
 * with the same key and carrying the same {@code sub} — cannot be replayed
 * against the user API.
 */
@Component
public class AccessTokenValidator implements OAuth2TokenValidator<Jwt> {
    private static final OAuth2Error INVALID_TOKEN = new OAuth2Error(
        OAuth2ErrorCodes.INVALID_TOKEN,
        "The session backing this access token is no longer valid.",
        null);

    private final AuthMapper authMapper;

    public AccessTokenValidator(AuthMapper authMapper) {
        this.authMapper = authMapper;
    }

    @Override
    public OAuth2TokenValidatorResult validate(Jwt token) {
        if (!JwtTokenService.ISSUER.equals(token.getClaimAsString("iss"))) {
            return failure();
        }
        UUID sessionId = uuid(token.getClaimAsString("sid"));
        UUID userId = uuid(token.getSubject());
        Integer tokenVersion = intClaim(token, "tv");
        if (sessionId == null || userId == null || tokenVersion == null) {
            return failure();
        }
        SessionAuthStateRow state = authMapper.findSessionAuthState(sessionId).orElse(null);
        if (state == null
            || !state.userId().equals(userId)
            || !"ACTIVE".equals(state.status())
            || state.tokenVersion() != tokenVersion) {
            return failure();
        }
        return OAuth2TokenValidatorResult.success();
    }

    private OAuth2TokenValidatorResult failure() {
        return OAuth2TokenValidatorResult.failure(INVALID_TOKEN);
    }

    private UUID uuid(String value) {
        if (value == null) {
            return null;
        }
        try {
            return UUID.fromString(value);
        } catch (IllegalArgumentException exception) {
            return null;
        }
    }

    private Integer intClaim(Jwt token, String name) {
        return token.getClaim(name) instanceof Number number ? number.intValue() : null;
    }
}
