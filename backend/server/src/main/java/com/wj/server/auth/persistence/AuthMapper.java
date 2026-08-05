package com.wj.server.auth.persistence;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.auth.domain.AuthSessionRow;
import com.wj.server.auth.domain.PasswordResetTokenRow;
import com.wj.server.auth.domain.SessionAuthStateRow;
import com.wj.server.auth.domain.UserRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface AuthMapper {

    @Select("""
        INSERT INTO users (email, password_hash, display_name)
        VALUES (#{email}, #{passwordHash}, #{displayName})
        RETURNING id, email, password_hash, display_name, status, token_version
        """)
    UserRow insertUser(
        @Param("email") String email,
        @Param("passwordHash") String passwordHash,
        @Param("displayName") String displayName
    );

    @Select("""
        SELECT id, email, password_hash, display_name, status, token_version
          FROM users
         WHERE email = #{email}
           AND deleted_at IS NULL
        """)
    Optional<UserRow> findUserByEmail(@Param("email") String email);

    @Select("""
        SELECT id, email, password_hash, display_name, status, token_version
          FROM users
         WHERE id = #{id}
           AND deleted_at IS NULL
        """)
    Optional<UserRow> findUserById(@Param("id") UUID id);

    @Update("UPDATE users SET last_login_at = now(), updated_at = now() WHERE id = #{id}")
    int updateLastLogin(@Param("id") UUID id);

    @Update("""
        UPDATE users
           SET display_name = #{displayName},
               updated_at = now()
         WHERE id = #{id}
           AND deleted_at IS NULL
        """)
    int updateDisplayName(@Param("id") UUID id, @Param("displayName") String displayName);

    @Insert("""
        INSERT INTO auth_sessions (
            id, user_id, refresh_token_hash, client_name, user_agent, ip_address, expires_at
        ) VALUES (
            #{id}, #{userId}, #{refreshTokenHash}, #{clientName}, #{userAgent},
            CAST(#{ipAddress} AS inet), #{expiresAt}
        )
        """)
    int insertSession(
        @Param("id") UUID id,
        @Param("userId") UUID userId,
        @Param("refreshTokenHash") String refreshTokenHash,
        @Param("clientName") String clientName,
        @Param("userAgent") String userAgent,
        @Param("ipAddress") String ipAddress,
        @Param("expiresAt") Instant expiresAt
    );

    @Select("""
        SELECT id, user_id, refresh_token_hash, expires_at, revoked_at
          FROM auth_sessions
         WHERE refresh_token_hash = #{refreshTokenHash}
           AND revoked_at IS NULL
           AND expires_at > now()
        """)
    Optional<AuthSessionRow> findActiveSession(@Param("refreshTokenHash") String refreshTokenHash);

    /**
     * 이미 회전(폐기)된 refresh 토큰이 다시 제시됐는지 판별한다. 회전된
     * 토큰의 재사용은 탈취의 명백한 신호다 — 만료만 된 토큰(revoked_at
     * IS NULL)은 오래 쉰 정상 사용자일 수 있으므로 여기에 걸리지 않는다.
     */
    @Select("""
        SELECT id, user_id, refresh_token_hash, expires_at, revoked_at
          FROM auth_sessions
         WHERE refresh_token_hash = #{refreshTokenHash}
           AND revoked_at IS NOT NULL
         LIMIT 1
        """)
    Optional<AuthSessionRow> findRevokedSessionByHash(
        @Param("refreshTokenHash") String refreshTokenHash);

    /**
     * Looked up on every authenticated request so that a revoked session or a
     * bumped token version invalidates an access token immediately, instead of
     * only when it expires.
     */
    @Select("""
        SELECT s.user_id, u.token_version, u.status
          FROM auth_sessions s
          JOIN users u ON u.id = s.user_id
         WHERE s.id = #{sessionId}
           AND s.revoked_at IS NULL
           AND s.expires_at > now()
           AND u.deleted_at IS NULL
        """)
    Optional<SessionAuthStateRow> findSessionAuthState(@Param("sessionId") UUID sessionId);

    @Update("""
        UPDATE auth_sessions
           SET revoked_at = now(), last_used_at = now()
         WHERE id = #{id}
           AND revoked_at IS NULL
        """)
    int revokeSession(@Param("id") UUID id);

    @Update("""
        UPDATE auth_sessions
           SET revoked_at = now()
         WHERE id = #{id}
           AND user_id = #{userId}
           AND revoked_at IS NULL
        """)
    int revokeOwnedSession(@Param("id") UUID id, @Param("userId") UUID userId);

    // --- account withdrawal ---

    @Select("""
        SELECT EXISTS (
            SELECT 1
              FROM vault_memberships
             WHERE user_id = #{userId} AND role = 'OWNER' AND status = 'ACTIVE'
        )
        """)
    boolean hasActiveOwnerMembership(@Param("userId") UUID userId);

    @Update("""
        UPDATE device_memberships
           SET status = 'REVOKED', revoked_at = now(), revoked_by = #{userId}, updated_at = now()
         WHERE user_id = #{userId} AND status = 'ACTIVE'
        """)
    int revokeAllMembershipsForUser(@Param("userId") UUID userId);

    @Update("""
        UPDATE vault_memberships
           SET status = 'REVOKED', revoked_at = now(),
               revoked_by = #{userId}, updated_at = now()
         WHERE user_id = #{userId} AND status = 'ACTIVE'
        """)
    int revokeAllVaultMembershipsForUser(@Param("userId") UUID userId);

    @Update("""
        UPDATE auth_sessions
           SET revoked_at = now()
         WHERE user_id = #{userId} AND revoked_at IS NULL
        """)
    int revokeAllSessionsForUser(@Param("userId") UUID userId);

    @Update("""
        UPDATE auth_sessions
           SET revoked_at = now()
         WHERE user_id = #{userId} AND id != #{sessionId} AND revoked_at IS NULL
        """)
    int revokeOtherSessionsForUser(
        @Param("userId") UUID userId,
        @Param("sessionId") UUID sessionId
    );

    @Update("""
        UPDATE users
           SET password_hash = #{passwordHash}, token_version = token_version + 1,
               updated_at = now()
         WHERE id = #{userId} AND status = 'ACTIVE' AND deleted_at IS NULL
        """)
    int updatePassword(
        @Param("userId") UUID userId,
        @Param("passwordHash") String passwordHash
    );

    @Update("""
        UPDATE password_reset_tokens
           SET used_at = now()
         WHERE user_id = #{userId} AND used_at IS NULL
        """)
    int expirePasswordResetTokens(@Param("userId") UUID userId);

    @Insert("""
        INSERT INTO password_reset_tokens (id, user_id, token_hash, expires_at)
        VALUES (#{id}, #{userId}, #{tokenHash}, #{expiresAt})
        """)
    int insertPasswordResetToken(
        @Param("id") UUID id,
        @Param("userId") UUID userId,
        @Param("tokenHash") String tokenHash,
        @Param("expiresAt") Instant expiresAt
    );

    @Select("""
        SELECT id, user_id, expires_at, used_at
          FROM password_reset_tokens
         WHERE token_hash = #{tokenHash}
         FOR UPDATE
        """)
    Optional<PasswordResetTokenRow> lockPasswordResetToken(
        @Param("tokenHash") String tokenHash
    );

    @Update("""
        UPDATE password_reset_tokens SET used_at = now()
         WHERE id = #{id} AND used_at IS NULL
        """)
    int consumePasswordResetToken(@Param("id") UUID id);

    @Update("""
        UPDATE users
           SET status = 'WITHDRAWN', deleted_at = now(),
               token_version = token_version + 1, updated_at = now()
         WHERE id = #{userId} AND deleted_at IS NULL
        """)
    int markUserWithdrawn(@Param("userId") UUID userId);
}
