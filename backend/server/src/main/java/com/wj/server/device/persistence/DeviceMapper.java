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
        ON CONFLICT (device_id, user_id) DO UPDATE
            SET role = 'OWNER', status = 'ACTIVE', joined_at = now(),
                revoked_at = NULL, revoked_by = NULL, updated_at = now()
        """)
    int insertOwnerMembership(@Param("deviceId") UUID deviceId, @Param("userId") UUID userId);

    @Insert("""
        INSERT INTO device_memberships (device_id, user_id, role, status, joined_at)
        SELECT #{deviceId}, vm.user_id, vm.role, 'ACTIVE', vm.joined_at
          FROM device_bindings b
          JOIN vault_memberships vm ON vm.vault_id = b.vault_id
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND vm.status = 'ACTIVE'
        ON CONFLICT (device_id, user_id) DO UPDATE
            SET role = EXCLUDED.role, status = 'ACTIVE',
                revoked_at = NULL, revoked_by = NULL, updated_at = now()
        """)
    int syncMembershipsFromVault(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT d.id, d.name, d.model, d.status, m.role AS my_role,
               d.retention_days, d.last_seen_at, d.serial_number,
               d.firmware_version, d.claimed_at, d.detection_enabled
          FROM devices d
          JOIN device_bindings b ON b.device_id = d.id AND b.status = 'ACTIVE'
          JOIN vault_memberships m ON m.vault_id = b.vault_id
         WHERE m.user_id = #{userId} AND m.status = 'ACTIVE'
           AND d.status IN ('ONLINE', 'OFFLINE')
         ORDER BY b.bound_at DESC, d.id DESC
        """)
    List<DeviceViewRow> findAccessibleDevices(@Param("userId") UUID userId);

    @Select("""
        SELECT d.id, d.name, d.model, d.status, m.role AS my_role,
               d.retention_days, d.last_seen_at, d.serial_number,
               d.firmware_version, d.claimed_at, d.detection_enabled
          FROM devices d
          JOIN device_bindings b ON b.device_id = d.id AND b.status = 'ACTIVE'
          JOIN vault_memberships m ON m.vault_id = b.vault_id
         WHERE d.id = #{deviceId}
           AND m.user_id = #{userId}
           AND m.status = 'ACTIVE'
           AND d.status IN ('ONLINE', 'OFFLINE')
        """)
    Optional<DeviceViewRow> findAccessibleDevice(
        @Param("userId") UUID userId,
        @Param("deviceId") UUID deviceId
    );

    @Select("""
        SELECT d.id, d.name, d.model, d.status, m.role AS my_role,
               d.retention_days, d.last_seen_at, d.serial_number,
               d.firmware_version, d.claimed_at, d.detection_enabled
          FROM devices d
          JOIN device_bindings b ON b.device_id = d.id AND b.status = 'ACTIVE'
          JOIN vault_memberships m ON m.vault_id = b.vault_id
         WHERE d.id = #{deviceId} AND m.user_id = #{userId}
           AND m.status = 'ACTIVE' AND d.status IN ('ONLINE', 'OFFLINE')
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
               detection_enabled = CASE WHEN #{detectionEnabledPresent}
                   THEN #{detectionEnabled} ELSE detection_enabled END,
               updated_at = now()
         WHERE id = #{deviceId} AND status != 'REVOKED'
        """)
    int updateSettings(
        @Param("deviceId") UUID deviceId,
        @Param("namePresent") boolean namePresent,
        @Param("name") String name,
        @Param("retentionDaysPresent") boolean retentionDaysPresent,
        @Param("retentionDays") Integer retentionDays,
        @Param("detectionEnabledPresent") boolean detectionEnabledPresent,
        @Param("detectionEnabled") Boolean detectionEnabled
    );

    /**
     * 이 기기가 지금 감지를 받는가. 업로드 경로가 부른다.
     *
     * <p>기기 행이 없거나 폐기됐으면 비어 있다 — 부르는 쪽이 그 경우를 이미
     * 다른 오류로 가르므로 여기서 참·거짓으로 뭉개지 않는다.
     */
    @Select("SELECT detection_enabled FROM devices WHERE id = #{deviceId}")
    Optional<Boolean> findDetectionEnabled(@Param("deviceId") UUID deviceId);

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
          JOIN device_bindings b ON b.device_id = d.id AND b.status = 'ACTIVE'
          JOIN vault_memberships m ON m.vault_id = b.vault_id
         WHERE d.id = #{deviceId} AND m.user_id = #{userId}
           AND m.status = 'ACTIVE' AND d.status IN ('ONLINE', 'OFFLINE')
        """)
    Optional<DeviceStatusRow> findAccessibleStatus(
        @Param("userId") UUID userId,
        @Param("deviceId") UUID deviceId
    );

    @Update("""
        UPDATE devices
           SET status = 'UNCLAIMED', claimed_at = NULL, claimed_by = NULL,
               revoked_at = NULL, registration_mode_expires_at = NULL,
               recording = false, person_count = NULL, updated_at = now()
         WHERE id = #{deviceId} AND status IN ('ONLINE', 'OFFLINE')
        """)
    int markUnclaimed(@Param("deviceId") UUID deviceId);

    @Update("""
        UPDATE device_memberships
           SET status = 'REVOKED', revoked_at = now(), revoked_by = #{ownerId}, updated_at = now()
         WHERE device_id = #{deviceId} AND status = 'ACTIVE'
        """)
    int revokeAllMemberships(@Param("deviceId") UUID deviceId, @Param("ownerId") UUID ownerId);

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
    int promoteNonOwnerToOwner(@Param("deviceId") UUID deviceId, @Param("membershipId") UUID membershipId);

}
