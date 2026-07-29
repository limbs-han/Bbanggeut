package com.wj.server.vault.persistence;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.vault.domain.VaultViewRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface VaultMapper {

    @Insert("""
        INSERT INTO memory_vaults (id, name)
        VALUES (#{vaultId}, #{name})
        """)
    int insertVault(@Param("vaultId") UUID vaultId, @Param("name") String name);

    @Insert("""
        INSERT INTO vault_memberships (vault_id, user_id, role, status)
        VALUES (#{vaultId}, #{userId}, 'OWNER', 'ACTIVE')
        """)
    int insertOwner(@Param("vaultId") UUID vaultId, @Param("userId") UUID userId);

    @Select("""
        SELECT role::text
          FROM vault_memberships
         WHERE vault_id = #{vaultId} AND user_id = #{userId}
           AND status = 'ACTIVE'
        """)
    Optional<String> findActiveRole(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId
    );

    @Select("""
        SELECT v.id, v.name, v.status::text, vm.role::text AS my_role,
               v.retention_days, v.subscription_active,
               v.subscription_grace_until,
               b.id AS binding_id, COALESCE(b.generation, 0) AS binding_generation,
               d.id AS device_id, d.name AS device_name, d.model AS device_model,
               d.status::text AS device_status, d.last_seen_at AS device_last_seen_at
          FROM memory_vaults v
          JOIN vault_memberships vm ON vm.vault_id = v.id
          LEFT JOIN device_bindings b
            ON b.vault_id = v.id AND b.status = 'ACTIVE'
          LEFT JOIN devices d ON d.id = b.device_id
         WHERE vm.user_id = #{userId} AND vm.status = 'ACTIVE'
           AND v.status <> 'CLOSED'
         ORDER BY v.created_at, v.id, b.bound_at, b.id
        """)
    List<VaultViewRow> findAccessibleVaults(@Param("userId") UUID userId);

    @Select("""
        SELECT v.id, v.name, v.status::text, vm.role::text AS my_role,
               v.retention_days, v.subscription_active,
               v.subscription_grace_until,
               b.id AS binding_id, COALESCE(b.generation, 0) AS binding_generation,
               d.id AS device_id, d.name AS device_name, d.model AS device_model,
               d.status::text AS device_status, d.last_seen_at AS device_last_seen_at
          FROM memory_vaults v
          JOIN vault_memberships vm ON vm.vault_id = v.id
          LEFT JOIN device_bindings b
            ON b.vault_id = v.id AND b.status = 'ACTIVE'
          LEFT JOIN devices d ON d.id = b.device_id
         WHERE v.id = #{vaultId} AND vm.user_id = #{userId}
           AND vm.status = 'ACTIVE' AND v.status <> 'CLOSED'
         ORDER BY b.bound_at, b.id
        """)
    List<VaultViewRow> findAccessibleVault(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId
    );

    @Insert("""
        INSERT INTO device_bindings (device_id, vault_id, generation, status)
        SELECT #{deviceId}, #{vaultId},
               COALESCE(MAX(generation), 0) + 1, 'ACTIVE'
          FROM device_bindings
         WHERE device_id = #{deviceId}
        """)
    int insertActiveBinding(
        @Param("deviceId") UUID deviceId,
        @Param("vaultId") UUID vaultId
    );

    @Update("""
        UPDATE device_bindings
           SET status = CAST(#{reason} AS device_binding_status),
               ended_at = now(), ended_by = #{userId}, updated_at = now()
         WHERE device_id = #{deviceId} AND status = 'ACTIVE'
        """)
    int endActiveBinding(
        @Param("deviceId") UUID deviceId,
        @Param("userId") UUID userId,
        @Param("reason") String reason
    );

    @Update("""
        UPDATE memory_vaults v
           SET retention_days = CASE
                   WHEN #{retentionDaysPresent} THEN #{retentionDays}
                   ELSE v.retention_days
               END,
               updated_at = now()
          FROM device_bindings b
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND v.id = b.vault_id
        """)
    int updateRetentionForDevice(
        @Param("deviceId") UUID deviceId,
        @Param("retentionDaysPresent") boolean retentionDaysPresent,
        @Param("retentionDays") Integer retentionDays
    );

    @Select("""
        SELECT vault_id
          FROM device_bindings
         WHERE device_id = #{deviceId} AND status = 'ACTIVE'
         FOR UPDATE
        """)
    Optional<UUID> lockActiveVaultId(@Param("deviceId") UUID deviceId);

    @Insert("""
        INSERT INTO vault_memberships (vault_id, user_id, role, status)
        SELECT b.vault_id, #{userId}, CAST(#{role} AS device_role), 'ACTIVE'
          FROM device_bindings b
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
        ON CONFLICT (vault_id, user_id) DO UPDATE
            SET role = EXCLUDED.role, status = 'ACTIVE', joined_at = now(),
                revoked_at = NULL, revoked_by = NULL, updated_at = now()
        """)
    int activateMemberForDevice(
        @Param("deviceId") UUID deviceId,
        @Param("userId") UUID userId,
        @Param("role") String role
    );

    @Update("""
        UPDATE vault_memberships vm
           SET status = 'REVOKED', revoked_at = now(),
               revoked_by = #{ownerId}, updated_at = now()
          FROM device_bindings b
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND vm.vault_id = b.vault_id AND vm.user_id = #{memberUserId}
           AND vm.role = 'MEMBER' AND vm.status = 'ACTIVE'
        """)
    int revokeMemberForDevice(
        @Param("deviceId") UUID deviceId,
        @Param("memberUserId") UUID memberUserId,
        @Param("ownerId") UUID ownerId
    );

    @Update("""
        UPDATE vault_memberships vm
           SET role = 'MEMBER', updated_at = now()
          FROM device_bindings b
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND vm.vault_id = b.vault_id AND vm.user_id = #{userId}
           AND vm.role = 'OWNER' AND vm.status = 'ACTIVE'
        """)
    int demoteOwnerForDevice(
        @Param("deviceId") UUID deviceId,
        @Param("userId") UUID userId
    );

    @Update("""
        UPDATE vault_memberships vm
           SET role = 'OWNER', updated_at = now()
          FROM device_bindings b, device_memberships dm
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND dm.device_id = b.device_id AND dm.user_id = vm.user_id
           AND dm.id = #{membershipId}
           AND vm.vault_id = b.vault_id AND vm.role = 'MEMBER'
           AND vm.status = 'ACTIVE'
        """)
    int promoteMemberForDevice(
        @Param("deviceId") UUID deviceId,
        @Param("membershipId") UUID membershipId
    );
}
