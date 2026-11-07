package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TheTractorHacker/openfamily/backend/internal/atrest"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/config"
	"github.com/TheTractorHacker/openfamily/backend/internal/e2eebridge"
)

// serverDeviceMode decides whether the API runs its own server device
// (docs/design/PRIVACY_PROCESSING.md section 22). OPENFAMILY_SERVER_DEVICE:
//
//	auto (default)  built in, unless the operator configured an ingest token for the separate sidecar
//	builtin         always built in
//	sidecar | off   never (the optional e2ee-server-device container, or nothing)
func serverDeviceMode(getenv func(string) string) string {
	switch m := strings.ToLower(strings.TrimSpace(getenv("OPENFAMILY_SERVER_DEVICE"))); m {
	case "builtin", "sidecar", "off":
		return m
	}
	if strings.TrimSpace(getenv("E2EE_SERVER_INGEST_TOKEN")) != "" || strings.TrimSpace(getenv("E2EE_SERVER_INGEST_TOKEN_FILE")) != "" {
		return "sidecar"
	}
	return "builtin"
}

// ingestTokenFor returns the shared token the API and its built-in device use,
// creating it once in dir (0600) when it does not exist.
func ingestTokenFor(dir string) (string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	p := filepath.Join(dir, "ingest-token")
	if b, err := os.ReadFile(p); err == nil {
		if t := strings.TrimSpace(string(b)); len(t) >= 32 {
			return t, nil
		}
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	t := hex.EncodeToString(raw)
	if err := os.WriteFile(p, []byte(t+"\n"), 0o600); err != nil {
		return "", err
	}
	return t, nil
}

// loopbackBase is where the built-in device reaches the API: itself.
func loopbackBase(cfg config.Config) (string, bool) {
	_, port, err := net.SplitHostPort(cfg.HTTPAddr)
	if err != nil || port == "" {
		port = "8080"
	}
	if cfg.TLSCertFile != "" && cfg.TLSKeyFile != "" {
		return "https://127.0.0.1:" + port, true
	}
	return "http://127.0.0.1:" + port, false
}

// startServerDevice opens the built-in device and starts its loop. It returns
// the host for the handlers, or nil when the mode is not built in. A failure
// never stops the API: the family keeps working without server processing.
func startServerDevice(ctx context.Context, cfg config.Config, pool *pgxpool.Pool, tm *auth.TokenManager) *e2eebridge.Embedded {
	mode := serverDeviceMode(os.Getenv)
	if mode != "builtin" {
		slog.Info("built-in server device not used", "mode", mode)
		return nil
	}
	dir := strings.TrimSpace(os.Getenv("OPENFAMILY_SERVER_DEVICE_DIR"))
	if dir == "" {
		dir = "/data/server-device"
	}
	tok, err := ingestTokenFor(dir)
	if err != nil {
		slog.Error("built-in server device disabled: cannot write its state directory (mount a volume at "+dir+")", "err", err)
		return nil
	}
	_ = os.Setenv("E2EE_SERVER_INGEST_TOKEN", tok) // turns the ingest endpoints on for this process only
	key, err := atrest.EnvSecret()
	if err != nil {
		slog.Error("built-in server device disabled", "err", err)
		return nil
	}
	base, insecure := loopbackBase(cfg)
	dev, err := e2eebridge.OpenEmbedded(e2eebridge.EmbeddedOptions{
		Dir: dir, DataKey: key, BaseURL: base, Insecure: insecure, Token: tok,
		MintAccess: func(ctx context.Context, userID string) (string, error) {
			var ver int
			if err := pool.QueryRow(ctx, `SELECT token_version FROM users WHERE id = $1`, userID).Scan(&ver); err != nil {
				return "", errors.New("the account the server key belongs to is gone")
			}
			return tm.IssueAccess(userID, "", ver)
		},
		Log: slog.Default(),
	})
	if err != nil {
		slog.Error("built-in server device cannot start", "err", fmt.Sprint(err))
		if dev == nil {
			return nil
		}
		return dev // reports state "error" to the admin
	}
	if dev != nil {
		go dev.Run(ctx)
	}
	return dev
}
