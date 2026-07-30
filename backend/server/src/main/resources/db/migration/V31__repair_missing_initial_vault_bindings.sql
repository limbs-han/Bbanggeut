-- Repair active legacy devices for which the initial Vault migration was only
-- partially applied. Devices with any binding history are intentionally
-- excluded: automatically choosing a historical Vault after a transfer could
-- expose new recordings to the wrong household.
INSERT INTO memory_vaults (
    id, name, status, retention_days, subscription_active,
    subscription_grace_until, created_at, updated_at
)
SELECT d.id, d.name, 'ACTIVE', d.retention_days, d.subscription_active,
       d.subscription_grace_until, d.created_at, now()
  FROM devices d
 WHERE d.status IN ('ONLINE', 'OFFLINE')
   AND d.claimed_by IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM device_bindings b WHERE b.device_id = d.id
   )
ON CONFLICT (id) DO NOTHING;

INSERT INTO vault_memberships (
    vault_id, user_id, role, status, joined_at, created_at, updated_at
)
SELECT d.id, d.claimed_by, 'OWNER', 'ACTIVE',
       COALESCE(d.claimed_at, d.created_at), d.created_at, now()
  FROM devices d
  JOIN memory_vaults v ON v.id = d.id AND v.status = 'ACTIVE'
 WHERE d.status IN ('ONLINE', 'OFFLINE')
   AND d.claimed_by IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM device_bindings b WHERE b.device_id = d.id
   )
   AND NOT EXISTS (
       SELECT 1
         FROM vault_memberships owner_membership
        WHERE owner_membership.vault_id = d.id
          AND owner_membership.role = 'OWNER'
          AND owner_membership.status = 'ACTIVE'
   )
ON CONFLICT (vault_id, user_id) DO NOTHING;

INSERT INTO device_bindings (
    device_id, vault_id, generation, status, bound_at,
    created_at, updated_at
)
SELECT d.id, d.id, 1, 'ACTIVE',
       COALESCE(d.claimed_at, d.created_at), d.created_at, now()
  FROM devices d
  JOIN memory_vaults v ON v.id = d.id AND v.status = 'ACTIVE'
  JOIN vault_memberships owner_membership
    ON owner_membership.vault_id = v.id
   AND owner_membership.user_id = d.claimed_by
   AND owner_membership.role = 'OWNER'
   AND owner_membership.status = 'ACTIVE'
 WHERE d.status IN ('ONLINE', 'OFFLINE')
   AND NOT EXISTS (
       SELECT 1 FROM device_bindings b WHERE b.device_id = d.id
   )
ON CONFLICT (device_id, generation) DO NOTHING;
