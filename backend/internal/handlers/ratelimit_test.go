package handlers

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

func TestAllowAuthNilLimiter(t *testing.T) {
	srv := &Server{}
	w := httptest.NewRecorder()
	if !srv.allowAuth(w, "login:ip:1.1.1.1", 1, time.Minute) {
		t.Fatal("nil limiter should allow")
	}
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d", w.Code)
	}
}

func TestAllowAuthRejectsBurst(t *testing.T) {
	srv := &Server{AuthLimit: sms.NewLimiter()}
	w1 := httptest.NewRecorder()
	if !srv.allowAuth(w1, "login:ip:1.1.1.1", 1, time.Minute) {
		t.Fatal("first hit should allow")
	}
	w2 := httptest.NewRecorder()
	if srv.allowAuth(w2, "login:ip:1.1.1.1", 1, time.Minute) {
		t.Fatal("second hit should deny")
	}
	if w2.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d body=%s", w2.Code, w2.Body.String())
	}
}

// Spoofed forwarding headers from an untrusted peer must not buy extra
// register attempts (BSEC-002): 6 attempts from one peer are limited even when
// every request claims a different X-Real-IP / X-Forwarded-For.
func TestRegisterLimitIgnoresSpoofedHeaders(t *testing.T) {
	srv := &Server{AuthLimit: sms.NewLimiter()}
	r := chi.NewRouter()
	r.Use(middleware.ClientIP(nil))
	r.Post("/auth/register", srv.Register)

	var last int
	for i := 0; i < registerPerIP+1; i++ {
		req := httptest.NewRequest(http.MethodPost, "/auth/register", nil)
		req.RemoteAddr = "203.0.113.50:4242"
		req.Header.Set("X-Real-IP", "10.0.0."+string(rune('1'+i)))
		req.Header.Set("True-Client-IP", "10.9.9."+string(rune('1'+i)))
		req.Header.Set("X-Forwarded-For", "10.8.8."+string(rune('1'+i)))
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		last = w.Code
		if i < registerPerIP && w.Code == http.StatusTooManyRequests {
			t.Fatalf("attempt %d limited too early", i+1)
		}
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("6th attempt status=%d, want 429", last)
	}
}

// Login lockout is per (ip, email): an attacker burning the budget for a
// victim's email from their own address does not block the victim elsewhere.
func TestLoginLockoutIsPerIPAndEmail(t *testing.T) {
	srv := &Server{AuthLimit: sms.NewLimiter()}
	attacker := authEmailKey("victim@example.com", "198.51.100.1")
	victim := authEmailKey("victim@example.com", "203.0.113.7")
	for i := 0; i < loginPerEmail; i++ {
		w := httptest.NewRecorder()
		if srv.loginBlocked(w, attacker) {
			t.Fatalf("blocked after only %d failures", i)
		}
		srv.loginFailed(attacker)
	}
	if !srv.loginBlocked(httptest.NewRecorder(), attacker) {
		t.Fatal("attacker pair not blocked after budget")
	}
	if srv.loginBlocked(httptest.NewRecorder(), victim) {
		t.Fatal("victim from another address was locked out")
	}
	srv.loginSucceeded(attacker)
	if srv.loginBlocked(httptest.NewRecorder(), attacker) {
		t.Fatal("success should reset the failure budget")
	}
}

func TestLimiterIPGroupsIPv6By64(t *testing.T) {
	if limiterIP("2001:db8::1") != limiterIP("2001:db8::ffff") {
		t.Fatal("same /64 should share a key")
	}
	if limiterIP("2001:db8:0:1::1") == limiterIP("2001:db8::1") {
		t.Fatal("different /64s should not share a key")
	}
	if limiterIP("192.0.2.1") != "192.0.2.1" {
		t.Fatal("ipv4 must be unchanged")
	}
}

func TestPreviouslyUnthrottledEndpointsAreLimited(t *testing.T) {
	srv := &Server{AuthLimit: sms.NewLimiter()}
	for i := 0; i < deleteMePerUser; i++ {
		if !srv.allowKey(httptest.NewRecorder(), "deleteme:user:u1", deleteMePerUser, deleteMeWindow) {
			t.Fatal("limited too early")
		}
	}
	w := httptest.NewRecorder()
	if srv.allowKey(w, "deleteme:user:u1", deleteMePerUser, deleteMeWindow) || w.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429, got allowed/%d", w.Code)
	}
}
