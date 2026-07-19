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
        SELECT m.role::text
          FROM device_memberships m
          JOIN devices d ON d.id = m.device_id
         WHERE m.device_id = #{deviceId} AND m.user_id = #{userId}
           AND m.status = 'ACTIVE' AND d.status != 'REVOKED'
        """)
    Optional<String> findActiveRole(@Param("userId") UUID userId, @Param("deviceId") UUID deviceId);

    @Update("""
        UPDATE invitations
           SET status = 'EXPIRED', updated_at = now()
         WHERE device_id = #{deviceId} AND status = 'PENDING' AND expires_at <= now()
        """)
    int expirePendingForDevice(@Param("deviceId") UUID deviceId);

    @Update("""
        UPDATE invitations
           SET status = 'EXPIRED', updated_at = now()
         WHERE device_id = #{deviceId} AND invitee_email = #{email}
           AND status = 'PENDING' AND expires_at <= now()
        """)
    int expirePendingForEmail(@Param("deviceId") UUID deviceId, @Param("email") String email);

    @Select("""
        SELECT i.id, i.device_id, i.inviter_id, i.invitee_email, i.role::text, i.status::text,
               i.expires_at, i.created_at, d.status::text AS device_status
          FROM invitations i
          JOIN devices d ON d.id = i.device_id
         WHERE i.device_id = #{deviceId}
         ORDER BY i.created_at DESC, i.id DESC
        """)
    List<InvitationRow> findByDevice(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT EXISTS (
            SELECT 1
              FROM device_memberships m
              JOIN users u ON u.id = m.user_id
             WHERE m.device_id = #{deviceId} AND u.email = #{email} AND m.status = 'ACTIVE'
        )
        """)
    boolean activeMembershipExistsByEmail(@Param("deviceId") UUID deviceId, @Param("email") String email);

    @Insert("""
        INSERT INTO invitations
            (id, device_id, inviter_id, invitee_email, role, token_hash, status, expires_at)
        VALUES
            (#{id}, #{deviceId}, #{inviterId}, #{email}, 'MEMBER', #{tokenHash}, 'PENDING', #{expiresAt})
        """)
    int insert(
        @Param("id") UUID id,
        @Param("deviceId") UUID deviceId,
        @Param("inviterId") UUID inviterId,
        @Param("email") String email,
        @Param("tokenHash") String tokenHash,
        @Param("expiresAt") Instant expiresAt
    );

    @Select("""
        SELECT i.id, i.device_id, i.inviter_id, i.invitee_email, i.role::text, i.status::text,
               i.expires_at, i.created_at, d.status::text AS device_status
          FROM invitations i
          JOIN devices d ON d.id = i.device_id
         WHERE i.id = #{invitationId} AND i.device_id = #{deviceId}
         FOR UPDATE OF i
        """)
    Optional<InvitationRow> lockScoped(
        @Param("deviceId") UUID deviceId,
        @Param("invitationId") UUID invitationId
    );

    @Select("""
        SELECT i.id, i.device_id, i.inviter_id, i.invitee_email, i.role::text, i.status::text,
               i.expires_at, i.created_at, d.status::text AS device_status
          FROM invitations i
          JOIN devices d ON d.id = i.device_id
         WHERE i.token_hash = #{tokenHash}
         FOR UPDATE OF i
        """)
    Optional<InvitationRow> lockByTokenHash(@Param("tokenHash") String tokenHash);

    @Update("""
        UPDATE invitations SET status = 'EXPIRED', updated_at = now()
         WHERE id = #{id} AND status = 'PENDING'
        """)
    int markExpired(@Param("id") UUID id);

    @Update("""
        UPDATE invitations SET status = 'REVOKED', revoked_at = now(), updated_at = now()
         WHERE id = #{id} AND status = 'PENDING' AND expires_at > now()
        """)
    int revokeInvitation(@Param("id") UUID id);

    @Insert("""
        INSERT INTO device_memberships (device_id, user_id, role, status, joined_at)
        VALUES (#{deviceId}, #{userId}, 'MEMBER', 'ACTIVE', now())
        ON CONFLICT (device_id, user_id) DO UPDATE
            SET role = 'MEMBER', status = 'ACTIVE', joined_at = now(),
                revoked_at = NULL, revoked_by = NULL, updated_at = now()
        """)
    int activateMember(@Param("deviceId") UUID deviceId, @Param("userId") UUID userId);

    @Update("""
        UPDATE invitations
           SET status = 'ACCEPTED', accepted_by = #{userId}, accepted_at = now(), updated_at = now()
         WHERE id = #{id} AND status = 'PENDING' AND expires_at > now()
        """)
    int markAccepted(@Param("id") UUID id, @Param("userId") UUID userId);

    @Select("""
        SELECT m.id, m.device_id, m.user_id, u.email, u.display_name,
               m.role::text, m.status::text, m.joined_at
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
               m.role::text, m.status::text, m.joined_at
          FROM device_memberships m
          JOIN users u ON u.id = m.user_id
         WHERE m.device_id = #{deviceId} AND m.status = 'ACTIVE'
         ORDER BY CASE WHEN m.role = 'OWNER' THEN 0 ELSE 1 END, m.joined_at, m.id
        """)
    List<MembershipRow> findActiveMembers(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT m.id, m.device_id, m.user_id, u.email, u.display_name,
               m.role::text, m.status::text, m.joined_at
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
}
