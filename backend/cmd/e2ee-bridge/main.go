// Command e2ee-bridge exports the positions of Private (end-to-end encrypted)
// Orbitly circles to the user's own Dawarich, without the Orbitly server
// ever seeing plaintext. It is a `service` device member of the circle.
//
// RUN IT OFF THE OPENFAMILY SERVER HOST: whoever runs this program can read the
// circle. See README.md.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

const usageText = `e2ee-bridge - export Private (end-to-end encrypted) Orbitly circles to your own Dawarich

IMPORTANT: run this program OFF the Orbitly server host (a home server, a
NAS, a Raspberry Pi). Whoever runs it holds a circle member's keys and can read
every position of the circles it joins. Running it next to the Orbitly server
removes the point of end-to-end encryption. It never logs keys, coordinates,
tokens or passwords.

SERVER MODE (enroll --kind server, config "mode": "server"): this program is the
Orbitly server's own device. It decrypts circles whose members ALL consented on
their phones and hands the positions to the Orbitly API, so the server CAN read
them and keeps plaintext. Running it next to the server is then the point. See
docs/design/E2EE.md "Trusted-server mode".

Usage:
  e2ee-bridge enroll   --server URL --email ADDR [--totp CODE] [--name NAME] [--kind service|server]
                       step 1: create the key, log in, print the REQUEST CODE
  e2ee-bridge enroll   --approval CODE [--server URL]
                       step 2: register the key with the code the phone shows
  e2ee-bridge run      --config FILE [--once]
                       pull, verify, decrypt and push to Dawarich until stopped
  e2ee-bridge status   print the state (no secrets)
  e2ee-bridge revoke   revoke this bridge's key on the server

Common flags:
  --state-dir DIR        state directory (env E2EE_BRIDGE_STATE, default ~/.config/e2ee-bridge)
  --passphrase-file FILE seal keys/session with the passphrase in FILE
                         (env E2EE_BRIDGE_PASSPHRASE also works)

Environment: E2EE_BRIDGE_PASSWORD (Orbitly password; otherwise read from stdin),
E2EE_SERVER_INGEST_TOKEN (server mode: shared secret with the Orbitly API),
E2EE_BRIDGE_DAWARICH_KEY (main Dawarich API key).

Exit codes: 0 ok / clean shutdown, 1 error, 2 usage or config, 3 bridge revoked or
not approved (server says no_approved_device), 4 key log verification failed,
5 login expired (re-run enroll), 6 Dawarich refused the API key (server mode: the ingest token),
7 SECURITY ALARM: the server handed this key a circle-key (CK) wrap, or an SK that reuses a CK.
Exit 3 also covers: server assistance switched off in every circle this server device was reading.

LANES CIRCLES (per-member processing lanes, docs/design/PRIVACY_PROCESSING.md): the server device holds ONLY
the server key SK, never a circle key. It reads items of members whose own signed lane is "server" (checked
against the key log) and nothing else; phone-lane members' items are never decrypted. The Dawarich bridge
does the same in a circle whose server assistance is on.
`

type app struct {
	st     *store
	env    func(string) string
	stdin  io.Reader
	stdout io.Writer
	stderr io.Writer
	log    *slog.Logger
	bo     backoff
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	os.Exit(realMain(ctx, os.Args[1:], os.Getenv, os.Stdin, os.Stdout, os.Stderr))
}

func defaultStateDir(env func(string) string) string {
	if d := env("E2EE_BRIDGE_STATE"); d != "" {
		return d
	}
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".config", "e2ee-bridge")
	}
	return ".e2ee-bridge"
}

func realMain(ctx context.Context, args []string, env func(string) string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		fmt.Fprint(stdout, usageText)
		if len(args) == 0 {
			return exitUsage
		}
		return exitOK
	}
	cmd := args[0]
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() { fmt.Fprint(stderr, usageText) }
	stateDir := fs.String("state-dir", defaultStateDir(env), "state directory")
	passFile := fs.String("passphrase-file", env("E2EE_BRIDGE_PASSPHRASE_FILE"), "file holding the state passphrase")
	server := fs.String("server", "", "Orbitly server URL")
	email := fs.String("email", "", "Orbitly account email (login)")
	totp := fs.String("totp", "", "TOTP code, if the account uses one")
	name := fs.String("name", "", "display name of this bridge (max 40 chars)")
	kind := fs.String("kind", "", `enroll: "service" (Dawarich bridge, default) or "server" (the Orbitly server's own device)`)
	approval := fs.String("approval", "", "approval code from the phone")
	cfgPath := fs.String("config", "", "bridge config file (run)")
	once := fs.Bool("once", false, "run a single pass and exit")
	verbose := fs.Bool("v", false, "debug logging")
	if err := fs.Parse(args[1:]); err != nil {
		return exitUsage
	}
	switch cmd {
	case "enroll", "run", "status", "revoke":
	default:
		fmt.Fprintf(stderr, "unknown command %q\n\n%s", cmd, usageText)
		return exitUsage
	}
	lvl := slog.LevelInfo
	if *verbose {
		lvl = slog.LevelDebug
	}
	logger := slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: lvl}))

	var pass []byte
	if p := env("E2EE_BRIDGE_PASSPHRASE"); p != "" {
		pass = []byte(p)
	} else if *passFile != "" {
		b, err := os.ReadFile(*passFile)
		if err != nil {
			fmt.Fprintln(stderr, "cannot read the passphrase file:", err)
			return exitUsage
		}
		pass = []byte(strings.TrimRight(string(b), "\r\n"))
	}
	st, err := openStore(*stateDir, pass)
	if err != nil {
		fmt.Fprintln(stderr, "state directory:", err)
		return exitError
	}
	a := &app{st: st, env: env, stdin: stdin, stdout: stdout, stderr: stderr, log: logger, bo: defaultBackoff()}
	if *kind != "" && *kind != "service" && *kind != "server" {
		fmt.Fprintln(stderr, `--kind must be "service" or "server"`)
		return exitUsage
	}
	o := enrollOpts{server: *server, email: *email, totp: *totp, name: *name, approval: *approval, kind: *kind, env: env, stdin: stdin, out: stdout}

	switch cmd {
	case "enroll":
		err = a.cmdEnroll(ctx, o)
	case "revoke":
		err = a.cmdRevoke(ctx, o)
	case "status":
		err = a.cmdStatus()
	case "run":
		return a.cmdRun(ctx, *cfgPath, *once)
	}
	if err != nil {
		fmt.Fprintln(stderr, "error:", err)
		return exitCodeFor(err)
	}
	return exitOK
}

func exitCodeFor(err error) int {
	var le *logError
	switch {
	case errors.Is(err, errNoApproved), errors.Is(err, errPolicyOff):
		return exitRevoked
	case isAlarm(err):
		return exitAlarm
	case errors.As(err, &le):
		return exitLog
	case errors.Is(err, errReauth):
		return exitReauth
	case errors.Is(err, errDawarichAuth), errors.Is(err, errIngestAuth):
		return exitDawarich
	}
	return exitError
}

func (a *app) cmdStatus() error {
	pub, err := a.st.publicIdentity()
	if err != nil {
		if errors.Is(err, errNotFound) {
			fmt.Fprintln(a.stdout, "Not enrolled yet. Run `e2ee-bridge enroll`.")
			return nil
		}
		return err
	}
	w := a.stdout
	fmt.Fprintf(w, "State dir:    %s\n", a.st.dir)
	fmt.Fprintf(w, "Name:         %s\n", pub.Name)
	fmt.Fprintf(w, "Device id:    %s\n", pub.DeviceID)
	fmt.Fprintf(w, "User id:      %s\n", or(pub.UserID, "(not logged in yet)"))
	fmt.Fprintf(w, "Server:       %s\n", or(pub.Server, "(unknown)"))
	if fp, err := hexBytes(pub.Fingerprint); err == nil {
		fmt.Fprintf(w, "Fingerprint:  %s\n", e2ee.ShortFingerprint(fp))
	}
	switch {
	case pub.RevokedAt != "":
		fmt.Fprintf(w, "Registration: REVOKED at %s\n", pub.RevokedAt)
	case pub.RegisteredAt != "":
		fmt.Fprintf(w, "Registration: registered at %s (approved by phone %s)\n", pub.RegisteredAt, pub.ApprovedBy)
	default:
		fmt.Fprintln(w, "Registration: not registered (run enroll, then enroll --approval)")
	}
	fmt.Fprintf(w, "Secrets:      %s\n", map[bool]string{true: "sealed with a passphrase", false: "plain files (0600)"}[pub.Secret.Sealed != nil])
	rs, err := a.st.loadRunState()
	if err != nil {
		return err
	}
	if rs.LogSeq > 0 {
		fmt.Fprintf(w, "Pinned log:   entry %d\n", rs.LogSeq)
	} else {
		fmt.Fprintln(w, "Pinned log:   none yet")
	}
	fmt.Fprintf(w, "Last sync:    %s\n", or(rs.Stats.LastSync, "never"))
	fmt.Fprintf(w, "Points sent:  %d   items accepted: %d\n", rs.Stats.Sent, rs.Stats.Accepted)
	for circle, cur := range rs.Recv.Cursor {
		lbl := ""
		if strings.HasSuffix(circle, "#sk") {
			lbl, circle = " (server line)", strings.TrimSuffix(circle, "#sk")
		}
		fmt.Fprintf(w, "Circle %s%s: cursor %d\n", circle[:min(8, len(circle))], lbl, cur)
	}
	fmt.Fprintf(w, "Deferred items: %d\n", len(rs.Recv.Deferred))
	for k, v := range rs.Stats.Rejected {
		fmt.Fprintf(w, "Rejected %-28s %d\n", k+":", v)
	}
	for k, v := range rs.Stats.Dropped {
		fmt.Fprintf(w, "Dropped points %-22s %d\n", k+":", v)
	}
	return nil
}

func or(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

func (a *app) cmdRun(ctx context.Context, cfgPath string, once bool) int {
	fail := func(err error) int {
		fmt.Fprintln(a.stderr, "error:", err)
		return exitCodeFor(err)
	}
	if cfgPath == "" {
		fmt.Fprintln(a.stderr, "error: --config is required")
		return exitUsage
	}
	cfg, err := loadConfig(cfgPath, a.env)
	if err != nil {
		fmt.Fprintln(a.stderr, "error:", err)
		return exitUsage
	}
	id, err := a.st.loadIdentity()
	if err != nil {
		return fail(err)
	}
	if id.f.RegisteredAt == "" || id.f.RevokedAt != "" {
		return fail(errors.New("the bridge is not registered (or was revoked); run `e2ee-bridge enroll`"))
	}
	var sess session
	if err := a.st.readSecret(fileSession, &sess); err != nil || sess.RefreshToken == "" {
		return fail(errReauth)
	}
	api := newAPIClient(sess.Server, sess.RefreshToken, func(rt string) error {
		sess.RefreshToken = rt
		return a.st.writeSecret(fileSession, sess)
	})
	api.bo = a.bo
	if cfg.serverMode() != (id.kind() == "server") {
		return fail(errors.New(`config "mode" and the enrolled key disagree: server mode needs a key enrolled with --kind server, the Dawarich bridge a "service" key`))
	}
	b, err := newBridge(a.st, id, api, cfg, a.log)
	if err != nil {
		return fail(err)
	}
	b.sink.setBackoff(a.bo)
	if ss, ok := b.sink.(*serverSink); ok {
		if err := ss.pin(ctx); err != nil {
			return fail(fmt.Errorf("could not register this key as the Orbitly server device: %w", err))
		}
	}
	return b.loop(ctx, time.Duration(cfg.PollSeconds)*time.Second, once)
}

// loop runs cycles until stopped. It returns the process exit code.
func (b *bridge) loop(ctx context.Context, poll time.Duration, once bool) int {
	b.log.Info("bridge started", "device", b.id.f.DeviceID[:8], "poll", poll.String())
	failures := 0
	for {
		err := b.cycle(ctx)
		switch {
		case err == nil:
			failures = 0
		case ctx.Err() != nil:
			b.log.Info("stopping")
			_ = b.save()
			return exitOK
		case errors.Is(err, errNoApproved):
			b.log.Error("STOPPING: the server no longer lets this bridge read the circle. It was revoked or its key is not approved any more. Re-enroll if that is unexpected.", "err", err)
			return exitRevoked
		case errors.Is(err, errPolicyOff):
			b.log.Error("STOPPING: " + err.Error())
			return exitRevoked
		case isAlarm(err):
			b.log.Error("STOPPING: " + err.Error())
			return exitAlarm
		case errors.Is(err, errReauth):
			b.log.Error("STOPPING: login expired, re-run `e2ee-bridge enroll --email ...`")
			return exitReauth
		case errors.Is(err, errDawarichAuth):
			b.log.Error("STOPPING: " + err.Error())
			return exitDawarich
		case errors.Is(err, errIngestAuth):
			b.log.Error("STOPPING: " + err.Error())
			return exitDawarich
		default:
			var le *logError
			if errors.As(err, &le) {
				b.log.Error("STOPPING: " + le.Error() + " - the server may be rewriting history or showing a different log. Do not trust this server until investigated.")
				return exitLog
			}
			failures++
			b.log.Warn("cycle failed, backing off", "err", err, "failures", failures)
		}
		if once {
			if err != nil {
				return exitError
			}
			return exitOK
		}
		wait := poll
		if failures > 0 {
			wait = b.api.bo.delay(failures-1, 0)
			if wait < poll {
				wait = poll
			}
		}
		if err := sleepCtx(ctx, wait); err != nil {
			b.log.Info("stopping")
			_ = b.save()
			return exitOK
		}
	}
}
