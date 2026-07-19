package com.wj.server.device.persistence;

import java.time.Instant;
import java.util.UUID;

import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface ClaimAttemptMapper {

    @Select("""
        SELECT (
            (SELECT count(*) FROM device_claim_attempts
              WHERE user_id = #{userId} AND succeeded = false AND attempted_at >= #{since}) >= #{maxFailures}
            OR
            (SELECT count(*) FROM device_claim_attempts
              WHERE serial_fingerprint = #{serialFingerprint} AND succeeded = false
                AND attempted_at >= #{since}) >= #{maxFailures}
            OR
            (SELECT count(*) FROM device_claim_attempts
              WHERE ip_hash = #{ipHash} AND succeeded = false AND attempted_at >= #{since}) >= #{maxFailures}
        )
        """)
    boolean isRateLimited(
        @Param("userId") UUID userId,
        @Param("serialFingerprint") String serialFingerprint,
        @Param("ipHash") String ipHash,
        @Param("since") Instant since,
        @Param("maxFailures") int maxFailures
    );

    @Insert("""
        INSERT INTO device_claim_attempts (user_id, serial_fingerprint, ip_hash, succeeded)
        VALUES (#{userId}, #{serialFingerprint}, #{ipHash}, #{succeeded})
        """)
    int insertAttempt(
        @Param("userId") UUID userId,
        @Param("serialFingerprint") String serialFingerprint,
        @Param("ipHash") String ipHash,
        @Param("succeeded") boolean succeeded
    );
}
