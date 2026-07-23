package com.wj.server.device.persistence;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.device.domain.DeviceViewRow;
import com.wj.server.device.domain.DeviceStatusRow;
import com.wj.server.device.domain.MembershipStateRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface DeviceMapper {

    @Update("""
        UPDATE devices
           SET status = CASE
                 WHEN last_seen_at IS NOT NULL
                  AND last_seen_at > now() - interval '90 seconds'
                 THEN 'ONLINE'::device_status
                 ELSE 'OFFLINE'::device_status
               END,
               claimed_at = now(),
               claimed_by = #{userId},
               registration_mode_expires_at = NULL,
               name = COALESCE(#{name}, name),
               updated_at = now()
         WHERE id = #{deviceId}
           AND status = 'UNCLAIMED'
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
           SET status = 'OFFLINE', recording = false, person_count = NULL, updated_at = now()
         WHERE id = #{deviceId} AND status = 'ONLINE'
           AND (last_seen_at IS NULL OR last_seen_at <= now() - interval '90 seconds')
        """)
    int markOfflineIfStale(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT d.id AS device_id, d.status, d.recording,
               d.upload_queue_depth, d.buffer_seconds, d.person_count
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
           SET status = 'REVOKED', decided_at = now(), updated_at = now()
         WHERE device_id = #{deviceId} AND status = 'PENDING'
        """)
    int cancelPendingInvitations(@Param("deviceId") UUID deviceId);

    @Update("""
        UPDATE videos
           SET status = 'DELETING', delete_requested_at = now(), deleted_by = #{userId}, updated_at = now()
         WHERE device_id = #{deviceId} AND status NOT IN ('DELETING', 'DELETED')
        """)
    int markAllVideosDeleting(@Param("deviceId") UUID deviceId, @Param("userId") UUID userId);

    @Insert("""
        INSERT INTO video_deletion_jobs (video_id)
        SELECT id FROM videos WHERE device_id = #{deviceId} AND status = 'DELETING'
        ON CONFLICT (video_id) DO NOTHING
        """)
    int enqueueDeletionJobsForDevice(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT id, user_id, role::text, status::text
          FROM device_memberships
         WHERE id = #{membershipId} AND device_id = #{deviceId}
         FOR UPDATE
        """)
    Optional<MembershipStateRow> lockMembership(
        @Param("deviceId") UUID deviceId,
        @Param("membershipId") UUID membershipId
    );

    @Update("""
        UPDATE device_memberships
           SET role = 'MEMBER', updated_at = now()
         WHERE device_id = #{deviceId} AND user_id = #{userId}
           AND role = 'OWNER' AND status = 'ACTIVE'
        """)
    int demoteOwnerToMember(@Param("deviceId") UUID deviceId, @Param("userId") UUID userId);

    @Update("""
        UPDATE device_memberships
           SET role = 'OWNER', updated_at = now()
         WHERE id = #{membershipId} AND device_id = #{deviceId}
           AND role = 'MEMBER' AND status = 'ACTIVE'
        """)
    int promoteMemberToOwner(@Param("deviceId") UUID deviceId, @Param("membershipId") UUID membershipId);

    /**
     * Ownership transfer: the revoked row keeps the history while the same
     * physical serial gets a fresh UNCLAIMED row for the next owner.
     */
    @Select("""
        INSERT INTO devices (serial_number, model, firmware_version, status)
        SELECT serial_number, model, firmware_version, 'UNCLAIMED'
          FROM devices
         WHERE id = #{deviceId}
        RETURNING id::text
        """)
    String insertSuccessorDevice(@Param("deviceId") UUID deviceId);
}
