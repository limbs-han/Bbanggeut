package com.wj.server.auth.persistence;

import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * Durable record of rejected sign-ins, kept for incident analysis.
 *
 * <p>Enforcement lives in the Redis limiter, so nothing here is on the sign-in
 * decision path. Retention is handled by dropping partitions rather than
 * deleting rows, which is why no delete statement remains.
 */
@Mapper
public interface LoginAttemptMapper {

    @Insert("""
        INSERT INTO auth_login_attempts (email_hash, ip_hash)
        VALUES (#{emailHash}, #{ipHash})
        """)
    int insertFailure(
        @Param("emailHash") byte[] emailHash,
        @Param("ipHash") byte[] ipHash
    );
}
