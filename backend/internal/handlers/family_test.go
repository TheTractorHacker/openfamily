package handlers

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

func TestLeaveFamilyBlocked(t *testing.T) {
	cases := []struct {
		role       models.Role
		adminCount int
		blocked    bool
	}{
		{models.RoleAdmin, 1, true},
		{models.RoleAdmin, 2, false},
		{models.RoleMember, 1, false},
		{models.RoleChild, 1, false},
		{models.RoleAdmin, 0, true},
	}
	for _, tc := range cases {
		got := leaveFamilyBlocked(tc.role, tc.adminCount)
		if got != tc.blocked {
			t.Errorf("role=%s admins=%d: blocked=%v want %v", tc.role, tc.adminCount, got, tc.blocked)
		}
	}
}

func TestRenameFamilyUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Patch("/family", srv.RenameFamily)
	req := httptest.NewRequest(http.MethodPatch, "/family", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestLeaveFamilyUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Post("/family/leave", srv.LeaveFamily)
	req := httptest.NewRequest(http.MethodPost, "/family/leave", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}
