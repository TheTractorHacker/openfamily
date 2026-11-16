package handlers

import (
	"time"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

func TestInviteGuardPerCodeLockout(t *testing.T) {
	s := &Server{AuthLimit: sms.NewLimiter()}
	for i := 0; i < inviteFailPerCode; i++ {
		w := httptest.NewRecorder()
		if s.inviteLocked(w, "ABCD2345", "u1") {
			t.Fatalf("locked after %d failures", i)
		}
		s.inviteFailed("ABCD2345", "u1")
	}
	w := httptest.NewRecorder()
	if !s.inviteLocked(w, "ABCD2345", "u2") || w.Code != http.StatusTooManyRequests {
		t.Fatalf("code must be locked for everyone, got %d", w.Code)
	}
	// A different code from a different user is unaffected.
	if s.inviteLocked(httptest.NewRecorder(), "ZZZZ2345", "u2") {
		t.Fatal("unrelated code locked")
	}
}

func TestInviteGuardPerUserAndGlobal(t *testing.T) {
	s := &Server{AuthLimit: sms.NewLimiter()}
	for i := 0; i < inviteFailPerUser; i++ {
		s.inviteFailed("CODE"+string(rune('A'+i))+"2345", "u1")
	}
	if !s.inviteLocked(httptest.NewRecorder(), "FRESH2345", "u1") {
		t.Fatal("user must be locked after repeated failures")
	}
	if s.inviteLocked(httptest.NewRecorder(), "FRESH2345", "u2") {
		t.Fatal("other user must not be locked")
	}
	g := &Server{AuthLimit: sms.NewLimiter()}
	for i := 0; i < inviteFailGlobal; i++ {
		g.AuthLimit.Record(inviteGlobalKey, inviteFailGlobalWin)
	}
	start := time.Now()
	if g.inviteLocked(httptest.NewRecorder(), "ANY22222", "") {
		t.Fatal("global ceiling must slow attempts down, never lock valid redemptions out")
	}
	if time.Since(start) < inviteStormDelay {
		t.Fatal("global ceiling must add a delay")
	}
}

func TestInviteGuardNilLimiter(t *testing.T) {
	s := &Server{}
	s.inviteFailed("X", "u")
	if s.inviteLocked(httptest.NewRecorder(), "X", "u") {
		t.Fatal("nil limiter must not lock")
	}
}
