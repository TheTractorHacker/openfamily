package backup

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/backupsettings"
)

// Out of the box (nothing saved in the admin UI, no BACKUP_LOCAL_DIR) the
// compose file's BACKUP_DEFAULT_LOCAL_DIR turns on local backups.
func TestResolveConfigDefaultLocalDir(t *testing.T) {
	e := env(map[string]string{"BACKUP_DEFAULT_LOCAL_DIR": "/backups"})
	for name, st := range map[string]*backupsettings.Stored{
		"no database":   nil,
		"nothing saved": {Settings: backupsettings.Defaults()},
	} {
		c, err := ResolveConfig(e, st)
		if err != nil || c.LocalDir != "/backups" || !c.HasDestination() {
			t.Fatalf("%s: %+v %v", name, c, err)
		}
		// Not a pin: the UI may switch it off.
		if _, pinned := c.EnvPublic["BACKUP_LOCAL_DIR"]; pinned {
			t.Fatalf("%s: default must not pin the setting", name)
		}
		if c.Summary().Encryption != EncNone {
			t.Fatalf("%s: no key configured yet, got %s", name, c.Summary().Encryption)
		}
	}
	// Without the compose hint nothing changes (scripts, tests, non-compose runs).
	if c, err := ResolveConfig(env(nil), nil); err != nil || c.LocalDir != "" {
		t.Fatalf("no default dir: %+v %v", c, err)
	}
	// A saved choice wins: local switched off in the UI stays off.
	off := &backupsettings.Stored{Exists: true, Settings: backupsettings.Defaults()}
	off.Settings.LocalEnabled = false
	if c, err := ResolveConfig(e, off); err != nil || c.LocalDir != "" {
		t.Fatalf("ui off: %+v %v", c, err)
	}
	// An explicit environment value still pins.
	if c, err := ResolveConfig(env(map[string]string{"BACKUP_DEFAULT_LOCAL_DIR": "/backups", "BACKUP_LOCAL_DIR": "/elsewhere"}), off); err != nil || c.LocalDir != "/elsewhere" {
		t.Fatalf("env pin: %+v %v", c, err)
	}
}

func TestUIDefaultsHaveLocalOn(t *testing.T) {
	if !backupsettings.Defaults().LocalEnabled {
		t.Fatal("local backups must default to on")
	}
}

func TestRunOnStartModes(t *testing.T) {
	cases := map[string][2]bool{ // value -> {RunOnStart, RunOnFirstStart}
		"":      {false, false},
		"false": {false, false},
		"true":  {true, false},
		"first": {false, true},
		"FIRST": {false, true},
	}
	for v, want := range cases {
		c, err := LoadConfig(env(map[string]string{"BACKUP_RUN_ON_START": v}))
		if err != nil {
			t.Fatal(err)
		}
		if c.RunOnStart != want[0] || c.RunOnFirstStart != want[1] {
			t.Errorf("%q: got %v/%v want %v", v, c.RunOnStart, c.RunOnFirstStart, want)
		}
	}
}

func TestShouldRunOnStart(t *testing.T) {
	mk := func(first bool, dest string, has bool) *Agent {
		return &Agent{
			Runner:     &Runner{Cfg: &Config{RunOnFirstStart: first, LocalDir: dest}},
			hasSuccess: func(context.Context) bool { return has },
		}
	}
	ctx := context.Background()
	if !mk(true, "/backups", false).shouldRunOnStart(ctx) {
		t.Error("first start without any backup must run")
	}
	if mk(true, "/backups", true).shouldRunOnStart(ctx) {
		t.Error("an existing backup means no extra run on restart")
	}
	if mk(true, "", false).shouldRunOnStart(ctx) {
		t.Error("no destination: nothing to run")
	}
	if mk(false, "/backups", false).shouldRunOnStart(ctx) {
		t.Error("mode off")
	}
	always := &Agent{Runner: &Runner{Cfg: &Config{RunOnStart: true}}}
	if !always.shouldRunOnStart(ctx) {
		t.Error("BACKUP_RUN_ON_START=true always runs")
	}
}

// A folder the service cannot write gets the fix, not just "permission denied".
func TestDirStoreExplainsPermission(t *testing.T) {
	if runtime.GOOS == "windows" || os.Getuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	base := t.TempDir()
	ro := filepath.Join(base, "backups")
	if err := os.Mkdir(ro, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(ro, 0o700) })
	src := filepath.Join(base, "src")
	if err := os.WriteFile(src, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	key := "openfamily-" + time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC).Format(tsLayout) + ".dump"
	err := (&DirStore{Dir: ro}).PutFile(context.Background(), key, src)
	if err == nil || !strings.Contains(err.Error(), "not writable") || !strings.Contains(err.Error(), "chown") {
		t.Fatalf("err=%v", err)
	}
}
