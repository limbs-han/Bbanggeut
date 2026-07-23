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

    @Select("SELECT email FROM users WHERE id = #{userId} AND deleted_at IS NULL")
    Optional<String> findUserEmail(@Param("userId") UUID userId);

    // --- email invitations ---

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM device_memberships m
              JOIN users u ON u.id = m.user_id
             WHERE m.device_id = #{deviceId} AND m.status = 'ACTIVE'
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
        INSERT INTO invitations (id, device_id, inviter_id, invitee_email, expires_at)
        VALUES (#{id}, #{deviceId}, #{inviterId}, lower(btrim(#{inviteeEmail})), #{expiresAt})
        """)
    int insertInvitation(
        @Param("id") UUID id,
        @Param("deviceId") UUID deviceId,
        @Param("inviterId") UUID inviterId,
        @Param("inviteeEmail") String inviteeEmail,
        @Param("expiresAt") Instant expiresAt
    );

    @Select("""
        SELECT i.id, i.device_id, d.name AS device_name,
               i.inviter_id, iu.email AS inviter_email, iu.display_name AS inviter_display_name,
               i.invitee_email, i.status::text, i.expires_at, i.created_at
          FROM invitations i
          JOIN devices d ON d.id = i.device_id
          LEFT JOIN users iu ON iu.id = i.inviter_id
         WHERE i.device_id = #{deviceId} AND i.id = #{invitationId}
        """)
    Optional<InvitationRow> findScopedInvitation(
        @Param("deviceId") UUID deviceId,
        @Param("invitationId") UUID invitationId
    );

    @Select("""
        SELECT i.id, i.device_id, d.name AS device_name,
               i.inviter_id, iu.email AS inviter_email, iu.display_name AS inviter_display_name,
               i.invitee_email, i.status::text, i.expires_at, i.created_at
          FROM invitations i
          JOIN devices d ON d.id = i.device_id
          LEFT JOIN users iu ON iu.id = i.inviter_id
         WHERE i.device_id = #{deviceId} AND i.status = 'PENDING'
         ORDER BY i.created_at DESC, i.id
        """)
    List<InvitationRow> findDeviceInvitations(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT i.id, i.device_id, d.name AS device_name,
               i.inviter_id, iu.email AS inviter_email, iu.display_name AS inviter_display_name,
               i.invitee_email, i.status::text, i.expires_at, i.created_at
          FROM invitations i
          JOIN devices d ON d.id = i.device_id
          LEFT JOIN users iu ON iu.id = i.inviter_id
         WHERE lower(i.invitee_email) = lower(#{email}) AND i.status = 'PENDING'
           AND i.expires_at > now() AND d.status != 'REVOKED'
         ORDER BY i.created_at DESC, i.id
        """)
    List<InvitationRow> findReceivedInvitations(@Param("email") String email);

    @Select("""
        SELECT i.id, i.device_id, d.name AS device_name,
               i.inviter_id, iu.email AS inviter_email, iu.display_name AS inviter_display_name,
               i.invitee_email, i.status::text, i.expires_at, i.created_at
          FROM invitations i
          JOIN devices d ON d.id = i.device_id
          LEFT JOIN users iu ON iu.id = i.inviter_id
         WHERE i.id = #{invitationId}
         FOR UPDATE OF i
        """)
    Optional<InvitationRow> lockInvitation(@Param("invitationId") UUID invitationId);

    @Update("""
        UPDATE invitations
           SET status = 'REVOKED', decided_by = #{ownerId}, decided_at = now(), updated_at = now()
         WHERE id = #{invitationId} AND device_id = #{deviceId} AND status = 'PENDING'
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

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM device_memberships
             WHERE device_id = #{deviceId} AND user_id = #{userId} AND status = 'ACTIVE'
        )
        """)
    boolean activeMembershipExists(@Param("deviceId") UUID deviceId, @Param("userId") UUID userId);

    @Insert("""
        INSERT INTO device_memberships (device_id, user_id, role, status, joined_at)
        VALUES (#{deviceId}, #{userId}, 'MEMBER', 'ACTIVE', now())
        ON CONFLICT (device_id, user_id) DO UPDATE
            SET role = 'MEMBER', status = 'ACTIVE', joined_at = now(),
                revoked_at = NULL, revoked_by = NULL, updated_at = now()
        """)
    int activateMember(@Param("deviceId") UUID deviceId, @Param("userId") UUID userId);

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
