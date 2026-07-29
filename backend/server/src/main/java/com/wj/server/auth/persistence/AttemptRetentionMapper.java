package com.wj.server.auth.persistence;

import java.time.Instant;

import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

/**
 * Partition maintenance for the attempt history tables.
 *
 * <p>The table name is passed as a bound argument to a stored function rather
 * than pasted into the statement, so no caller can steer the DDL these
 * functions execute.
 */
@Mapper
public interface AttemptRetentionMapper {

    @Select("SELECT ensure_attempt_partitions(#{parent}, #{from}, #{to})")
    int ensurePartitions(
        @Param("parent") String parent,
        @Param("from") Instant from,
        @Param("to") Instant to
    );

    @Select("SELECT drop_expired_attempt_partitions(#{parent}, #{cutoff})")
    int dropExpiredPartitions(
        @Param("parent") String parent,
        @Param("cutoff") Instant cutoff
    );

    /**
     * Rows land in the default partition only when their week was never
     * provisioned, so this normally deletes nothing. Dropping a partition
     * cannot reclaim them, which is why they are still swept by age.
     */
    @Delete("DELETE FROM auth_login_attempts_default WHERE attempted_at < #{before}")
    int sweepLoginDefaultPartition(@Param("before") Instant before);

    @Delete("DELETE FROM device_claim_attempts_default WHERE attempted_at < #{before}")
    int sweepClaimDefaultPartition(@Param("before") Instant before);
}
