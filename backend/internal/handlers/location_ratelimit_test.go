package handlers

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

// testClaims builds access-token claims for the given user id.
func testClaims(userID string) *auth.Claims {
	return &auth.Claims{
		UserID:       userID,
		TokenType:    auth.AccessToken,
		TokenVersion: 1,
	}
}

// TestIngestLocationRateLimited verifies the per-user ingest throttle trips
// with a 429 once the window is exhausted. The limiter check runs before any
// database access, so this needs no Postgres.
func TestIngestLocationRateLimited(t *testing.T) {
	s := &Server{LocationLimit: sms.NewLimiter()}

	req := httptest.NewRequest(http.MethodPost, "/locations", nil)
	req = req.WithContext(middleware.ContextWithClaims(
		req.Context(), testClaims("11111111-1111-1111-1111-111111111111"),
	))
	rec := httptest.NewRecorder()

	var last int
	for i := 0; i <= ingestPerWindow; i++ {
		rec = httptest.NewRecorder()
		s.IngestLocation(rec, req)
		last = rec.Code
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("after %d requests got status %d, want %d", ingestPerWindow, last, http.StatusTooManyRequests)
	}

	// A different user still has their own budget.
	req2 := httptest.NewRequest(http.MethodPost, "/locations", nil)
	req2 = req2.WithContext(middleware.ContextWithClaims(
		req2.Context(), testClaims("22222222-2222-2222-2222-222222222222"),
	))
	rec2 := httptest.NewRecorder()
	s.IngestLocation(rec2, req2)
	if rec2.Code == http.StatusTooManyRequests {
		t.Error("second user was rate limited by the first user's budget")
	}
}

// TestIngestLocationUnlimitedWhenNil ensures a nil LocationLimit (tests,
// embedders) keeps the endpoint open.
func TestIngestLocationUnlimitedWhenNil(t *testing.T) {
	s := &Server{}
	req := httptest.NewRequest(http.MethodPost, "/locations", nil)
	req = req.WithContext(middleware.ContextWithClaims(
		req.Context(), testClaims("33333333-3333-3333-3333-333333333333"),
	))
	rec := httptest.NewRecorder()
	s.IngestLocation(rec, req)
	if rec.Code == http.StatusTooManyRequests {
		t.Error("nil limiter must not rate limit")
	}
}
