package com.wj.server.invitation.persistence;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.invitation.domain.InviteLinkRow;
import com.wj.server.invitation.domain.JoinRequestRow;
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

    // --- invite links ---

    @Update("""
        UPDATE device_invite_links
           SET revoked_at = now()
         WHERE device_id = #{deviceId} AND revoked_at IS NULL
        """)
    int revokeActiveLinks(@Param("deviceId") UUID deviceId);

    @Insert("""
        INSERT INTO device_invite_links (id, device_id, token_hash, created_by, expires_at)
        VALUES (#{id}, #{deviceId}, #{tokenHash}, #{createdBy}, #{expiresAt})
        """)
    int insertLink(
        @Param("id") UUID id,
        @Param("deviceId") UUID deviceId,
        @Param("tokenHash") String tokenHash,
        @Param("createdBy") UUID createdBy,
        @Param("expiresAt") Instant expiresAt
    );

    @Select("""
        SELECT l.id, l.device_id, l.expires_at, l.revoked_at,
               d.status::text AS device_status
          FROM device_invite_links l
          JOIN devices d ON d.id = l.device_id
         WHERE l.token_hash = #{tokenHash}
        """)
    Optional<InviteLinkRow> findLinkByTokenHash(@Param("tokenHash") String tokenHash);

    // --- join requests ---

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM device_memberships
             WHERE device_id = #{deviceId} AND user_id = #{userId} AND status = 'ACTIVE'
        )
        """)
    boolean activeMembershipExists(@Param("deviceId") UUID deviceId, @Param("userId") UUID userId);

    @Insert("""
        INSERT INTO join_requests (id, device_id, user_id)
        VALUES (#{id}, #{deviceId}, #{userId})
        """)
    int insertJoinRequest(
        @Param("id") UUID id,
        @Param("deviceId") UUID deviceId,
        @Param("userId") UUID userId
    );

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM join_requests
             WHERE device_id = #{deviceId} AND user_id = #{userId} AND status = 'PENDING'
        )
        """)
    boolean pendingJoinRequestExists(@Param("deviceId") UUID deviceId, @Param("userId") UUID userId);

    @Select("""
        SELECT r.id, r.device_id, r.user_id, u.email, u.display_name,
               r.status::text, r.requested_at
          FROM join_requests r
          JOIN users u ON u.id = r.user_id
         WHERE r.device_id = #{deviceId} AND r.status = 'PENDING'
         ORDER BY r.requested_at, r.id
        """)
    List<JoinRequestRow> findPendingJoinRequests(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT r.id, r.device_id, r.user_id, u.email, u.display_name,
               r.status::text, r.requested_at
          FROM join_requests r
          JOIN users u ON u.id = r.user_id
         WHERE r.id = #{requestId} AND r.device_id = #{deviceId}
         FOR UPDATE OF r
        """)
    Optional<JoinRequestRow> lockScopedJoinRequest(
        @Param("deviceId") UUID deviceId,
        @Param("requestId") UUID requestId
    );

    @Update("""
        UPDATE join_requests
           SET status = CAST(#{status} AS join_request_status), decided_at = now(), decided_by = #{decidedBy}
         WHERE id = #{requestId} AND status = 'PENDING'
        """)
    int decideJoinRequest(
        @Param("requestId") UUID requestId,
        @Param("status") String status,
        @Param("decidedBy") UUID decidedBy
    );

    // --- memberships ---

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
