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
        SELECT v.subscription_active, v.subscription_grace_until
          FROM device_bindings b
          JOIN memory_vaults v ON v.id = b.vault_id
          JOIN vault_memberships m ON m.vault_id = v.id
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND m.user_id = #{userId} AND m.status = 'ACTIVE'
        """)
    Optional<SubscriptionRow> findAccessibleSubscription(
        @Param("userId") UUID userId,
        @Param("deviceId") UUID deviceId
    );

    @Update("""
        UPDATE memory_vaults v
           SET subscription_active = true, subscription_grace_until = NULL, updated_at = now()
          FROM device_bindings b
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND v.id = b.vault_id AND v.status = 'ACTIVE'
        """)
    int activate(@Param("deviceId") UUID deviceId);

    @Update("""
        UPDATE memory_vaults v
           SET subscription_active = false, subscription_grace_until = #{graceUntil}, updated_at = now()
          FROM device_bindings b
         WHERE b.device_id = #{deviceId} AND b.status = 'ACTIVE'
           AND v.id = b.vault_id AND v.status = 'ACTIVE'
           AND v.subscription_active = true
        """)
    int cancel(@Param("deviceId") UUID deviceId, @Param("graceUntil") Instant graceUntil);

    /** Never shortens an existing expiry; only extends up to the premium window. */
    @Update("""
        UPDATE videos
           SET retention_until = GREATEST(
                   COALESCE(retention_until, 'epoch'::timestamptz),
                   COALESCE(uploaded_at, created_at) + make_interval(days => #{premiumRetentionDays})),
               updated_at = now()
         WHERE vault_id = (
             SELECT vault_id FROM device_bindings
              WHERE device_id = #{deviceId} AND status = 'ACTIVE'
         ) AND status NOT IN ('DELETING', 'DELETED')
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
          FROM memory_vaults d
         WHERE d.id = v.vault_id
           AND v.vault_id = (
               SELECT vault_id FROM device_bindings
                WHERE device_id = #{deviceId} AND status = 'ACTIVE'
           )
           AND v.status NOT IN ('DELETING', 'DELETED')
        """)
    int resetRetentionToBaseline(@Param("deviceId") UUID deviceId, @Param("graceUntil") Instant graceUntil);

    // --- vault-scoped API (works while no device is connected) ---

    @Select("""
        SELECT v.subscription_active, v.subscription_grace_until
          FROM memory_vaults v
          JOIN vault_memberships m ON m.vault_id = v.id
         WHERE v.id = #{vaultId}
           AND m.user_id = #{userId} AND m.status = 'ACTIVE'
        """)
    Optional<SubscriptionRow> findAccessibleVaultSubscription(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId
    );

    @Select("""
        SELECT m.role::text
          FROM memory_vaults v
          JOIN vault_memberships m ON m.vault_id = v.id
         WHERE v.id = #{vaultId} AND v.status = 'ACTIVE'
           AND m.user_id = #{userId} AND m.status = 'ACTIVE'
         FOR UPDATE OF v
        """)
    Optional<String> lockVaultRole(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId
    );

    @Update("""
        UPDATE memory_vaults
           SET subscription_active = true, subscription_grace_until = NULL,
               updated_at = now()
         WHERE id = #{vaultId} AND status = 'ACTIVE'
        """)
    int activateVault(@Param("vaultId") UUID vaultId);

    @Update("""
        UPDATE memory_vaults
           SET subscription_active = false,
               subscription_grace_until = #{graceUntil}, updated_at = now()
         WHERE id = #{vaultId} AND status = 'ACTIVE'
           AND subscription_active = true
        """)
    int cancelVault(
        @Param("vaultId") UUID vaultId,
        @Param("graceUntil") Instant graceUntil
    );

    @Update("""
        UPDATE videos
           SET retention_until = GREATEST(
                   COALESCE(retention_until, 'epoch'::timestamptz),
                   COALESCE(uploaded_at, created_at)
                       + make_interval(days => #{premiumRetentionDays})),
               updated_at = now()
         WHERE vault_id = #{vaultId}
           AND status NOT IN ('DELETING', 'DELETED')
        """)
    int extendVaultRetentionToPremium(
        @Param("vaultId") UUID vaultId,
        @Param("premiumRetentionDays") int premiumRetentionDays
    );

    @Update("""
        UPDATE videos v
           SET retention_until = GREATEST(
                   COALESCE(v.uploaded_at, v.created_at)
                       + make_interval(days => d.retention_days),
                   #{graceUntil}),
               updated_at = now()
          FROM memory_vaults d
         WHERE d.id = v.vault_id
           AND v.vault_id = #{vaultId}
           AND v.status NOT IN ('DELETING', 'DELETED')
        """)
    int resetVaultRetentionToBaseline(
        @Param("vaultId") UUID vaultId,
        @Param("graceUntil") Instant graceUntil
    );
}
