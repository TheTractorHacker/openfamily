ALTER TABLE device_approvals DROP COLUMN IF EXISTS self_approved;
ALTER TABLE circles DROP COLUMN IF EXISTS owner_approval_seq;
ALTER TABLE circles DROP COLUMN IF EXISTS owner_approval;
