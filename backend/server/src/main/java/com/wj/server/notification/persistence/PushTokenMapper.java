package com.wj.server.notification.persistence;

import java.util.List;
import java.util.UUID;

import com.wj.server.notification.api.PushPlatform;
import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface PushTokenMapper {
    @Delete("""
        DELETE FROM notification_push_tokens
         WHERE token = #{token}
           AND (user_id <> #{userId} OR installation_id <> #{installationId})
        """)
    int deleteTokenFromOtherInstallation(
        @Param("userId") UUID userId,
        @Param("installationId") String installationId,
        @Param("token") String token
    );

    @Insert("""
        INSERT INTO notification_push_tokens (
            id, user_id, installation_id, token, platform
        ) VALUES (
            #{id}, #{userId}, #{installationId}, #{token}, CAST(#{platform} AS push_platform)
        )
        ON CONFLICT (user_id, installation_id) DO UPDATE
            SET token = EXCLUDED.token,
                platform = EXCLUDED.platform,
                updated_at = now()
        """)
    int upsert(
        @Param("id") UUID id,
        @Param("userId") UUID userId,
        @Param("installationId") String installationId,
        @Param("token") String token,
        @Param("platform") PushPlatform platform
    );

    @Delete("""
        DELETE FROM notification_push_tokens
         WHERE user_id = #{userId} AND installation_id = #{installationId}
        """)
    int deleteForUser(
        @Param("userId") UUID userId,
        @Param("installationId") String installationId
    );

    @Delete("""
        <script>
        DELETE FROM notification_push_tokens
         WHERE token IN
        <foreach item="token" collection="tokens" open="(" separator="," close=")">
          #{token}
        </foreach>
        </script>
        """)
    int deleteTokens(@Param("tokens") List<String> tokens);

    @Select("""
        SELECT pt.token
          FROM notification_push_tokens pt
          JOIN users u ON u.id = pt.user_id
         WHERE lower(u.email) = lower(#{email})
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
         ORDER BY pt.created_at, pt.id
        """)
    List<String> findActiveTokensByEmail(@Param("email") String email);

    /**
     * 새 영상(추억) 푸시 수신자. "새로운 추억 알림"을 끈 사용자는 제외하며,
     * 설정 행이 없으면 켜진 것으로 본다. 인앱 알림 목록에는 영향이 없다.
     */
    @Select("""
        SELECT DISTINCT pt.token
          FROM notification_push_tokens pt
          JOIN users u ON u.id = pt.user_id
          JOIN vault_memberships m ON m.user_id = pt.user_id
          JOIN device_bindings b
            ON b.vault_id = m.vault_id AND b.status = 'ACTIVE'
          LEFT JOIN user_notification_preferences p ON p.user_id = pt.user_id
         WHERE b.device_id = #{deviceId} AND m.status = 'ACTIVE'
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
           AND COALESCE(p.new_memory_alerts, true)
         ORDER BY pt.token
        """)
    List<String> findActiveTokensByDevice(@Param("deviceId") UUID deviceId);

    @Select("""
        SELECT pt.token
          FROM notification_push_tokens pt
          JOIN users u ON u.id = pt.user_id
         WHERE pt.user_id = #{userId}
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
         ORDER BY pt.created_at, pt.id
        """)
    List<String> findActiveTokensByUser(@Param("userId") UUID userId);

    @Select("""
        SELECT DISTINCT pt.token
          FROM notification_push_tokens pt
          JOIN users u ON u.id = pt.user_id
          JOIN vault_memberships m ON m.user_id = pt.user_id
          JOIN videos v ON v.vault_id = m.vault_id
         WHERE v.id = #{videoId} AND m.status = 'ACTIVE'
           AND pt.user_id <> #{excludeUserId}
           AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
         ORDER BY pt.token
        """)
    List<String> findActiveTokensByVideoExcluding(
        @Param("videoId") UUID videoId,
        @Param("excludeUserId") UUID excludeUserId
    );
}
