package com.wj.server.device.persistence;

import java.time.Instant;
import java.util.UUID;

import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * Durable record of rejected device claims, kept for incident analysis.
 * Enforcement moved to the Redis limiter, so nothing here is on the decision
 * path. Successful claims are covered by the audit log instead.
 */
@Mapper
public interface ClaimAttemptMapper {

    @Insert("""
        INSERT INTO device_claim_attempts (user_id, ip_hash, succeeded)
        VALUES (#{userId}, #{ipHash}, false)
        """)
    int insertFailure(
        @Param("userId") UUID userId,
        @Param("ipHash") String ipHash
    );

    @Delete("DELETE FROM device_claim_attempts WHERE attempted_at < #{before}")
    int deleteOlderThan(@Param("before") Instant before);
}
