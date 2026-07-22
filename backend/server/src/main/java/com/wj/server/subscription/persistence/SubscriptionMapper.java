package com.wj.server.subscription.persistence;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.subscription.domain.SubscriptionRow;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface SubscriptionMapper {

    @Select("""
        SELECT d.subscription_active, d.subscription_grace_until
          FROM devices d
          JOIN device_memberships m ON m.device_id = d.id
         WHERE d.id = #{deviceId} AND m.user_id = #{userId}
           AND m.status = 'ACTIVE' AND d.status != 'REVOKED'
        """)
    Optional<SubscriptionRow> findAccessibleSubscription(
        @Param("userId") UUID userId,
        @Param("deviceId") UUID deviceId
    );

    @Update("""
        UPDATE devices
           SET subscription_active = true, subscription_grace_until = NULL, updated_at = now()
         WHERE id = #{deviceId} AND status != 'REVOKED'
        """)
    int activate(@Param("deviceId") UUID deviceId);

    @Update("""
        UPDATE devices
           SET subscription_active = false, subscription_grace_until = #{graceUntil}, updated_at = now()
         WHERE id = #{deviceId} AND status != 'REVOKED' AND subscription_active = true
        """)
    int cancel(@Param("deviceId") UUID deviceId, @Param("graceUntil") Instant graceUntil);

    /** Never shortens an existing expiry; only extends up to the premium window. */
    @Update("""
        UPDATE videos
           SET retention_until = GREATEST(
                   COALESCE(retention_until, 'epoch'::timestamptz),
                   COALESCE(uploaded_at, created_at) + make_interval(days => #{premiumRetentionDays})),
               updated_at = now()
         WHERE device_id = #{deviceId} AND status NOT IN ('DELETING', 'DELETED')
        """)
    int extendRetentionToPremium(
        @Param("deviceId") UUID deviceId,
        @Param("premiumRetentionDays") int premiumRetentionDays
    );

    /**
     * On cancel, every video falls back to the device baseline but keeps at
     * least the grace window so the user can download or resubscribe.
     */
    @Update("""
        UPDATE videos v
           SET retention_until = GREATEST(
                   COALESCE(v.uploaded_at, v.created_at) + make_interval(days => d.retention_days),
                   #{graceUntil}),
               updated_at = now()
          FROM devices d
         WHERE d.id = v.device_id
           AND v.device_id = #{deviceId}
           AND v.status NOT IN ('DELETING', 'DELETED')
        """)
    int resetRetentionToBaseline(@Param("deviceId") UUID deviceId, @Param("graceUntil") Instant graceUntil);
}
