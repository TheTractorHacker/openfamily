package auth

import (
	"testing"
	"time"
)

func TestIssueAndParseTokenVersion(t *testing.T) {
	tm := NewTokenManager("test-secret-at-least-32-bytes-long!", time.Minute, time.Hour)
	access, err := tm.IssueAccess("user-1", "fam-1", 3)
	if err != nil {
		t.Fatal(err)
	}
	claims, err := tm.Parse(access, AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	if claims.UserID != "user-1" || claims.FamilyID != "fam-1" || claims.TokenVersion != 3 {
		t.Fatalf("claims=%+v", claims)
	}

	refresh, err := tm.IssueRefresh("user-1", "fam-1", 3)
	if err != nil {
		t.Fatal(err)
	}
	refreshClaims, err := tm.Parse(refresh, RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if refreshClaims.TokenVersion != 3 {
		t.Fatalf("refresh ver=%d", refreshClaims.TokenVersion)
	}
}

func TestAMRClaimRoundTripsAndDefaultsEmpty(t *testing.T) {
	m := NewTokenManager("secret-secret-secret-secret-secret", time.Minute, time.Hour)
	plain, _ := m.IssueAccess("u", "", 1)
	if c, err := m.Parse(plain, AccessToken); err != nil || c.AMR != "" {
		t.Fatalf("plain token must carry no amr: %+v %v", c, err)
	}
	a, _ := m.IssueAccessAMR("u", "", 1, AMRTOTP)
	if c, err := m.Parse(a, AccessToken); err != nil || c.AMR != AMRTOTP {
		t.Fatalf("access amr: %+v %v", c, err)
	}
	r, _ := m.IssueRefreshWithIDAMR("u", "", 1, "jti", AMRTOTP)
	if c, err := m.Parse(r, RefreshToken); err != nil || c.AMR != AMRTOTP || c.ID != "jti" {
		t.Fatalf("refresh amr: %+v %v", c, err)
	}
}
