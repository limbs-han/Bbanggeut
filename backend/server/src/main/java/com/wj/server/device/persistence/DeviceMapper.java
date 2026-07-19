package com.wj.server.device.persistence;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.device.domain.DeviceRow;
import com.wj.server.device.domain.DeviceViewRow;
import com.wj.server.device.domain.DeviceStatusRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface DeviceMapper {

    @Select("""
        SELECT id, serial_number, product_code_hash, name, model, firmware_version,
               status, retention_days, registration_mode_expires_at,
               product_code_retired_at, claimed_at, claimed_by, last_seen_at
          FROM devices
         WHERE serial_number = #{serialNumber}
         FOR UPDATE
        """)
    Optional<DeviceRow> findClaimCandidateForUpdate(@Param("serialNumber") String serialNumber);

    @Update("""
        UPDATE devices
           SET status = 'OFFLINE',
               claimed_at = now(),
               claimed_by = #{userId},
               product_code_retired_at = now(),
               registration_mode_expires_at = NULL,
               name = COALESCE(#{name}, name),
               updated_at = now()
         WHERE id = #{deviceId}
           AND status = 'UNCLAIMED'
           AND product_code_retired_at IS NULL
        """)
    int markClaimed(
        @Param("deviceId") UUID deviceId,
        @Param("userId") UUID userId,
        @Param("name") String name
    );

    @Insert("""
        INSERT INTO device_memberships (device_id, user_id, role, status)
        VALUES (#{deviceId}, #{userId}, 'OWNER', 'ACTIVE')
        """)
    int insertOwnerMembership(@Param("deviceId") UUID deviceId, @Param("userId") UUID userId);

    @Select("""
        SELECT d.id, d.name, d.model, d.status, m.role AS my_role,
               d.retention_days, d.last_seen_at, d.serial_number,
               d.firmware_version, d.claimed_at
          FROM devices d
          JOIN device_memberships m ON m.device_id = d.id
         WHERE m.user_id = #{userId}
           AND m.status = 'ACTIVE'
           AND d.status <> 'REVOKED'
         ORDER BY m.joined_at DESC, d.id DESC
        """)
    List<DeviceViewRow> findAccessibleDevices(@Param("userId") UUID userId);

    @Select("""
        SELECT d.id, d.name, d.model, d.status, m.role AS my_role,
               d.retention_days, d.last_seen_at, d.serial_number,
               d.firmware_version, d.claimed_at
          FROM devices d
          JOIN device_memberships m ON m.device_id = d.id
         WHERE d.id = #{deviceId}
           AND m.user_id = #{userId}
           AND m.status = 'ACTIVE'
           AND d.status <> 'REVOKED'
        """)
    Optional<DeviceViewRow> findAccessibleDevice(
        @Param("userId") UUID userId,
        @Param("deviceId") UUID deviceId
    );

    @Select("""
        SELECT d.id, d.name, d.model, d.status, m.role AS my_role,
               d.retention_days, d.last_seen_at, d.serial_number,
               d.firmware_version, d.claimed_at
          FROM devices d
          JOIN device_memberships m ON m.device_id = d.id
         WHERE d.id = #{deviceId} AND m.user_id = #{userId}
           AND m.status = 'ACTIVE' AND d.status != 'REVOKED'
         FOR UPDATE OF d
        """)
    Optional<DeviceViewRow> lockAccessibleDevice(
        @Param("userId") UUID userId,
        @Param("deviceId") UUID deviceId
    );

    @Update("""
        UPDATE devices
           SET name = CASE WHEN #{namePresent} THEN #{name} ELSE name END,
               retention_days = CASE WHEN #{retentionDaysPresent} THEN #{retentionDays} ELSE retention_days END,
               updated_at = now()
         WHERE id = #{deviceId} AND status != 'REVOKED'
        """)
    int updateSettings(
        @Param("deviceId") UUID deviceId,
        @Param("namePresent") boolean namePresent,
        @Param("name") String name,
        @Param("retentionDaysPresent") boolean retentionDaysPresent,
        @Param("retentionDays") Integer retentionDays
    );

    @Update("""
        UPDATE devices
           SET status = 'OFFLINE', recording = false, updated_at = now()
         WHERE id = #{deviceId} AND status = 'ONLINE'
           AND (last_seen_at IS NULL OR last_seen_at <= now() - interval '90 seconds')
        """)
    int markOfflineIfStale(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT d.id AS device_id, d.status, d.recording,
               d.upload_queue_depth, d.buffer_seconds
          FROM devices d
          JOIN device_memberships m ON m.device_id = d.id
         WHERE d.id = #{deviceId} AND m.user_id = #{userId}
           AND m.status = 'ACTIVE' AND d.status != 'REVOKED'
        """)
    Optional<DeviceStatusRow> findAccessibleStatus(
        @Param("userId") UUID userId,
        @Param("deviceId") UUID deviceId
    );

    @Update("""
        UPDATE devices
           SET status = 'REVOKED', revoked_at = now(), recording = false, updated_at = now()
         WHERE id = #{deviceId} AND status IN ('ONLINE', 'OFFLINE')
        """)
    int markRevoked(@Param("deviceId") UUID deviceId);

    @Update("""
        UPDATE device_memberships
           SET status = 'REVOKED', revoked_at = now(), revoked_by = #{ownerId}, updated_at = now()
         WHERE device_id = #{deviceId} AND status = 'ACTIVE'
        """)
    int revokeAllMemberships(@Param("deviceId") UUID deviceId, @Param("ownerId") UUID ownerId);

    @Update("""
        UPDATE device_credentials
           SET status = 'REVOKED', revoked_at = now()
         WHERE device_id = #{deviceId} AND status = 'ACTIVE'
        """)
    int revokeActiveCredentials(@Param("deviceId") UUID deviceId);

    @Update("""
        UPDATE invitations
           SET status = 'REVOKED', revoked_at = now(), updated_at = now()
         WHERE device_id = #{deviceId} AND status = 'PENDING'
        """)
    int revokePendingInvitations(@Param("deviceId") UUID deviceId);
}
