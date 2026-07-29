package com.wj.server.device.persistence;

import java.util.UUID;

import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * Durable record of rejected device claims, kept for incident analysis.
 * Enforcement lives in the Redis limiter and retention is handled by dropping
 * partitions, so neither a lookup nor a delete belongs here.
 */
@Mapper
public interface ClaimAttemptMapper {

    @Insert("""
        INSERT INTO device_claim_attempts (user_id, ip_hash)
        VALUES (#{userId}, #{ipHash})
        """)
    int insertFailure(
        @Param("userId") UUID userId,
        @Param("ipHash") byte[] ipHash
    );
}
