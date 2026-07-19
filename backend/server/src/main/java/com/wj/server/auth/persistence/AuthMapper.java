package com.wj.server.auth.persistence;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.auth.domain.AuthSessionRow;
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
}
