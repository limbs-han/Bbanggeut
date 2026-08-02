package com.wj.server.notification.persistence;

import java.util.List;
import java.util.UUID;

import com.wj.server.notification.domain.NotificationRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface NotificationMapper {
    @Insert("""
        INSERT INTO notifications (
            id, user_id, type, title, body, device_id, resource_id, dedupe_key
        )
        SELECT #{id}, u.id, 'INVITATION_RECEIVED', '새로운 기기 초대',
               #{deviceName} || ' 기기에 초대되었습니다.',
               #{deviceId}, #{invitationId}, 'invitation:' || CAST(#{invitationId} AS text)
          FROM users u
         WHERE lower(u.email) = lower(#{email})
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
        ON CONFLICT (user_id, dedupe_key) DO NOTHING
        """)
    int insertInvitationNotification(
        @Param("id") UUID id,
        @Param("email") String email,
        @Param("deviceId") UUID deviceId,
        @Param("deviceName") String deviceName,
        @Param("invitationId") UUID invitationId
    );

    @Insert("""
        INSERT INTO notifications (
            id, user_id, type, title, body, vault_id, resource_id, dedupe_key
        )
        SELECT #{id}, u.id, 'INVITATION_RECEIVED', '새로운 Vault 초대',
               #{vaultName} || ' Vault에 초대되었습니다.',
               #{vaultId}, #{invitationId},
               'invitation:' || CAST(#{invitationId} AS text)
          FROM users u
         WHERE lower(u.email) = lower(#{email})
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
        ON CONFLICT (user_id, dedupe_key) DO NOTHING
        """)
    int insertVaultInvitationNotification(
        @Param("id") UUID id,
        @Param("email") String email,
        @Param("vaultId") UUID vaultId,
        @Param("vaultName") String vaultName,
        @Param("invitationId") UUID invitationId
    );

    @Insert("""
        INSERT INTO notifications (
            id, user_id, type, title, body, device_id, resource_id, dedupe_key
        )
        SELECT gen_random_uuid(), m.user_id, 'LAUGHTER_VIDEO_READY',
               '웃음 영상이 도착했어요', #{title},
               #{deviceId}, #{videoId}, 'laughter-video:' || CAST(#{videoId} AS text)
          FROM device_bindings b
          JOIN vault_memberships m ON m.vault_id = b.vault_id
          JOIN users u ON u.id = m.user_id
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND m.status = 'ACTIVE'
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
        ON CONFLICT (user_id, dedupe_key) DO NOTHING
        """)
    int insertLaughterVideoNotifications(
        @Param("deviceId") UUID deviceId,
        @Param("videoId") UUID videoId,
        @Param("title") String title
    );

    @Select("""
        SELECT id, type::text, title, body, device_id, vault_id,
               resource_id, read_at, created_at
          FROM notifications
         WHERE user_id = #{userId}
         ORDER BY created_at DESC, id DESC
         LIMIT #{limit}
        """)
    List<NotificationRow> findForUser(@Param("userId") UUID userId, @Param("limit") int limit);

    @Select("""
        SELECT count(*) FROM notifications
         WHERE user_id = #{userId} AND read_at IS NULL
        """)
    long countUnread(@Param("userId") UUID userId);

    @Update("""
        UPDATE notifications SET read_at = COALESCE(read_at, now())
         WHERE id = #{notificationId} AND user_id = #{userId}
        """)
    int markRead(
        @Param("userId") UUID userId,
        @Param("notificationId") UUID notificationId
    );

    @Update("""
        UPDATE notifications SET read_at = now()
         WHERE user_id = #{userId} AND read_at IS NULL
        """)
    int markAllRead(@Param("userId") UUID userId);
}
