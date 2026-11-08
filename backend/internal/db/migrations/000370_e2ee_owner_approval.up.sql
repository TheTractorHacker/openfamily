-- Owner approval (docs/design/E2EE.md "Owner approval"): a per-circle policy
-- that lets the circle's creator, while a circle admin, approve their OWN
-- replacement device when no second admin can. Off by default. Switching it
-- is a signed key-log action (12); owner_approval_seq is that entry's seq.
-- device_approvals.self_approved marks approvals made under the policy so
-- every screen can say "approved by the owner without a second admin".
ALTER TABLE circles ADD COLUMN IF NOT EXISTS owner_approval BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE circles ADD COLUMN IF NOT EXISTS owner_approval_seq BIGINT;
ALTER TABLE device_approvals ADD COLUMN IF NOT EXISTS self_approved BOOLEAN NOT NULL DEFAULT FALSE;
