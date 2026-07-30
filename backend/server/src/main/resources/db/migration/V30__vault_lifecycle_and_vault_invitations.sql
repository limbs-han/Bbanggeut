-- Vault membership is independent from the physical device lifecycle.
-- Invitations therefore belong to a vault. device_id is retained only as
-- optional historical context for invitations created through the legacy API.
ALTER TABLE invitations
    ADD COLUMN IF NOT EXISTS vault_id uuid
        REFERENCES memory_vaults(id) ON DELETE RESTRICT;

UPDATE invitations i
   SET vault_id = (
      SELECT b.vault_id
        FROM device_bindings b
       WHERE b.device_id = i.device_id
       ORDER BY (b.status = 'ACTIVE') DESC, b.generation DESC
       LIMIT 1
   )
 WHERE i.vault_id IS NULL;

ALTER TABLE invitations ALTER COLUMN vault_id SET NOT NULL;
ALTER TABLE invitations ALTER COLUMN device_id DROP NOT NULL;

DROP INDEX IF EXISTS ux_invitations_one_pending_per_email;
DROP INDEX IF EXISTS ix_invitations_device_status;

CREATE UNIQUE INDEX ux_invitations_one_pending_per_vault_email
    ON invitations (vault_id, lower(invitee_email))
    WHERE status = 'PENDING';
CREATE INDEX ix_invitations_vault_status
    ON invitations (vault_id, status, created_at DESC);

-- Notifications can still navigate to a vault when no physical device is
-- currently connected.
ALTER TABLE notifications
    ADD COLUMN IF NOT EXISTS vault_id uuid
        REFERENCES memory_vaults(id) ON DELETE RESTRICT;

-- Vault administration remains auditable while no device is attached.
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'VAULT_UPDATE';
ALTER TABLE access_logs ALTER COLUMN device_id DROP NOT NULL;
ALTER TABLE access_logs
    ADD COLUMN IF NOT EXISTS vault_id uuid
        REFERENCES memory_vaults(id) ON DELETE RESTRICT;
ALTER TABLE access_logs
    ADD CONSTRAINT ck_access_logs_resource_scope
        CHECK (device_id IS NOT NULL OR vault_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS ix_access_logs_vault_time
    ON access_logs (vault_id, created_at DESC, id DESC)
    WHERE vault_id IS NOT NULL;

-- A completed binding is immutable history. Re-registering the same physical
-- device must always insert a new generation instead of reactivating or moving
-- an old row.
CREATE OR REPLACE FUNCTION prevent_device_binding_history_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.device_id <> OLD.device_id
       OR NEW.vault_id <> OLD.vault_id
       OR NEW.generation <> OLD.generation THEN
        RAISE EXCEPTION 'device binding identity is immutable';
    END IF;
    IF OLD.status <> 'ACTIVE' AND NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'completed device binding history is immutable';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_device_bindings_history_immutable ON device_bindings;
CREATE TRIGGER trg_device_bindings_history_immutable
BEFORE UPDATE ON device_bindings
FOR EACH ROW EXECUTE FUNCTION prevent_device_binding_history_change();

-- A live vault always has exactly one OWNER. The trigger is deferred so an
-- ownership transfer can demote and promote within one transaction.
CREATE OR REPLACE FUNCTION ensure_vault_has_one_owner()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    affected_vault_id uuid;
    owner_count integer;
    current_status vault_status;
BEGIN
    IF TG_TABLE_NAME = 'memory_vaults' THEN
        affected_vault_id := NEW.id;
    ELSIF TG_OP = 'DELETE' THEN
        affected_vault_id := OLD.vault_id;
    ELSE
        affected_vault_id := NEW.vault_id;
    END IF;

    SELECT status INTO current_status
      FROM memory_vaults
     WHERE id = affected_vault_id;

    IF current_status IS NOT NULL AND current_status <> 'CLOSED' THEN
        SELECT count(*) INTO owner_count
          FROM vault_memberships
         WHERE vault_id = affected_vault_id
           AND role = 'OWNER'
           AND status = 'ACTIVE';
        IF owner_count <> 1 THEN
            RAISE EXCEPTION 'vault % must have exactly one active OWNER',
                affected_vault_id;
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_vault_memberships_exactly_one_owner
    ON vault_memberships;
CREATE CONSTRAINT TRIGGER trg_vault_memberships_exactly_one_owner
AFTER INSERT OR UPDATE OR DELETE ON vault_memberships
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ensure_vault_has_one_owner();

DROP TRIGGER IF EXISTS trg_memory_vaults_exactly_one_owner ON memory_vaults;
CREATE CONSTRAINT TRIGGER trg_memory_vaults_exactly_one_owner
AFTER INSERT OR UPDATE ON memory_vaults
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ensure_vault_has_one_owner();
