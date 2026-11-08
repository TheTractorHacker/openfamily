package handlers

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/apkrelease"
	"github.com/TheTractorHacker/openfamily/backend/internal/compat"
	"github.com/TheTractorHacker/openfamily/backend/internal/errlog"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Check statuses for the System health checklist.
const (
	checkOK   = "ok"
	checkWarn = "warn"
	checkFail = "fail"
	checkInfo = "info" // informational or "not used": never counted as a problem
)

// SystemCheck is one row of the System health checklist. Metadata only: no
// secrets, tokens, addresses of people or coordinates ever appear here.
type SystemCheck struct {
	ID      string `json:"id"`
	Group   string `json:"group"`
	Title   string `json:"title"`
	Status  string `json:"status"`
	Summary string `json:"summary"`
	// Hint is a plain-language fix, shown for warn/fail rows.
	Hint string `json:"hint,omitempty"`
	// Link is an in-app anchor or docs URL that helps with this row.
	Link      string `json:"link,omitempty"`
	LinkLabel string `json:"link_label,omitempty"`
}

type systemChecksOut struct {
	GeneratedAt time.Time     `json:"generated_at"`
	Checks      []SystemCheck `json:"checks"`
	Counts      map[string]int `json:"counts"`
	Errors24h   struct {
		Errors   int `json:"errors"`
		Warnings int `json:"warnings"`
	} `json:"errors_24h"`
	WSClients int `json:"ws_clients"`
}

const systemCheckTimeout = 4 * time.Second

// AdminSystemChecks builds the System health checklist.
// GET /api/admin/system/checks
func (s *Server) AdminSystemChecks(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	out := s.systemChecks(ctx, r)
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) systemChecks(ctx context.Context, r *http.Request) systemChecksOut {
	now := time.Now()
	var out systemChecksOut
	out.GeneratedAt = now
	out.Counts = map[string]int{checkOK: 0, checkWarn: 0, checkFail: 0, checkInfo: 0}

	dbCtx, cancel := context.WithTimeout(ctx, systemCheckTimeout)
	defer cancel()
	var all []SystemCheck
	add := func(c ...SystemCheck) { all = append(all, c...) }

	dbOK := true
	add(s.checkDatabase(dbCtx, &dbOK))
	if dbOK {
		add(s.checkMigrations(dbCtx), s.checkClock(dbCtx, now))
	}
	add(s.checkDisk())
	if dbOK {
		add(s.checkBackup(dbCtx, now))
	}
	add(s.checkPush(dbCtx, dbOK)...)
	add(s.checkGeocoder(), s.checkSMS())
	if dbOK {
		add(s.checkServerKey(dbCtx), s.checkIngest(dbCtx, now))
	}
	n := s.hub.clientCount()
	out.WSClients = n
	add(SystemCheck{ID: "websocket", Group: "Live updates", Title: "Connected apps", Status: checkInfo,
		Summary: fmt.Sprintf("%d live connection%s right now.", n, plural(n))})
	if dbOK {
		add(s.checkQueues(dbCtx, now))
	}
	add(s.checkVersions(ctx))
	add(s.checkTLS(r))

	errs, warns := errorCounts24h(errlog.Default.Recent(100), now)
	out.Errors24h.Errors, out.Errors24h.Warnings = errs, warns
	e := SystemCheck{ID: "errors", Group: "Problems", Title: "Errors in the last 24 hours", Status: checkOK,
		Summary: "No errors recorded.", Link: "#recent-errors", LinkLabel: "See the list"}
	switch {
	case errs >= 25:
		e.Status = checkFail
		e.Summary = fmt.Sprintf("%d errors and %d warnings.", errs, warns)
		e.Hint = "Many errors in a day. Open the list below and look for a repeating message."
	case errs > 0:
		e.Status = checkWarn
		e.Summary = fmt.Sprintf("%d error%s and %d warning%s.", errs, plural(errs), warns, plural(warns))
		e.Hint = "Open the list below. A single error is often a one-off, such as a phone going offline."
	case warns > 0:
		e.Summary = fmt.Sprintf("No errors, %d warning%s.", warns, plural(warns))
	}
	add(e)

	out.Checks = all
	for _, c := range all {
		out.Counts[c.Status]++
	}
	return out
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

func errorCounts24h(entries []errlog.Entry, now time.Time) (errs, warns int) {
	for _, e := range entries {
		if now.Sub(e.Time) > 24*time.Hour {
			continue
		}
		if strings.EqualFold(e.Level, "ERROR") {
			errs++
		} else {
			warns++
		}
	}
	return
}

func (s *Server) checkDatabase(ctx context.Context, ok *bool) SystemCheck {
	c := SystemCheck{ID: "database", Group: "Server", Title: "Database"}
	var size int64
	if s.Pool == nil {
		*ok = false
		c.Status, c.Summary, c.Hint = checkFail, "Not connected.", "Check that the database container is running: docker compose ps"
		return c
	}
	if err := s.Pool.QueryRow(ctx, `SELECT pg_database_size(current_database())`).Scan(&size); err != nil {
		*ok = false
		c.Status, c.Summary = checkFail, "The database did not answer."
		c.Hint = "Check that the database container is running and healthy: docker compose ps, then docker compose logs db."
		return c
	}
	c.Status, c.Summary = checkOK, "Reachable, "+humanBytes(size)+" in use."
	return c
}

func (s *Server) checkMigrations(ctx context.Context) SystemCheck {
	c := SystemCheck{ID: "migrations", Group: "Server", Title: "Database version"}
	var ver int64
	var dirty bool
	err := s.Pool.QueryRow(ctx, `SELECT version, dirty FROM schema_migrations LIMIT 1`).Scan(&ver, &dirty)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		c.Status, c.Summary = checkWarn, "No migration is recorded yet."
		c.Hint = "Restart the server; it applies migrations on start."
	case err != nil:
		c.Status, c.Summary = checkFail, "Could not read the migration version."
		c.Hint = "Check docker compose logs api for a migration error."
	case dirty:
		c.Status, c.Summary = checkFail, fmt.Sprintf("Version %d did not finish cleanly.", ver)
		c.Hint = "A migration stopped half way. Restore the latest backup or ask for help before upgrading again; see docs/backup-restore.md."
	default:
		c.Status, c.Summary = checkOK, fmt.Sprintf("Version %d, up to date and clean.", ver)
	}
	return c
}

// checkClock compares the server clock with the database clock (same host in
// the default install; a gap points to a broken time source). The browser also
// compares generated_at with its own clock.
func (s *Server) checkClock(ctx context.Context, now time.Time) SystemCheck {
	c := SystemCheck{ID: "clock", Group: "Server", Title: "Clock"}
	var dbNow time.Time
	if err := s.Pool.QueryRow(ctx, `SELECT now()`).Scan(&dbNow); err != nil {
		c.Status, c.Summary = checkInfo, "Could not read the database clock."
		return c
	}
	skew := now.Sub(dbNow)
	if skew < 0 {
		skew = -skew
	}
	switch {
	case skew > time.Minute:
		c.Status, c.Summary = checkFail, fmt.Sprintf("The server and database clocks differ by %d seconds.", int(skew.Seconds()))
		c.Hint = "Turn on automatic time on the host (for example: sudo timedatectl set-ntp true). Wrong clocks break logins and alert times."
	case skew > 5*time.Second:
		c.Status, c.Summary = checkWarn, fmt.Sprintf("The server and database clocks differ by %d seconds.", int(skew.Seconds()))
		c.Hint = "Check that automatic time sync is on for the host."
	default:
		c.Status, c.Summary = checkOK, "In sync with the database (under 5 seconds apart)."
	}
	return c
}

// dataDirs are the container paths whose free space matters: the server
// device key and the APK cache. Empty entries are skipped.
func (s *Server) dataDirs() []string {
	dir := strings.TrimSpace(os.Getenv("OPENFAMILY_SERVER_DEVICE_DIR"))
	if dir == "" {
		dir = "/data/server-device"
	}
	return []string{dir, s.APKDir}
}

func (s *Server) checkDisk() SystemCheck {
	c := SystemCheck{ID: "disk", Group: "Server", Title: "Disk space (server data)"}
	for _, d := range s.dataDirs() {
		if d == "" {
			continue
		}
		var st syscall.Statfs_t
		if err := syscall.Statfs(d, &st); err != nil {
			continue
		}
		total := int64(st.Blocks) * int64(st.Bsize)
		free := int64(st.Bavail) * int64(st.Bsize)
		if total <= 0 {
			continue
		}
		pct := float64(free) / float64(total) * 100
		c.Summary = fmt.Sprintf("Server data volume: %s free of %s (%.0f%%). The database disk is separate; its size is shown under Database.", humanBytes(free), humanBytes(total), pct)
		switch {
		case pct < 5 || free < 200<<20:
			c.Status = checkFail
			c.Hint = "The disk is almost full. Free space (docker system prune, old backups) or enlarge the volume."
		case pct < 15:
			c.Status = checkWarn
			c.Hint = "Less than 15% is free. Plan to clean up or enlarge the volume."
		default:
			c.Status = checkOK
		}
		return c
	}
	c.Status, c.Summary = checkInfo, "Not measurable from inside the server container."
	c.Hint = "Check the host with: df -h (the database volume lives there too)."
	return c
}

func (s *Server) checkBackup(ctx context.Context, now time.Time) SystemCheck {
	c := SystemCheck{ID: "backup", Group: "Backups", Title: "Backups", Link: "#backups", LinkLabel: "Back up now"}
	var last *time.Time
	var enc bool
	var dest *string
	err := s.Pool.QueryRow(ctx, `SELECT taken_at, destination, encrypted FROM backup_runs WHERE status = 'success' ORDER BY taken_at DESC LIMIT 1`).
		Scan(&last, &dest, &enc)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		c.Status, c.Summary = checkWarn, "Could not read the backup history."
		return c
	}
	var hb *time.Time
	var schedule *string
	agentErr := s.Pool.QueryRow(ctx, `SELECT heartbeat_at, config->>'schedule' FROM backup_agent WHERE id = 1`).Scan(&hb, &schedule)
	agentUp := agentErr == nil && hb != nil && now.Sub(*hb) < 10*time.Minute
	scheduled := agentUp && schedule != nil && strings.TrimSpace(*schedule) != ""

	hb2 := backupHealth(last, nil, now, s.backupStaleAfter(ctx))
	where := ""
	if dest != nil && *dest != "" {
		where = " to " + *dest
	}
	encText := "not encrypted"
	if enc {
		encText = "encrypted"
	}
	sched := "Schedule is off."
	if scheduled {
		sched = "Schedule is on."
	} else if !agentUp {
		sched = "The backup service is not running."
	}
	switch hb2.Status {
	case "missing":
		c.Status, c.Summary = checkFail, "No backup has ever been recorded. "+sched
		c.Hint = "Start the backup service (docker compose --profile backup up -d backup), then press Back up now. Without a backup, a lost disk means lost data."
	case "stale":
		c.Status = checkWarn
		c.Summary = fmt.Sprintf("Last backup %s ago%s, %s. %s", humanAge(now.Sub(*last)), where, encText, sched)
		c.Hint = fmt.Sprintf("The newest backup is older than %d hours. Press Back up now and check that the backup service is running.", hb2.StaleAfterHours)
	default:
		c.Status = checkOK
		c.Summary = fmt.Sprintf("Last backup %s ago%s, %s. %s", humanAge(now.Sub(*last)), where, encText, sched)
		if !scheduled {
			c.Status = checkWarn
			c.Hint = "Backups only run when you press the button. Turn on a schedule in the Backups section below when you are ready."
		}
	}
	return c
}

func (s *Server) checkPush(ctx context.Context, dbOK bool) []SystemCheck {
	var out []SystemCheck
	apns := SystemCheck{ID: "push_apns", Group: "Notifications", Title: "Apple push (APNs)"}
	if s.APNsConfigured {
		apns.Status, apns.Summary = checkOK, "A key is configured."
	} else {
		apns.Status, apns.Summary = checkInfo, "Not configured. iPhones then get alerts only while the app is open or through the built-in channel."
		apns.Hint = "Only needed for iPhone families: set APNS_KEY_FILE, APNS_KEY_ID and APNS_TEAM_ID (docs/push.md)."
	}
	out = append(out, apns)

	direct := SystemCheck{ID: "push_direct", Group: "Notifications", Title: "Built-in push channel"}
	if s.Direct != nil {
		direct.Status, direct.Summary = checkOK, "On. Phones that opt in receive alerts straight from this server."
	} else {
		direct.Status, direct.Summary = checkInfo, "Off."
		direct.Hint = "Android phones then need ntfy or UnifiedPush for alerts while the app is closed (docs/push.md)."
	}
	out = append(out, direct)

	ntfy := SystemCheck{ID: "push_ntfy", Group: "Notifications", Title: "ntfy / UnifiedPush"}
	if s.NtfyBaseURL != "" {
		ntfy.Status, ntfy.Summary = checkOK, "Configured for this server."
	} else {
		ntfy.Status, ntfy.Summary = checkInfo, "Not configured."
	}
	out = append(out, ntfy)

	fcm := SystemCheck{ID: "push_fcm", Group: "Notifications", Title: "Google push (FCM)", Status: checkInfo,
		Summary: "Not used. This app has no Google services; it never needs a Firebase account."}
	out = append(out, fcm)

	if !s.APNsConfigured && s.Direct == nil && s.NtfyBaseURL == "" {
		out = append(out, SystemCheck{ID: "push_none", Group: "Notifications", Title: "Any push channel", Status: checkWarn,
			Summary: "No push channel is set up, so phones with the app closed get no alerts.",
			Hint:    "Turn on the built-in channel or set NTFY_BASE_URL (docs/push.md).", Link: "https://github.com/TheTractorHacker/orbitly/blob/main/docs/push.md", LinkLabel: "Push guide"})
	}
	return out
}

func (s *Server) checkGeocoder() SystemCheck {
	c := SystemCheck{ID: "geocoder", Group: "Optional services", Title: "Address search (geocoder)"}
	if s.Geocoder == nil {
		c.Status, c.Summary = checkInfo, "Off. Address search in the app is unavailable; maps still work."
		c.Hint = "Optional. Enable it in the server settings if families want to search for addresses."
		return c
	}
	if err := s.Geocoder.FallbackError(); err != nil {
		c.Status, c.Summary = checkWarn, "On, but the backup lookup service reports a problem."
		c.Hint = "Addresses may be found less reliably. Check the server logs for the geocoder."
		return c
	}
	c.Status, c.Summary = checkOK, "On."
	return c
}

func (s *Server) checkSMS() SystemCheck {
	c := SystemCheck{ID: "sms", Group: "Optional services", Title: "Text messages (SMS)"}
	if s.SMSEnabled() {
		c.Status, c.Summary = checkOK, "A provider is configured."
		return c
	}
	c.Status, c.Summary = checkInfo, "Not configured. Alerts still reach phones in the app; no text messages are sent."
	c.Hint = "Optional. Add Twilio details in Settings if you want text messages for SOS."
	return c
}

func (s *Server) checkServerKey(ctx context.Context) SystemCheck {
	c := SystemCheck{ID: "server_key", Group: "Privacy", Title: "Built-in server key"}
	if s.ServerDevice == nil {
		c.Status, c.Summary = checkInfo, "Off. This server does not process location for circles."
		return c
	}
	info := s.ServerDevice.Info()
	switch info.State {
	case "running":
		c.Status, c.Summary = checkOK, "Approved and running."
		if info.LastSync != "" {
			c.Summary += " Last data processed: " + info.LastSync + "."
		}
	case "idle":
		c.Status, c.Summary = checkOK, "Approved. No circle uses the server right now."
	case "waiting_for_approval":
		c.Status, c.Summary = checkWarn, "Waiting for a family admin to approve the key on their phone."
		c.Hint = "In the app: Circle settings, Server, Approve. Until then the server cannot help with places and alerts in private circles."
	case "stopped":
		c.Status, c.Summary = checkFail, "Stopped for safety (key revoked or the log does not match)."
		c.Hint = "Open Private circles in this panel and check the server key fingerprint."
	default:
		c.Status, c.Summary = checkFail, "The server key could not be loaded."
		c.Hint = "Check that the server-device volume is mounted and OPENFAMILY_DATA_KEY has not changed."
	}
	if info.StateDetail != "" && (c.Status == checkFail || c.Status == checkWarn) {
		c.Summary += " (" + info.StateDetail + ")"
	}
	return c
}

func (s *Server) checkIngest(ctx context.Context, now time.Time) SystemCheck {
	c := SystemCheck{ID: "e2ee_ingest", Group: "Privacy", Title: "Private circle activity"}
	var n int64
	var last *time.Time
	if err := s.Pool.QueryRow(ctx, `SELECT count(*), max(received_at) FROM e2ee_items WHERE received_at > now() - interval '24 hours'`).Scan(&n, &last); err != nil {
		c.Status, c.Summary = checkInfo, "Could not read activity."
		return c
	}
	if n == 0 {
		c.Status, c.Summary = checkInfo, "No private-circle data arrived in the last 24 hours."
		return c
	}
	c.Status = checkOK
	c.Summary = fmt.Sprintf("%d encrypted update%s in the last 24 hours (newest %s ago).", n, plural(int(n)), humanAge(now.Sub(*last)))
	return c
}

func (s *Server) checkQueues(ctx context.Context, now time.Time) SystemCheck {
	c := SystemCheck{ID: "queues", Group: "Live updates", Title: "Waiting work (queues)"}
	var pushQ, stuckPush, backupReq int
	e1 := s.Pool.QueryRow(ctx, `SELECT count(*), count(*) FILTER (WHERE created_at < now() - interval '15 minutes') FROM push_outbox WHERE state = 'queued' AND expires_at > now()`).Scan(&pushQ, &stuckPush)
	e2 := s.Pool.QueryRow(ctx, `SELECT count(*) FROM backup_requests WHERE status IN ('pending','running') AND requested_at < now() - interval '15 minutes'`).Scan(&backupReq)
	if e1 != nil || e2 != nil {
		c.Status, c.Summary = checkInfo, "Could not read the queues."
		return c
	}
	c.Summary = fmt.Sprintf("%d alert%s waiting to be delivered, %d older than 15 minutes.", pushQ, plural(pushQ), stuckPush)
	switch {
	case stuckPush > 0:
		c.Status = checkWarn
		c.Hint = "Alerts are waiting for phones that are offline or not connected. Check that phones can reach this server."
	case backupReq > 0:
		c.Status = checkWarn
		c.Summary += " A backup request has waited over 15 minutes."
		c.Hint = "The backup service may be stopped: docker compose --profile backup ps backup"
	default:
		c.Status = checkOK
	}
	return c
}

func (s *Server) checkVersions(ctx context.Context) SystemCheck {
	c := SystemCheck{ID: "versions", Group: "Versions", Title: "Versions"}
	pol := s.CompatPolicy(ctx)
	ver := s.BuildVersion
	if ver == "" {
		ver = "dev"
	}
	c.Status = checkOK
	c.Summary = fmt.Sprintf("Server %s. Apps from %s up to %s are supported.", ver, pol.Min, pol.Latest)
	if s.APKGitHubRepo != "" {
		res := s.releases.Get(ctx, apkrelease.Options{Repo: s.APKGitHubRepo, Token: s.APKGitHubToken}, buildsListCount, false)
		if len(res.Releases) > 0 {
			latest := strings.TrimPrefix(res.Releases[0].TagName, "v")
			c.Summary += " Newest release: " + latest + "."
			cur, ok1 := compat.Parse(strings.TrimPrefix(ver, "v"))
			lv, ok2 := compat.Parse(latest)
			if ok1 && ok2 && cur.Less(lv) && !res.Releases[0].Prerelease {
				c.Status = checkWarn
				c.Summary += " An update is available."
				c.Hint = "Upgrade on the host with ./scripts/upgrade.sh. Read the release notes first."
				c.Link, c.LinkLabel = res.Releases[0].HTMLURL, "Release notes"
			}
		} else if res.Err != nil {
			c.Summary += " Could not check for a newer release."
		}
	}
	return c
}

var (
	tlsCacheMu sync.Mutex
	tlsCache   = map[string]tlsResult{}
)

type tlsResult struct {
	at     time.Time
	expiry time.Time
	err    error
}

// checkTLS looks at how the admin reached this server and, for a public domain,
// at the certificate Caddy serves for it. The certificate lookup is cached.
func (s *Server) checkTLS(r *http.Request) SystemCheck {
	c := SystemCheck{ID: "tls", Group: "Domain and security", Title: "HTTPS and certificate"}
	host := siteHost(s.SiteAddress)
	if host == "" {
		c.Status, c.Summary = checkInfo, "No public domain is set (SITE_ADDRESS), so the server runs without HTTPS."
		c.Hint = "Fine on a home network. Phones outside your network need a domain with HTTPS."
		return c
	}
	proto := r.Header.Get("X-Forwarded-Proto")
	viaHTTPS := r.TLS != nil || proto == "https"
	res := lookupCert(host)
	switch {
	case res.err != nil:
		c.Status, c.Summary = checkWarn, "Could not read the certificate for "+host+" from here."
		c.Hint = "Open https://" + host + " in a browser. If it shows a warning, check that the domain points to this server and ports 80 and 443 are open."
	default:
		days := int(time.Until(res.expiry).Hours() / 24)
		switch {
		case days < 0:
			c.Status, c.Summary = checkFail, "The certificate for "+host+" has expired."
			c.Hint = "Restart Caddy to renew: docker compose restart caddy. Ports 80 and 443 must be reachable from the internet."
		case days < 10:
			c.Status, c.Summary = checkWarn, fmt.Sprintf("The certificate for %s expires in %d days.", host, days)
			c.Hint = "It should renew by itself. If it keeps getting closer, check docker compose logs caddy."
		default:
			c.Status, c.Summary = checkOK, fmt.Sprintf("HTTPS for %s, certificate valid for %d more days.", host, days)
		}
	}
	if c.Status == checkOK && !viaHTTPS {
		c.Status = checkWarn
		c.Summary += " You are viewing this page without HTTPS."
		c.Hint = "Use the https:// address so your password is encrypted on the way."
	}
	return c
}

func siteHost(addr string) string {
	a := strings.TrimSpace(addr)
	a = strings.TrimPrefix(strings.TrimPrefix(a, "https://"), "http://")
	if i := strings.IndexAny(a, "/"); i >= 0 {
		a = a[:i]
	}
	if h, _, err := net.SplitHostPort(a); err == nil {
		a = h
	}
	if a == "" || a == "localhost" || net.ParseIP(a) != nil || !strings.Contains(a, ".") {
		return ""
	}
	return a
}

func lookupCert(host string) tlsResult {
	tlsCacheMu.Lock()
	defer tlsCacheMu.Unlock()
	if c, ok := tlsCache[host]; ok && time.Since(c.at) < 10*time.Minute {
		return c
	}
	res := tlsResult{at: time.Now()}
	d := &net.Dialer{Timeout: 3 * time.Second}
	conn, err := tls.DialWithDialer(d, "tcp", net.JoinHostPort(host, "443"), &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12})
	if err != nil {
		// An expired certificate fails verification; retry without it to read the date.
		var cv *tls.CertificateVerificationError
		if errors.As(err, &cv) && len(cv.UnverifiedCertificates) > 0 {
			res.expiry = cv.UnverifiedCertificates[0].NotAfter
			if res.expiry.After(time.Now()) {
				res.err = err // untrusted rather than expired
			}
		} else {
			res.err = err
		}
	} else {
		if cs := conn.ConnectionState(); len(cs.PeerCertificates) > 0 {
			res.expiry = cs.PeerCertificates[0].NotAfter
		}
		conn.Close()
	}
	tlsCache[host] = res
	return res
}

func humanBytes(b int64) string {
	const k = 1024.0
	f := float64(b)
	switch {
	case f >= k*k*k*k:
		return fmt.Sprintf("%.1f TB", f/(k*k*k*k))
	case f >= k*k*k:
		return fmt.Sprintf("%.1f GB", f/(k*k*k))
	case f >= k*k:
		return fmt.Sprintf("%.0f MB", f/(k*k))
	case f >= k:
		return fmt.Sprintf("%.0f KB", f/k)
	}
	return fmt.Sprintf("%d B", b)
}

func humanAge(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "under a minute"
	case d < time.Hour:
		return fmt.Sprintf("%d min", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%d h", int(d.Hours()))
	}
	return fmt.Sprintf("%d days", int(d.Hours()/24))
}
