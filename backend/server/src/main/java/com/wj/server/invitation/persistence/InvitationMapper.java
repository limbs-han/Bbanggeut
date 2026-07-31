package com.wj.server.invitation.persistence;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.invitation.domain.InvitationRow;
import com.wj.server.invitation.domain.MembershipRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface InvitationMapper {
    @Select("""
        SELECT vm.role::text
          FROM device_bindings b
          JOIN vault_memberships vm ON vm.vault_id = b.vault_id
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND vm.user_id = #{userId} AND vm.status = 'ACTIVE'
        """)
    Optional<String> findActiveRole(@Param("userId") UUID userId, @Param("deviceId") UUID deviceId);

    @Select("SELECT email FROM users WHERE id = #{userId} AND deleted_at IS NULL")
    Optional<String> findUserEmail(@Param("userId") UUID userId);

    // --- email invitations ---

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM users
             WHERE lower(email) = lower(#{email})
               AND status = 'ACTIVE' AND deleted_at IS NULL
        )
        """)
    boolean activeUserEmailExists(@Param("email") String email);

    @Select("""
        SELECT EXISTS (
            SELECT 1
              FROM device_bindings b
              JOIN vault_memberships m ON m.vault_id = b.vault_id
              JOIN users u ON u.id = m.user_id
             WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
               AND m.status = 'ACTIVE'
               AND lower(u.email) = lower(#{email})
        )
        """)
    boolean activeMemberEmailExists(@Param("deviceId") UUID deviceId, @Param("email") String email);

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM invitations
             WHERE device_id = #{deviceId} AND lower(invitee_email) = lower(#{email})
               AND status = 'PENDING'
        )
        """)
    boolean pendingInvitationExists(@Param("deviceId") UUID deviceId, @Param("email") String email);

    @Insert("""
        INSERT INTO invitations (
            id, device_id, vault_id, inviter_id, invitee_email, role, expires_at
        )
        SELECT #{id}, #{deviceId}, b.vault_id, #{inviterId},
               lower(btrim(#{inviteeEmail})), #{role}::device_role, #{expiresAt}
          FROM device_bindings b
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
        """)
    int insertInvitation(
        @Param("id") UUID id,
        @Param("deviceId") UUID deviceId,
        @Param("inviterId") UUID inviterId,
        @Param("inviteeEmail") String inviteeEmail,
        @Param("role") String role,
        @Param("expiresAt") Instant expiresAt
    );

    @Select("""
        SELECT i.id, i.device_id, d.name AS device_name,
               i.inviter_id, iu.email AS inviter_email, iu.display_name AS inviter_display_name,
               i.invitee_email, i.role::text, i.status::text, i.expires_at, i.created_at,
               i.vault_id, v.name AS vault_name
          FROM invitations i
          LEFT JOIN devices d ON d.id = i.device_id
          JOIN memory_vaults v ON v.id = i.vault_id
          JOIN device_bindings b
            ON b.device_id = #{deviceId}
           AND b.vault_id = i.vault_id
           AND b.status = 'ACTIVE'
          LEFT JOIN users iu ON iu.id = i.inviter_id
         WHERE i.id = #{invitationId}
        """)
    Optional<InvitationRow> findScopedInvitation(
        @Param("deviceId") UUID deviceId,
        @Param("invitationId") UUID invitationId
    );

    @Select("""
        SELECT i.id, i.device_id, d.name AS device_name,
               i.inviter_id, iu.email AS inviter_email, iu.display_name AS inviter_display_name,
               i.invitee_email, i.role::text, i.status::text, i.expires_at, i.created_at,
               i.vault_id, v.name AS vault_name
          FROM invitations i
          LEFT JOIN devices d ON d.id = i.device_id
          JOIN memory_vaults v ON v.id = i.vault_id
          JOIN device_bindings b
            ON b.device_id = #{deviceId}
           AND b.vault_id = i.vault_id
           AND b.status = 'ACTIVE'
          LEFT JOIN users iu ON iu.id = i.inviter_id
         WHERE i.status = 'PENDING'
         ORDER BY i.created_at DESC, i.id
        """)
    List<InvitationRow> findDeviceInvitations(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT i.id, i.device_id, d.name AS device_name,
               i.inviter_id, iu.email AS inviter_email, iu.display_name AS inviter_display_name,
               i.invitee_email, i.role::text, i.status::text, i.expires_at, i.created_at,
               i.vault_id, v.name AS vault_name
          FROM invitations i
          LEFT JOIN devices d ON d.id = i.device_id
          JOIN memory_vaults v ON v.id = i.vault_id
          LEFT JOIN users iu ON iu.id = i.inviter_id
         WHERE lower(i.invitee_email) = lower(#{email}) AND i.status = 'PENDING'
           AND i.expires_at > now() AND v.status <> 'CLOSED'
         ORDER BY i.created_at DESC, i.id
        """)
    List<InvitationRow> findReceivedInvitations(@Param("email") String email);

    @Select("""
        SELECT i.id, i.device_id, d.name AS device_name,
               i.inviter_id, iu.email AS inviter_email, iu.display_name AS inviter_display_name,
               i.invitee_email, i.role::text, i.status::text, i.expires_at, i.created_at,
               i.vault_id, v.name AS vault_name
          FROM invitations i
          LEFT JOIN devices d ON d.id = i.device_id
          JOIN memory_vaults v ON v.id = i.vault_id
          LEFT JOIN users iu ON iu.id = i.inviter_id
         WHERE i.id = #{invitationId}
         FOR UPDATE OF i
        """)
    Optional<InvitationRow> lockInvitation(@Param("invitationId") UUID invitationId);

    @Update("""
        UPDATE invitations
           SET status = 'REVOKED', decided_by = #{ownerId}, decided_at = now(), updated_at = now()
         WHERE id = #{invitationId} AND status = 'PENDING'
           AND vault_id = (
               SELECT vault_id
                 FROM device_bindings
                WHERE device_id = #{deviceId} AND status = 'ACTIVE'
           )
        """)
    int revokeInvitation(
        @Param("deviceId") UUID deviceId,
        @Param("invitationId") UUID invitationId,
        @Param("ownerId") UUID ownerId
    );

    @Update("""
        UPDATE invitations
           SET status = 'ACCEPTED', decided_by = #{userId}, decided_at = now(), updated_at = now()
         WHERE id = #{invitationId} AND status = 'PENDING'
        """)
    int acceptInvitation(@Param("invitationId") UUID invitationId, @Param("userId") UUID userId);

    @Update("""
        UPDATE invitations
           SET status = 'DECLINED', decided_by = #{userId}, decided_at = now(), updated_at = now()
         WHERE id = #{invitationId} AND status = 'PENDING'
        """)
    int declineInvitation(@Param("invitationId") UUID invitationId, @Param("userId") UUID userId);

    // --- memberships ---

    @Insert("""
        INSERT INTO device_memberships (device_id, user_id, role, status, joined_at)
        VALUES (#{deviceId}, #{userId}, #{role}::device_role, 'ACTIVE', now())
        ON CONFLICT (device_id, user_id) DO UPDATE
            SET role = EXCLUDED.role, status = 'ACTIVE', joined_at = now(),
                revoked_at = NULL, revoked_by = NULL, updated_at = now()
        """)
    int activateMember(
        @Param("deviceId") UUID deviceId,
        @Param("userId") UUID userId,
        @Param("role") String role
    );

    @Insert("""
        INSERT INTO vault_memberships (vault_id, user_id, role, status, joined_at)
        SELECT b.vault_id, #{userId}, CAST(#{role} AS device_role), 'ACTIVE', now()
          FROM device_bindings b
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
        ON CONFLICT (vault_id, user_id) DO UPDATE
            SET role = EXCLUDED.role, status = 'ACTIVE', joined_at = now(),
                revoked_at = NULL, revoked_by = NULL, updated_at = now()
        """)
    int activateVaultMember(
        @Param("deviceId") UUID deviceId,
        @Param("userId") UUID userId,
        @Param("role") String role
    );

    @Select("""
        SELECT m.id, m.device_id, m.user_id, u.email, u.display_name,
               m.role::text, m.status::text, m.joined_at,
               NULL::uuid AS vault_id
          FROM device_memberships m
          JOIN users u ON u.id = m.user_id
         WHERE m.device_id = #{deviceId} AND m.user_id = #{userId}
        """)
    Optional<MembershipRow> findMembership(
        @Param("deviceId") UUID deviceId,
        @Param("userId") UUID userId
    );

    @Select("""
        SELECT m.id, m.device_id, m.user_id, u.email, u.display_name,
               m.role::text, m.status::text, m.joined_at,
               NULL::uuid AS vault_id
          FROM device_memberships m
          JOIN users u ON u.id = m.user_id
         WHERE m.device_id = #{deviceId} AND m.status = 'ACTIVE'
         ORDER BY CASE WHEN m.role = 'OWNER' THEN 0 ELSE 1 END, m.joined_at, m.id
        """)
    List<MembershipRow> findActiveMembers(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT m.id, m.device_id, m.user_id, u.email, u.display_name,
               m.role::text, m.status::text, m.joined_at,
               NULL::uuid AS vault_id
          FROM device_memberships m
          JOIN users u ON u.id = m.user_id
         WHERE m.id = #{membershipId} AND m.device_id = #{deviceId}
         FOR UPDATE OF m
        """)
    Optional<MembershipRow> lockScopedMembership(
        @Param("deviceId") UUID deviceId,
        @Param("membershipId") UUID membershipId
    );

    @Update("""
        UPDATE device_memberships
           SET status = 'REVOKED', revoked_at = now(), revoked_by = #{ownerId}, updated_at = now()
         WHERE id = #{membershipId} AND role = 'MEMBER' AND status = 'ACTIVE'
        """)
    int revokeMember(@Param("membershipId") UUID membershipId, @Param("ownerId") UUID ownerId);

    @Update("""
        UPDATE vault_memberships vm
           SET status = 'REVOKED', revoked_at = now(),
               revoked_by = #{ownerId}, updated_at = now()
          FROM device_bindings b
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND vm.vault_id = b.vault_id AND vm.user_id = #{memberUserId}
           AND vm.role = 'MEMBER' AND vm.status = 'ACTIVE'
        """)
    int revokeVaultMember(
        @Param("deviceId") UUID deviceId,
        @Param("memberUserId") UUID memberUserId,
        @Param("ownerId") UUID ownerId
    );

    // --- vault-first API (works even while no device is connected) ---

    @Select("""
        SELECT role::text
          FROM vault_memberships
         WHERE vault_id = #{vaultId} AND user_id = #{userId}
           AND status = 'ACTIVE'
        """)
    Optional<String> findActiveVaultRole(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId
    );

    @Select("""
        SELECT b.device_id
          FROM device_bindings b
         WHERE b.vault_id = #{vaultId} AND b.status = 'ACTIVE'
         ORDER BY b.bound_at, b.id
         LIMIT 1
        """)
    Optional<UUID> findFirstActiveDeviceId(@Param("vaultId") UUID vaultId);

    @Select("""
        SELECT EXISTS (
            SELECT 1
              FROM vault_memberships m
              JOIN users u ON u.id = m.user_id
             WHERE m.vault_id = #{vaultId} AND m.status = 'ACTIVE'
               AND lower(u.email) = lower(#{email})
        )
        """)
    boolean activeVaultMemberEmailExists(
        @Param("vaultId") UUID vaultId,
        @Param("email") String email
    );

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM invitations
             WHERE vault_id = #{vaultId}
               AND lower(invitee_email) = lower(#{email})
               AND status = 'PENDING'
        )
        """)
    boolean pendingVaultInvitationExists(
        @Param("vaultId") UUID vaultId,
        @Param("email") String email
    );

    @Insert("""
        INSERT INTO invitations (
            id, device_id, vault_id, inviter_id, invitee_email, role, expires_at
        )
        VALUES (
            #{id}, #{deviceId}, #{vaultId}, #{inviterId},
            lower(btrim(#{inviteeEmail})), 'MEMBER', #{expiresAt}
        )
        """)
    int insertVaultInvitation(
        @Param("id") UUID id,
        @Param("vaultId") UUID vaultId,
        @Param("deviceId") UUID deviceId,
        @Param("inviterId") UUID inviterId,
        @Param("inviteeEmail") String inviteeEmail,
        @Param("expiresAt") Instant expiresAt
    );

    @Select("""
        SELECT i.id, i.device_id, d.name AS device_name,
               i.inviter_id, iu.email AS inviter_email,
               iu.display_name AS inviter_display_name,
               i.invitee_email, i.role::text, i.status::text,
               i.expires_at, i.created_at, i.vault_id, v.name AS vault_name
          FROM invitations i
          JOIN memory_vaults v ON v.id = i.vault_id
          LEFT JOIN devices d ON d.id = i.device_id
          LEFT JOIN users iu ON iu.id = i.inviter_id
         WHERE i.vault_id = #{vaultId} AND i.id = #{invitationId}
        """)
    Optional<InvitationRow> findScopedVaultInvitation(
        @Param("vaultId") UUID vaultId,
        @Param("invitationId") UUID invitationId
    );

    @Select("""
        SELECT i.id, i.device_id, d.name AS device_name,
               i.inviter_id, iu.email AS inviter_email,
               iu.display_name AS inviter_display_name,
               i.invitee_email, i.role::text, i.status::text,
               i.expires_at, i.created_at, i.vault_id, v.name AS vault_name
          FROM invitations i
          JOIN memory_vaults v ON v.id = i.vault_id
          LEFT JOIN devices d ON d.id = i.device_id
          LEFT JOIN users iu ON iu.id = i.inviter_id
         WHERE i.vault_id = #{vaultId} AND i.status = 'PENDING'
         ORDER BY i.created_at DESC, i.id
        """)
    List<InvitationRow> findVaultInvitations(@Param("vaultId") UUID vaultId);

    @Update("""
        UPDATE invitations
           SET status = 'REVOKED', decided_by = #{ownerId},
               decided_at = now(), updated_at = now()
         WHERE id = #{invitationId} AND vault_id = #{vaultId}
           AND status = 'PENDING'
        """)
    int revokeVaultInvitation(
        @Param("vaultId") UUID vaultId,
        @Param("invitationId") UUID invitationId,
        @Param("ownerId") UUID ownerId
    );

    @Insert("""
        INSERT INTO vault_memberships (
            vault_id, user_id, role, status, joined_at
        )
        VALUES (#{vaultId}, #{userId}, 'MEMBER', 'ACTIVE', now())
        ON CONFLICT (vault_id, user_id) DO UPDATE
            SET role = 'MEMBER', status = 'ACTIVE', joined_at = now(),
                revoked_at = NULL, revoked_by = NULL, updated_at = now()
        """)
    int activateVaultMemberByVault(
        @Param("vaultId") UUID vaultId,
        @Param("userId") UUID userId
    );

    @Insert("""
        INSERT INTO device_memberships (
            device_id, user_id, role, status, joined_at
        )
        SELECT b.device_id, #{userId}, 'MEMBER', 'ACTIVE', now()
          FROM device_bindings b
         WHERE b.vault_id = #{vaultId} AND b.status = 'ACTIVE'
        ON CONFLICT (device_id, user_id) DO UPDATE
            SET role = 'MEMBER', status = 'ACTIVE', joined_at = now(),
                revoked_at = NULL, revoked_by = NULL, updated_at = now()
        """)
    int activateMemberForVaultDevices(
        @Param("vaultId") UUID vaultId,
        @Param("userId") UUID userId
    );

    @Select("""
        SELECT vm.id, NULL::uuid AS device_id, vm.user_id,
               u.email, u.display_name, vm.role::text, vm.status::text,
               vm.joined_at, vm.vault_id
          FROM vault_memberships vm
          JOIN users u ON u.id = vm.user_id
         WHERE vm.vault_id = #{vaultId} AND vm.user_id = #{userId}
        """)
    Optional<MembershipRow> findVaultMembership(
        @Param("vaultId") UUID vaultId,
        @Param("userId") UUID userId
    );

    @Select("""
        SELECT vm.id, NULL::uuid AS device_id, vm.user_id,
               u.email, u.display_name, vm.role::text, vm.status::text,
               vm.joined_at, vm.vault_id
          FROM vault_memberships vm
          JOIN users u ON u.id = vm.user_id
         WHERE vm.vault_id = #{vaultId} AND vm.status = 'ACTIVE'
         ORDER BY CASE WHEN vm.role = 'OWNER' THEN 0 ELSE 1 END,
                  vm.joined_at, vm.id
        """)
    List<MembershipRow> findActiveVaultMembers(@Param("vaultId") UUID vaultId);

    @Select("""
        SELECT vm.id, NULL::uuid AS device_id, vm.user_id,
               u.email, u.display_name, vm.role::text, vm.status::text,
               vm.joined_at, vm.vault_id
          FROM vault_memberships vm
          JOIN users u ON u.id = vm.user_id
         WHERE vm.id = #{membershipId} AND vm.vault_id = #{vaultId}
         FOR UPDATE OF vm
        """)
    Optional<MembershipRow> lockScopedVaultMembership(
        @Param("vaultId") UUID vaultId,
        @Param("membershipId") UUID membershipId
    );

    @Update("""
        UPDATE vault_memberships
           SET status = 'REVOKED', revoked_at = now(),
               revoked_by = #{ownerId}, updated_at = now()
         WHERE id = #{membershipId} AND vault_id = #{vaultId}
           AND role = 'MEMBER' AND status = 'ACTIVE'
        """)
    int revokeVaultMembership(
        @Param("vaultId") UUID vaultId,
        @Param("membershipId") UUID membershipId,
        @Param("ownerId") UUID ownerId
    );

    @Update("""
        UPDATE device_memberships dm
           SET status = 'REVOKED', revoked_at = now(),
               revoked_by = #{ownerId}, updated_at = now()
          FROM device_bindings b
         WHERE b.vault_id = #{vaultId} AND b.status = 'ACTIVE'
           AND dm.device_id = b.device_id AND dm.user_id = #{memberUserId}
           AND dm.role = 'MEMBER' AND dm.status = 'ACTIVE'
        """)
    int revokeMemberFromVaultDevices(
        @Param("vaultId") UUID vaultId,
        @Param("memberUserId") UUID memberUserId,
        @Param("ownerId") UUID ownerId
    );

    @Update("""
        UPDATE vault_memberships
           SET role = 'MEMBER', updated_at = now()
         WHERE vault_id = #{vaultId} AND user_id = #{ownerId}
           AND role = 'OWNER' AND status = 'ACTIVE'
        """)
    int demoteVaultOwner(
        @Param("vaultId") UUID vaultId,
        @Param("ownerId") UUID ownerId
    );

    @Update("""
        UPDATE vault_memberships
           SET role = 'OWNER', updated_at = now()
         WHERE id = #{membershipId} AND vault_id = #{vaultId}
           AND role = 'MEMBER' AND status = 'ACTIVE'
        """)
    int promoteVaultMember(
        @Param("vaultId") UUID vaultId,
        @Param("membershipId") UUID membershipId
    );

    @Update("""
        UPDATE device_memberships dm
           SET role = CASE
               WHEN dm.user_id = #{newOwnerId} THEN 'OWNER'::device_role
               ELSE 'MEMBER'::device_role
           END,
           updated_at = now()
          FROM device_bindings b
         WHERE b.vault_id = #{vaultId} AND b.status = 'ACTIVE'
           AND dm.device_id = b.device_id AND dm.status = 'ACTIVE'
           AND dm.user_id IN (#{oldOwnerId}, #{newOwnerId})
        """)
    int syncVaultOwnerToDevices(
        @Param("vaultId") UUID vaultId,
        @Param("oldOwnerId") UUID oldOwnerId,
        @Param("newOwnerId") UUID newOwnerId
    );
}
