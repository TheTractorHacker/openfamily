package e2eebridge

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
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

// NoteRevoked: the API process itself just revoked this key (an owner key reset). One "revoked"
// answer then replaces the key at once; the new key names the old one; an id that is not this
// device's key is ignored.
func TestNoteRevokedReplacesAtOnce(t *testing.T) {
	var pins atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		pins.Add(1)
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"code":"server_key_revoked","error":"no active server key with that id"}`))
	}))
	defer srv.Close()
	e, err := OpenEmbedded(EmbeddedOptions{Dir: t.TempDir(), BaseURL: srv.URL, Token: "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-xx", Log: slog.Default(),
		MintAccess: func(context.Context, string) (string, error) { return "x", nil }})
	if err != nil {
		t.Fatal(err)
	}
	oldID := e.id.f.DeviceID
	e.id.f.UserID, e.id.f.RegisteredAt = "75e5320a-7604-4b93-832b-e641eb025ca5", "2026-11-07T22:14:20Z"
	if err := e.st.saveIdentity(e.id); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { defer close(done); e.Run(ctx) }()
	defer func() { cancel(); <-done }()

	// The first answer alone does not replace the key; the loop then waits 30 s.
	waitFor(t, 5*time.Second, func() bool { return pins.Load() >= 1 })
	time.Sleep(200 * time.Millisecond)
	if in := e.Info(); in.DeviceID != oldID {
		t.Fatalf("replaced after one answer without a hint: %+v", in)
	}
	// Another id (another account's key, or an older key): ignored.
	before := pins.Load()
	e.NoteRevoked("00000000-0000-4000-8000-000000000000")
	time.Sleep(300 * time.Millisecond)
	if in := e.Info(); in.DeviceID != oldID || pins.Load() != before {
		t.Fatalf("a foreign id woke the device: %+v pins=%d", in, pins.Load())
	}
	// Our own key: replaced after the next answer, without the 30 s waits.
	e.NoteRevoked(oldID)
	waitFor(t, 5*time.Second, func() bool { return e.Info().DeviceID != oldID })
	in := e.Info()
	if in.State != StateWaitingApproval || in.Registered {
		t.Fatalf("new key not waiting: %+v", in)
	}
	jr, err := e.JoinRequestFor("75e5320a-7604-4b93-832b-e641eb025ca5")
	if err != nil {
		t.Fatal(err)
	}
	if jr.Replaces != oldID || jr.Kind != "server" || jr.DeviceID == oldID {
		t.Fatalf("join request: %+v", jr)
	}
	// Public data only.
	b, _ := json.Marshal(jr)
	e.mu.Lock()
	seed := e.id.edPriv.Seed()
	e.mu.Unlock()
	for _, bad := range []string{base64.StdEncoding.EncodeToString(seed), base64.RawURLEncoding.EncodeToString(seed), hex.EncodeToString(seed), `"seed"`} {
		if strings.Contains(string(b), bad) {
			t.Fatalf("join request carries secret material: %s", b)
		}
	}
	// A late hint for the OLD key does nothing to the new one.
	e.NoteRevoked(oldID)
	time.Sleep(200 * time.Millisecond)
	if e.Info().DeviceID != in.DeviceID {
		t.Fatal("a stale hint replaced the new key")
	}
}

func waitFor(t *testing.T, d time.Duration, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(20 * time.Millisecond)
	}
}
