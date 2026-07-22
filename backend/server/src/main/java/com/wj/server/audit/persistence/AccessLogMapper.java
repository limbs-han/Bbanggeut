package com.wj.server.audit.persistence;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.audit.domain.AccessLogRow;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface AccessLogMapper {
    @Insert("""
        INSERT INTO access_logs (
            device_id, actor_user_id, actor_device_id, action, target_type, target_id,
            outcome, reason_code, ip_address, user_agent, request_id
        ) VALUES (
            #{deviceId}, #{actorUserId}, #{actorDeviceId}, CAST(#{action} AS audit_action),
            #{targetType}, #{targetId}, CAST(#{outcome} AS audit_outcome), #{reasonCode},
            CAST(#{ipAddress} AS inet), #{userAgent}, #{requestId}
        )
        """)
    int insert(
        @Param("deviceId") UUID deviceId,
        @Param("actorUserId") UUID actorUserId,
        @Param("actorDeviceId") UUID actorDeviceId,
        @Param("action") String action,
        @Param("targetType") String targetType,
        @Param("targetId") UUID targetId,
        @Param("outcome") String outcome,
        @Param("reasonCode") String reasonCode,
        @Param("ipAddress") String ipAddress,
        @Param("userAgent") String userAgent,
        @Param("requestId") String requestId
    );

    @Select("""
        SELECT m.role::text
          FROM device_memberships m
          JOIN devices d ON d.id = m.device_id
         WHERE m.device_id = #{deviceId} AND m.user_id = #{userId}
           AND m.status = 'ACTIVE' AND d.status != 'REVOKED'
        """)
    Optional<String> findActiveRole(@Param("userId") UUID userId, @Param("deviceId") UUID deviceId);

    @Select("""
        <script>
        SELECT id, device_id, actor_user_id, actor_device_id, action::text, target_type,
               target_id, outcome::text, reason_code, created_at
          FROM access_logs
         WHERE device_id = #{deviceId}
        <if test="cursorCreatedAt != null">
           AND (created_at, id) &lt; (#{cursorCreatedAt}, #{cursorId})
        </if>
         ORDER BY created_at DESC, id DESC
         LIMIT #{limit}
        </script>
        """)
    List<AccessLogRow> findPage(
        @Param("deviceId") UUID deviceId,
        @Param("cursorCreatedAt") Instant cursorCreatedAt,
        @Param("cursorId") Long cursorId,
        @Param("limit") int limit
    );
}
