package com.wj.server.notification.persistence;

import java.util.List;
import java.util.UUID;

import com.wj.server.notification.domain.ComicMadeRow;
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
            id, user_id, type, title, body, device_id, vault_id, resource_id, dedupe_key
        )
        SELECT #{id}, u.id, 'INVITATION_ACCEPTED', '초대를 수락했어요',
               #{memberName} || ' 님이 초대를 수락하고 가족이 되었어요.',
               #{deviceId}, #{vaultId}, #{invitationId},
               'invitation-accepted:' || CAST(#{invitationId} AS text)
          FROM users u
         WHERE u.id = #{inviterId}
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
        ON CONFLICT (user_id, dedupe_key) DO NOTHING
        """)
    int insertInvitationAcceptedNotification(
        @Param("id") UUID id,
        @Param("inviterId") UUID inviterId,
        @Param("memberName") String memberName,
        @Param("deviceId") UUID deviceId,
        @Param("vaultId") UUID vaultId,
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

    @Insert("""
        INSERT INTO notifications (
            id, user_id, type, title, body, vault_id, resource_id, dedupe_key
        )
        SELECT gen_random_uuid(), u.id, 'EDIT_ANALYSIS_READY',
               'AI 분석이 끝났어요', '편집기에서 AI 컷과 자동 줌을 쓸 수 있어요',
               v.vault_id, v.id, 'edit-analysis:' || CAST(v.id AS text)
          FROM videos v
          JOIN users u ON u.id = #{userId}
         WHERE v.id = #{videoId}
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
        ON CONFLICT (user_id, dedupe_key) DO NOTHING
        """)
    int insertEditAnalysisReadyNotification(
        @Param("userId") UUID userId,
        @Param("videoId") UUID videoId
    );

    @Insert("""
        INSERT INTO notifications (
            id, user_id, type, title, body, vault_id, resource_id, dedupe_key
        )
        SELECT gen_random_uuid(), u.id, 'COMIC_READY',
               '4컷 만화가 완성됐어요', '추억 탭에서 만화를 확인해 보세요',
               v.vault_id, v.id, 'comic:' || CAST(v.id AS text)
          FROM videos v
          JOIN users u ON u.id = #{userId}
         WHERE v.id = #{videoId}
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
        ON CONFLICT (user_id, dedupe_key) DO NOTHING
        """)
    int insertComicReadyNotification(
        @Param("userId") UUID userId,
        @Param("videoId") UUID videoId
    );

    /**
     * 이 금고에서 만화를 만들어 둔 영상과 그 시각.
     *
     * <p>별도 저장을 두지 않고 알림 행을 기록으로 쓴다 — 만화가 완성될 때마다
     * COMIC_READY 행이 남고, 거기에 vault_id와 resource_id가 이미 있다. 그래서
     * 목록 배지를 그리려고 영상마다 워커에 묻는 N+1을 만들지 않아도 된다.
     *
     * <p>누가 만들었는지는 보지 않는다. 만화는 금고에 속하므로 가족 누구에게나
     * 배지가 보여야 한다.
     */
    @Select("""
        SELECT n.resource_id AS video_id, MIN(n.created_at) AS made_at
          FROM notifications n
          JOIN vault_memberships m ON m.vault_id = n.vault_id
         WHERE n.vault_id = #{vaultId} AND n.type = 'COMIC_READY'
           AND n.resource_id IS NOT NULL
           AND m.user_id = #{userId} AND m.status = 'ACTIVE'
         GROUP BY n.resource_id
         ORDER BY made_at DESC
         LIMIT #{limit}
        """)
    List<ComicMadeRow> findComicsByVault(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId,
        @Param("limit") int limit
    );

    @Insert("""
        INSERT INTO notifications (
            id, user_id, type, title, body, vault_id, resource_id, dedupe_key
        )
        SELECT gen_random_uuid(), m.user_id, 'EDIT_COMMENT_ADDED',
               '가족이 편집 영상에 댓글을 남겼어요', #{body},
               v.vault_id, v.id,
               'edit-comment:' || CAST(v.id AS text) || ':' || #{commentId}
          FROM videos v
          JOIN vault_memberships m ON m.vault_id = v.vault_id
          JOIN users u ON u.id = m.user_id
         WHERE v.id = #{videoId} AND m.status = 'ACTIVE'
           AND m.user_id <> #{actorUserId}
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
        ON CONFLICT (user_id, dedupe_key) DO NOTHING
        """)
    int insertEditCommentNotifications(
        @Param("videoId") UUID videoId,
        @Param("actorUserId") UUID actorUserId,
        @Param("body") String body,
        @Param("commentId") String commentId
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
