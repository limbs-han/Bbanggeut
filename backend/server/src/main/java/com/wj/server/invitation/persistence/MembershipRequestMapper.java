package com.wj.server.invitation.persistence;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.invitation.domain.MembershipRequestRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface MembershipRequestMapper {
    @Update("""
        UPDATE membership_request_links
           SET revoked_at = now()
         WHERE requester_id = #{requesterId}
           AND used_at IS NULL AND revoked_at IS NULL
        """)
    int revokeActiveLinks(@Param("requesterId") UUID requesterId);

    @Insert("""
        INSERT INTO membership_request_links (
            id, requester_id, token_hash, expires_at
        ) VALUES (
            #{id}, #{requesterId}, #{tokenHash}, #{expiresAt}
        )
        """)
    int insert(
        @Param("id") UUID id,
        @Param("requesterId") UUID requesterId,
        @Param("tokenHash") String tokenHash,
        @Param("expiresAt") Instant expiresAt
    );

    @Select("""
        SELECT r.id, r.requester_id, u.email, u.display_name,
               r.expires_at, r.used_at
          FROM membership_request_links r
          JOIN users u ON u.id = r.requester_id
         WHERE r.token_hash = #{tokenHash}
           AND r.used_at IS NULL AND r.revoked_at IS NULL
           AND r.expires_at > now() AND u.status = 'ACTIVE'
        """)
    Optional<MembershipRequestRow> findActive(@Param("tokenHash") String tokenHash);

    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM device_memberships
             WHERE user_id = #{userId} AND role = 'OWNER' AND status = 'ACTIVE'
        )
        """)
    boolean hasActiveOwnerMembership(@Param("userId") UUID userId);

    @Update("""
        UPDATE membership_request_links
           SET used_at = now(), used_by = #{ownerId}, invitation_id = #{invitationId}
         WHERE token_hash = #{tokenHash}
           AND requester_id = #{requesterId}
           AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()
        """)
    int consume(
        @Param("tokenHash") String tokenHash,
        @Param("requesterId") UUID requesterId,
        @Param("ownerId") UUID ownerId,
        @Param("invitationId") UUID invitationId
    );
}
