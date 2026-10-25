package handlers

import (
	"testing"
	"time"

	"github.com/wheresfrank/openfamily/backend/internal/models"
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
