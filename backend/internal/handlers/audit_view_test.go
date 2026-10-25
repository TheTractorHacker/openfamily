package handlers

import (
	"context"
	"testing"

	"github.com/wheresfrank/openfamily/backend/internal/sms"
)

type auditRow struct{ user, family, action, detail string }

func auditCapture(s *Server) *[]auditRow {
	var rows []auditRow
	s.auditHook = func(u, f, a, d string) { rows = append(rows, auditRow{u, f, a, d}) }
	return &rows
}

func TestAuditAdminViewWritesFamilyScopedRow(t *testing.T) {
	s := &Server{viewAudit: sms.NewLimiter()}
	rows := auditCapture(s)
	s.auditAdminView(context.Background(), "admin-1", "fam-9", "viewed location history of member m1", "203.0.113.1")
	if len(*rows) != 1 {
		t.Fatalf("rows=%d", len(*rows))
	}
	got := (*rows)[0]
	if got.action != "admin.location_view" || got.family != "fam-9" || got.user != "admin-1" {
		t.Fatalf("row=%+v", got)
	}
}

func TestAuditAdminViewThrottlesIdenticalReadsButNotDifferentOnes(t *testing.T) {
	s := &Server{viewAudit: sms.NewLimiter()}
	rows := auditCapture(s)
	ctx := context.Background()
	for i := 0; i < 20; i++ { // admin panel polling the list
		s.auditAdminView(ctx, "admin-1", "", "listed last known locations of all members", "ip")
	}
	if len(*rows) != 1 {
		t.Fatalf("polling wrote %d rows, want 1", len(*rows))
	}
	s.auditAdminView(ctx, "admin-1", "fam-1", "viewed location history of member a", "ip")
	s.auditAdminView(ctx, "admin-1", "fam-2", "viewed location history of member b", "ip")
	s.auditAdminView(ctx, "admin-2", "", "listed last known locations of all members", "ip")
	if len(*rows) != 4 {
		t.Fatalf("distinct reads should each be recorded, rows=%d", len(*rows))
	}
}
