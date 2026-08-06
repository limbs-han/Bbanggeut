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

    /**
     * 감지로 담긴 영상이 도착했다고 가족 전원에게 알린다.
     *
     * <p>{@code headline}은 감지 유형이 정한다(웃음·박수·호출·직접 촬영).
     * 예전에는 제목이 '웃음 영상이 도착했어요'로 SQL에 박혀 있었고 호출부도
     * 웃음만 걸러 불렀다 — 그래서 박수로 잡힌 영상은 알림 행조차 생기지
     * 않았다. 타입은 {@code LAUGHTER_VIDEO_READY}를 그대로 쓴다: 앱의 알림
     * 라우팅과 저장된 알림들이 이 값을 가리키고 있어, 이름을 바꾸는 대신
     * 보이는 문구로 유형을 구분한다.
     */
    @Insert("""
        INSERT INTO notifications (
            id, user_id, type, title, body, device_id, resource_id, dedupe_key
        )
        SELECT gen_random_uuid(), m.user_id, 'LAUGHTER_VIDEO_READY',
               #{headline}, #{title},
               #{deviceId}, #{videoId}, 'laughter-video:' || CAST(#{videoId} AS text)
          FROM device_bindings b
          JOIN vault_memberships m ON m.vault_id = b.vault_id
          JOIN users u ON u.id = m.user_id
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND m.status = 'ACTIVE'
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
        ON CONFLICT (user_id, dedupe_key) DO NOTHING
        """)
    int insertVideoArrivedNotifications(
        @Param("deviceId") UUID deviceId,
        @Param("videoId") UUID videoId,
        @Param("headline") String headline,
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
     * 만화 1단계(대사 구성) 완료. dedupe_key를 완성 알림과 갈라 두어야
     * 대사 알림 하나 때문에 뒤이은 완성 알림이 묻히지 않는다.
     */
    @Insert("""
        INSERT INTO notifications (
            id, user_id, type, title, body, vault_id, resource_id, dedupe_key
        )
        SELECT gen_random_uuid(), u.id, 'COMIC_SCRIPT_READY',
               '만화 대사가 준비됐어요', '고칠 곳을 확인하고 그림을 만들어 보세요',
               v.vault_id, v.id, 'comic-script:' || CAST(v.id AS text)
          FROM videos v
          JOIN users u ON u.id = #{userId}
         WHERE v.id = #{videoId}
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
        ON CONFLICT (user_id, dedupe_key) DO NOTHING
        """)
    int insertComicScriptReadyNotification(
        @Param("userId") UUID userId,
        @Param("videoId") UUID videoId
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
