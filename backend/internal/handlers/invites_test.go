package handlers

import (
	"context"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

func TestNormalizeInviteParamsDefaultsAndBounds(t *testing.T) {
	role, uses, exp, err := normalizeInviteParams("", 0, 0)
	if err != nil || role != models.RoleMember || uses != 1 || exp == nil {
		t.Fatalf("defaults: %v %v %v %v", role, uses, exp, err)
	}
	if d := time.Until(*exp); d < 6*24*time.Hour || d > 8*24*time.Hour {
		t.Fatalf("default expiry %v", d)
	}
	if _, _, _, err := normalizeInviteParams(models.RoleMember, maxInviteUses, maxInviteExpiryHrs); err != nil {
		t.Fatalf("limits themselves must be allowed: %v", err)
	}
	for name, c := range map[string][2]int{
		"huge expiry (overflowing Duration)": {1, 1_000_000_000_000},
		"expiry just over cap":               {1, maxInviteExpiryHrs + 1},
		"max_uses over cap":                  {maxInviteUses + 1, 24},
		"max_uses huge":                      {1 << 30, 24},
	} {
		if _, _, _, err := normalizeInviteParams(models.RoleMember, c[0], c[1]); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, _, _, err := normalizeInviteParams("root", 1, 1); err == nil {
		t.Error("invalid role accepted")
	}
}

// A legacy invite (family_id only) must not bring a deleted circle back: the code is refused once the circle row is gone.
func TestRedeemInviteRefusesDeletedCircle(t *testing.T) {
	e := newCircleEnv(t)
	ctx := context.Background()
	c := e.createCircle("A", "Gone")
	if _, err := e.pool.Exec(ctx, `INSERT INTO families (id, name) VALUES ($1, 'Gone') ON CONFLICT DO NOTHING`, c); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO invite_codes (code, family_id, created_by, role, max_uses) VALUES ('LEGACYGONE1', $1, $2, 'member', 5)`, c, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	try := func() error {
		tx, err := e.pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		_, _, _, err = e.srv.redeemInviteCode(ctx, tx, "LEGACYGONE1", true)
		return err
	}
	if err := try(); err != nil {
		t.Fatalf("live circle: %v", err)
	}
	if _, err := e.pool.Exec(ctx, `DELETE FROM circles WHERE id = $1`, c); err != nil {
		t.Fatal(err)
	}
	if err := try(); err == nil {
		t.Fatal("legacy invite redeemed for a deleted circle")
	}
	_, _ = e.pool.Exec(ctx, `DELETE FROM invite_codes WHERE code = 'LEGACYGONE1'`)
	_, _ = e.pool.Exec(ctx, `DELETE FROM families WHERE id = $1`, c)
}
