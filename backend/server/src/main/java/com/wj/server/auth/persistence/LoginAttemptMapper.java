package com.wj.server.auth.persistence;

import java.time.Instant;

import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface LoginAttemptMapper {

    @Select("""
        SELECT (
            (SELECT count(*) FROM auth_login_attempts
              WHERE email_hash = #{emailHash} AND succeeded = false AND attempted_at >= #{since}) >= #{maxFailures}
            OR
            (SELECT count(*) FROM auth_login_attempts
              WHERE ip_hash = #{ipHash} AND succeeded = false AND attempted_at >= #{since}) >= #{maxFailures}
        )
        """)
    boolean isRateLimited(
        @Param("emailHash") String emailHash,
        @Param("ipHash") String ipHash,
        @Param("since") Instant since,
        @Param("maxFailures") int maxFailures
    );

    @Insert("""
        INSERT INTO auth_login_attempts (email_hash, ip_hash, succeeded)
        VALUES (#{emailHash}, #{ipHash}, #{succeeded})
        """)
    int insertAttempt(
        @Param("emailHash") String emailHash,
        @Param("ipHash") String ipHash,
        @Param("succeeded") boolean succeeded
    );

    @Delete("DELETE FROM auth_login_attempts WHERE attempted_at < #{before}")
    int deleteOlderThan(@Param("before") Instant before);
}
