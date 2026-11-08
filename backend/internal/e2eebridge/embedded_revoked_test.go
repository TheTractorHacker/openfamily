package e2eebridge

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The API answers 404 "no active server key" once the server key was revoked (for example when
// the owner account's keys were reset). That must not be reported as a bad ingest token, and the
// embedded device must archive the dead key and make a new one that waits for approval.
func TestRevokedServerKeyIsReplaced(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"code":"server_key_revoked","error":"no active server key with that id"}`))
	}))
	defer srv.Close()

	dir := t.TempDir()
	e, err := OpenEmbedded(EmbeddedOptions{Dir: dir, BaseURL: srv.URL, Token: "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-xx", Log: slog.Default(),
		MintAccess: func(context.Context, string) (string, error) { return "x", nil }})
	if err != nil {
		t.Fatal(err)
	}
	oldID := e.id.f.DeviceID
	e.id.f.UserID, e.id.f.RegisteredAt = "75e5320a-7604-4b93-832b-e641eb025ca5", "2026-11-07T22:14:20Z"
	if err := e.st.saveIdentity(e.id); err != nil {
		t.Fatal(err)
	}

	ss := newServerSink(&config{Ingest: ingestCfg{URL: srv.URL, token: "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-xx"}}, oldID, slog.Default())
	if err := ss.pin(context.Background()); !errors.Is(err, errServerKeyGone) {
		t.Fatalf("pin error = %v, want errServerKeyGone", err)
	}

	e.replaceRevokedKey()
	if e.id.f.DeviceID == oldID || e.id.f.RegisteredAt != "" || e.state != StateWaitingApproval {
		t.Fatalf("new key not waiting for approval: %+v state=%s", e.id.f, e.state)
	}
	got, err := e.st.loadIdentity()
	if err != nil || got.f.DeviceID != e.id.f.DeviceID {
		t.Fatalf("new identity not saved: %v", err)
	}
	matches, _ := filepath.Glob(filepath.Join(dir, "archive", "revoked-*", fileIdentity))
	if len(matches) != 1 {
		t.Fatalf("old identity not archived: %v", matches)
	}
	b, err := os.ReadFile(matches[0])
	if err != nil || len(b) == 0 {
		t.Fatalf("archived identity unreadable: %v", err)
	}
	if strings.Contains(string(b), `"seed"`) || strings.Contains(string(b), `"ct"`) {
		t.Fatalf("archive keeps secret material: %s", b)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(matches[0]), fileKeys)); err == nil {
		t.Fatal("circle keys were archived")
	}
}
