package com.wj.server.auth.persistence;

import java.time.Instant;

import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * Durable record of rejected sign-ins, kept for incident analysis.
 *
 * <p>Enforcement moved to the Redis limiter, so nothing here is on the sign-in
 * decision path any more. Successful sign-ins are no longer written: no query
 * read those rows, and {@code users.last_login} already records them.
 */
@Mapper
public interface LoginAttemptMapper {

    @Insert("""
        INSERT INTO auth_login_attempts (email_hash, ip_hash, succeeded)
        VALUES (#{emailHash}, #{ipHash}, false)
        """)
    int insertFailure(
        @Param("emailHash") String emailHash,
        @Param("ipHash") String ipHash
    );

    @Delete("DELETE FROM auth_login_attempts WHERE attempted_at < #{before}")
    int deleteOlderThan(@Param("before") Instant before);
}
