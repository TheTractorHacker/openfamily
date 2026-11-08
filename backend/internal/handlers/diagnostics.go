package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// "Why isn't my phone reporting?" support.
//
//   - PUT /devices/{id}/diagnostics   the phone reports its own health.
//   - GET /me/diagnostics             what the SERVER observed about the caller.
//   - GET /api/admin/fleet            the same facts for every member (admin).
//
// Everything here is metadata the server already has (timestamps, counts, OS
// states). There are no coordinates and no tokens in any of it, so the same
// payloads are safe for Private (end-to-end encrypted) circles, whose
// locations the server cannot read.

var (
	batteryOptValues = map[string]bool{"unrestricted": true, "optimized": true, "restricted": true, "unknown": true}
	locPermValues    = map[string]bool{"always": true, "while_in_use": true, "denied": true, "unknown": true}
	notifPermValues  = map[string]bool{"granted": true, "denied": true, "unknown": true}
)

type deviceDiagIn struct {
	OSVersion       string `json:"os_version"`
	BatteryOpt      string `json:"battery_opt"`
	OutboxPending   *int   `json:"outbox_pending"`
	LocPermission   string `json:"loc_permission"`
	NotifPermission string `json:"notif_permission"`
	BGService       *bool  `json:"bg_service"`
	AppVersion      string `json:"app_version"`
}

// ReportDeviceDiagnostics is PUT /devices/{id}/diagnostics. Only the owner can
// write; another user's device id is a 404.
func (s *Server) ReportDeviceDiagnostics(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "device id required")
		return
	}
	if !s.allowKey(w, "devdiag:user:"+claims.UserID, 60, time.Hour) {
		return
	}
	var in deviceDiagIn
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if in.BatteryOpt == "" {
		in.BatteryOpt = "unknown"
	}
	if in.LocPermission == "" {
		in.LocPermission = "unknown"
	}
	if in.NotifPermission == "" {
		in.NotifPermission = "unknown"
	}
	if !batteryOptValues[in.BatteryOpt] || !locPermValues[in.LocPermission] || !notifPermValues[in.NotifPermission] {
		writeError(w, http.StatusBadRequest, "unknown state value")
		return
	}
	if len(in.OSVersion) > 64 || len(in.AppVersion) > 64 {
		writeError(w, http.StatusBadRequest, "value too long")
		return
	}
	if in.OutboxPending != nil && (*in.OutboxPending < 0 || *in.OutboxPending > 100000) {
		writeError(w, http.StatusBadRequest, "outbox_pending out of range")
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `
		UPDATE devices SET os_version = NULLIF($3,''), battery_opt = $4, outbox_pending = $5,
		       loc_permission = $6, notif_permission = $7, bg_service = $8, diag_reported_at = now(),
		       app_version = COALESCE(NULLIF($9,''), app_version)
		WHERE id = $1 AND user_id = $2`,
		id, claims.UserID, in.OSVersion, in.BatteryOpt, in.OutboxPending, in.LocPermission, in.NotifPermission, in.BGService, in.AppVersion)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save diagnostics")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "device not found")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type diagDevice struct {
	ID              string     `json:"id"`
	Platform        string     `json:"platform"`
	Name            string     `json:"name"`
	AppVersion      string     `json:"app_version"`
	OSVersion       string     `json:"os_version"`
	LastSeen        *time.Time `json:"last_seen"`
	PushRegistered  bool       `json:"push_registered"`
	PushTransport   string     `json:"push_transport"`
	DirectSeenAt    *time.Time `json:"direct_seen_at"`
	LastPushOK      *time.Time `json:"last_push_ok_at"`
	LastPushFail    *time.Time `json:"last_push_fail_at"`
	BatteryOpt      string     `json:"battery_opt"`
	OutboxPending   *int       `json:"outbox_pending"`
	LocPermission   string     `json:"loc_permission"`
	NotifPermission string     `json:"notif_permission"`
	BGService       *bool      `json:"bg_service"`
	DiagReportedAt  *time.Time `json:"diag_reported_at"`
	// ClientVersion is the newest app version seen for this user on this
	// platform (app_client_versions); the fallback when AppVersion is stale.
	ClientVersion string `json:"client_version,omitempty"`
}

const diagDeviceSelect = `
	SELECT d.id::text, d.user_id::text, d.platform, COALESCE(d.name,''), COALESCE(d.app_version,''), COALESCE(d.os_version,''),
	       d.last_seen,
	       (COALESCE(d.push_token,'') <> '' OR COALESCE(d.unifiedpush_endpoint,'') <> '' OR d.push_transport = 'direct'),
	       d.push_transport, d.direct_seen_at, d.last_push_ok_at, d.last_push_fail_at,
	       COALESCE(d.battery_opt,'unknown'), d.outbox_pending, COALESCE(d.loc_permission,'unknown'),
	       COALESCE(d.notif_permission,'unknown'), d.bg_service, d.diag_reported_at
	FROM devices d `

func scanDiagDevice(row interface{ Scan(...any) error }) (uid string, d diagDevice, err error) {
	err = row.Scan(&d.ID, &uid, &d.Platform, &d.Name, &d.AppVersion, &d.OSVersion, &d.LastSeen, &d.PushRegistered,
		&d.PushTransport, &d.DirectSeenAt, &d.LastPushOK, &d.LastPushFail, &d.BatteryOpt, &d.OutboxPending,
		&d.LocPermission, &d.NotifPermission, &d.BGService, &d.DiagReportedAt)
	return
}

// GetMyDiagnostics is GET /me/diagnostics: the server's view of the caller.
func (s *Server) GetMyDiagnostics(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	ctx := r.Context()
	rows, err := s.Pool.Query(ctx, diagDeviceSelect+`WHERE d.user_id = $1 ORDER BY d.last_seen DESC NULLS LAST, d.created_at`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load devices")
		return
	}
	devs := []diagDevice{}
	for rows.Next() {
		if _, d, err := scanDiagDevice(rows); err == nil {
			devs = append(devs, d)
		}
	}
	rows.Close()

	var lastReport, lastWS *time.Time
	_ = s.Pool.QueryRow(ctx, `
		SELECT NULLIF(last_report_at, 'epoch'), last_ws_at FROM member_report_state WHERE user_id = $1`, claims.UserID).Scan(&lastReport, &lastWS)

	type circleDiag struct {
		ID           string `json:"id"`
		Name         string `json:"name"`
		Private      bool   `json:"private"`
		SilenceHours int    `json:"silence_alert_hours"`
	}
	crow, err := s.Pool.Query(ctx, `
		SELECT c.id::text, c.name, c.e2ee_mode = 'private', c.silence_alert_hours
		FROM live_circle_members m JOIN circles c ON c.id = m.circle_id
		WHERE m.user_id = $1 ORDER BY c.name`, claims.UserID)
	circs := []circleDiag{}
	if err == nil {
		for crow.Next() {
			var c circleDiag
			if crow.Scan(&c.ID, &c.Name, &c.Private, &c.SilenceHours) == nil {
				circs = append(circs, c)
			}
		}
		crow.Close()
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"server_time":    time.Now().UTC(),
		"last_report_at": lastReport,
		"last_ws_at":     lastWS,
		"devices":        devs,
		"circles":        circs,
		"push_provider":  map[string]bool{"direct": s.Direct != nil, "apns": s.APNsConfigured},
	})
}

// AdminFleetHealth is GET /api/admin/fleet (platform admin): per member, the
// liveness and health facts used to answer "why is this phone quiet?". No
// coordinates and no credentials; the same data the member sees about
// themselves.
func (s *Server) AdminFleetHealth(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	rows, err := s.Pool.Query(ctx, diagDeviceSelect+`WHERE d.hidden_at IS NULL OR d.last_seen > d.hidden_at ORDER BY d.last_seen DESC NULLS LAST LIMIT 2000`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load fleet")
		return
	}
	byUser := map[string][]diagDevice{}
	var order []string
	for rows.Next() {
		uid, d, err := scanDiagDevice(rows)
		if err != nil {
			continue
		}
		if _, ok := byUser[uid]; !ok {
			order = append(order, uid)
		}
		byUser[uid] = append(byUser[uid], d)
	}
	rows.Close()

	type member struct {
		UserID       string       `json:"user_id"`
		Name         string       `json:"name"`
		Email        string       `json:"email"`
		LastReportAt *time.Time   `json:"last_report_at"`
		LastWSAt     *time.Time   `json:"last_ws_at"`
		Private      bool         `json:"in_private_circle"`
		// LastActivityAt is the newest sign of life: the later of last_report_at,
		// last_ws_at, any device's last_seen and the last encrypted update
		// received. Private phones only show up through the last two.
		LastActivityAt *time.Time `json:"last_activity_at"`
		LastPrivateAt  *time.Time `json:"last_private_update_at"`
		Devices      []diagDevice `json:"devices"`
	}
	out := []member{}
	for _, uid := range order {
		m := member{UserID: uid, Devices: byUser[uid]}
		if err := s.Pool.QueryRow(ctx, `
			SELECT u.name, u.email, NULLIF(rs.last_report_at, 'epoch'), rs.last_ws_at,
			       EXISTS (SELECT 1 FROM live_circle_members cm JOIN circles c ON c.id = cm.circle_id
			               WHERE cm.user_id = u.id AND c.e2ee_mode = 'private')
			FROM users u LEFT JOIN member_report_state rs ON rs.user_id = u.id WHERE u.id = $1`, uid).
			Scan(&m.Name, &m.Email, &m.LastReportAt, &m.LastWSAt, &m.Private); err != nil {
			continue
		}
		_ = s.Pool.QueryRow(ctx, `
			SELECT max(i.received_at) FROM e2ee_items i JOIN device_keys k ON k.device_id = i.device_id
			WHERE k.user_id = $1`, uid).Scan(&m.LastPrivateAt)
		m.LastActivityAt = latestTime(m.LastReportAt, m.LastWSAt, m.LastPrivateAt)
		for _, d := range m.Devices {
			m.LastActivityAt = latestTime(m.LastActivityAt, d.LastSeen)
		}
		cv := map[string]string{}
		if vr, err := s.Pool.Query(ctx, `
			SELECT DISTINCT ON (platform) platform, app_version FROM app_client_versions
			WHERE user_id = $1 ORDER BY platform, last_seen DESC`, uid); err == nil {
			for vr.Next() {
				var p, v string
				if vr.Scan(&p, &v) == nil {
					cv[p] = v
				}
			}
			vr.Close()
		}
		for i := range m.Devices {
			m.Devices[i].ClientVersion = cv[m.Devices[i].Platform]
		}
		out = append(out, m)
	}
	var hidden int
	_ = s.Pool.QueryRow(ctx, `SELECT count(*) FROM devices WHERE hidden_at IS NOT NULL AND (last_seen IS NULL OR last_seen <= hidden_at)`).Scan(&hidden)
	writeJSON(w, http.StatusOK, map[string]any{"server_time": time.Now().UTC(), "members": out, "hidden_devices": hidden})
}

type staleDeviceOut struct {
	ID       string     `json:"id"`
	UserName string     `json:"user_name"`
	Platform string     `json:"platform"`
	Name     string     `json:"name"`
	LastSeen *time.Time `json:"last_seen"`
}

// AdminHideStaleDevices is POST /api/admin/fleet/hide-stale (platform admin):
// hides device rows not seen for `days` (default 7, min 1) from Fleet health.
// Nothing is deleted, so stored history stays; a hidden device that reports
// again shows up again. dry_run:true only returns the preview. Hiding a user's
// only device is never done: each user keeps their newest row.
func (s *Server) AdminHideStaleDevices(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Days   int  `json:"days"`
		DryRun bool `json:"dry_run"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Days == 0 {
		req.Days = 7
	}
	if req.Days < 1 || req.Days > 3650 {
		writeError(w, http.StatusBadRequest, "days must be between 1 and 3650")
		return
	}
	const stale = `
		FROM (
		  SELECT d.id, d.platform, COALESCE(d.name,'') AS name, d.last_seen, u.name AS uname,
		         row_number() OVER (PARTITION BY d.user_id ORDER BY d.last_seen DESC NULLS LAST, d.created_at DESC) = 1 AS newest,
		         d.hidden_at, d.created_at
		  FROM devices d JOIN users u ON u.id = d.user_id
		) x
		WHERE NOT x.newest AND COALESCE(x.last_seen, x.created_at) < now() - make_interval(days => $1)
		  AND (x.hidden_at IS NULL OR x.last_seen > x.hidden_at)`
	rows, err := s.Pool.Query(r.Context(), `SELECT x.id::text, x.uname, x.platform, x.name, x.last_seen `+stale+` ORDER BY x.last_seen NULLS FIRST LIMIT 500`, req.Days)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to preview stale devices")
		return
	}
	list := []staleDeviceOut{}
	for rows.Next() {
		var o staleDeviceOut
		if rows.Scan(&o.ID, &o.UserName, &o.Platform, &o.Name, &o.LastSeen) == nil {
			list = append(list, o)
		}
	}
	rows.Close()
	var count int
	if err := s.Pool.QueryRow(r.Context(), `SELECT count(*) `+stale, req.Days).Scan(&count); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to count stale devices")
		return
	}
	if req.DryRun {
		writeJSON(w, http.StatusOK, map[string]any{"count": count, "devices": list, "dry_run": true})
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `
		UPDATE devices SET hidden_at = now() WHERE id IN (SELECT x.id `+stale+`)`, req.Days)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to hide stale devices")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "admin.devices_hidden",
		fmt.Sprintf("hid %d device rows not seen for %d days", tag.RowsAffected(), req.Days), clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"count": tag.RowsAffected(), "hidden": tag.RowsAffected(), "dry_run": false})
}

// SendTestPush is POST /me/diagnostics/test-push: sends the caller a harmless
// notification on their own registered devices, so "do alerts reach this
// phone?" can be answered end to end. Rate limited; it only ever targets the
// caller.
func (s *Server) SendTestPush(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if !s.allowKey(w, "testpush:user:"+claims.UserID, 6, time.Hour) {
		return
	}
	if s.Push == nil {
		writeJSON(w, http.StatusOK, map[string]int{"sent": 0, "failed": 0})
		return
	}
	ctx := withPushRoute(r.Context(), "diagnostics")
	sent, failed := s.pushUsersRender(ctx, []string{claims.UserID}, fixedRender(
		"Orbitly test alert", "If you can read this, alerts reach this phone."))
	writeJSON(w, http.StatusOK, map[string]int{"sent": sent, "failed": failed})
}

// latestTime returns the latest non-nil time, or nil.
func latestTime(ts ...*time.Time) *time.Time {
	var best *time.Time
	for _, t := range ts {
		if t != nil && (best == nil || t.After(*best)) {
			best = t
		}
	}
	return best
}
