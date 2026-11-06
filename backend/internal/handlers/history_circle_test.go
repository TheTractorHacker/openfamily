package handlers

import (
	"net/url"
	"testing"
	"time"
)

// #38: member history follows circle permissions, not the legacy family id.
// Needs TEST_DATABASE_URL.
func TestMemberHistoryFollowsCircleSharing(t *testing.T) {
	e := newCircleEnv(t)
	e.rt.Get("/family/members/{id}/history", e.srv.GetMemberHistory)
	n := time.Now().UTC()
	q := "?" + url.Values{"from": {n.Add(-2 * time.Hour).Format(time.RFC3339)}, "to": {n.Format(time.RFC3339)}}.Encode()
	hist := func(viewer, subject string) int {
		code, _, _ := e.do(viewer, "GET", "/family/members/"+e.ids[subject]+"/history"+q, nil)
		return code
	}

	c1 := e.createCircle("A", "Circle1", "B") // A and B share circle 1; C is outside
	if got := hist("A", "B"); got != 200 {
		t.Fatalf("co-member history = %d, want 200", got)
	}
	if got := hist("A", "A"); got != 200 {
		t.Fatalf("own history = %d, want 200", got)
	}
	if got := hist("C", "B"); got != 403 {
		t.Fatalf("outsider history = %d, want 403", got)
	}
	// B stops sharing: A may no longer read B's trail.
	e.mustCode("B", "PUT", "/circles/"+c1+"/sharing", map[string]bool{"enabled": false}, 200)
	if got := hist("A", "B"); got != 403 {
		t.Fatalf("history of a member who turned sharing off = %d, want 403", got)
	}
	if got := hist("B", "B"); got != 200 {
		t.Fatalf("own history with sharing off = %d, want 200", got)
	}
	e.mustCode("B", "PUT", "/circles/"+c1+"/sharing", map[string]bool{"enabled": true}, 200)
	if got := hist("A", "B"); got != 200 {
		t.Fatalf("history after re-enabling sharing = %d, want 200", got)
	}
}
