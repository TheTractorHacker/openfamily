package handlers

// End-to-end encryption, phase 2: the encrypted channel of a Private circle.
//
// The server stores and relays CIPHERTEXT ONLY. A sender device seals each
// payload with the circle key on the phone (purpose "fix", "event", "place",
// "history", "checkin" or "chat") and posts a batch here; members and approved
// read-only devices (web viewer, Dawarich bridge) pull it with a cursor and get
// it live over the WebSocket as an `e2ee_item` frame. Nothing here parses,
// logs or indexes plaintext, and no coordinate can be stored (there is no
// column for one). See docs/design/E2EE.md ("Phase 2").

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/config"
	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

const (
	e2eeBatchPerUser   = 120
	e2eeBatchWindow    = time.Minute
	e2eeMaxBatchItems  = 50
	e2eeMaxBatchBody   = 2 << 20
	e2eePullPerUser    = 240
	e2eePullWindow     = time.Minute
	e2eeDefaultPull    = 100
	e2eeMaxPull        = 500
	e2eeMaxPlaceItems  = 2000 // sealed place records per circle
	e2eeDefaultLiveTTL = 48 * time.Hour
	e2eeItemsInterval  = 15 * time.Minute
	e2eeWakeEvery      = 10 * time.Second
	e2eeEraseOpPerUser = 10
)

// e2eeMaxBucket is the largest padded plaintext (a Pad bucket) per purpose.
// Live fixes, events and check-ins are tiny; places are a few KiB; a history
// chunk may be up to the Pad limit (65535 bytes of payload).
var e2eeMaxBucket = map[string]int{
	"fix": 1024, "event": 1024, "checkin": 1024, "chat": 4096, "place": 4096, "history": 69632,
}

// e2eeWakePurposes are the purposes that trigger a content-free wake-up push.
// Live fixes are not pushed (the stream carries them while a phone is open).
var e2eeWakePurposes = map[string]bool{"event": true, "checkin": true, "chat": true}

// e2eeLiveTTL is the lifetime of live-window ciphertext (fix, event).
// E2EE_LIVE_TTL_HOURS overrides it (1..720).
func e2eeLiveTTL() time.Duration {
	if v, err := strconv.Atoi(strings.TrimSpace(os.Getenv("E2EE_LIVE_TTL_HOURS"))); err == nil && v >= 1 && v <= 720 {
		return time.Duration(v) * time.Hour
	}
	return e2eeDefaultLiveTTL
}

type e2eeItemIn struct {
	Seq        int64  `json:"seq"`
	Purpose    string `json:"purpose"`
	Epoch      int    `json:"epoch"`
	SizeBucket int    `json:"size_bucket"`
	Ciphertext string `json:"ciphertext"`
}

type e2eeBatchReq struct {
	DeviceID string       `json:"sender_device_id"`
	Items    []e2eeItemIn `json:"items"`
}

type e2eeItemResult struct {
	Seq    int64  `json:"seq"`
	Status string `json:"status"` // stored | duplicate | rejected
	ID     int64  `json:"id,omitempty"`
	Error  string `json:"error,omitempty"`
}

// e2eeItemOut is the wire shape of one stored item (REST pull and WS frame).
// Deliberately no user id: the sender is the device; a client maps it to a
// person through the verified key log.
type e2eeItemOut struct {
	Type       string    `json:"type,omitempty"` // "e2ee_item" on the WebSocket
	CircleID   string    `json:"circle_id"`
	ID         int64     `json:"id"`
	DeviceID   string    `json:"device_id"`
	Seq        int64     `json:"seq"`
	Purpose    string    `json:"purpose"`
	Epoch      int       `json:"epoch"`
	SizeBucket int       `json:"size_bucket"`
	Ciphertext string    `json:"ciphertext"`
	ReceivedAt time.Time `json:"received_at"` // truncated to the minute
}

func writeE2EECode(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"error": msg, "code": code})
}

// validBucket reports whether b is a Pad bucket (256, 512, 1024, 4096, 8192, ...).
func validBucket(b int) bool {
	return b >= 256 && e2ee.PadBucket(b-2) == b
}

// ciphertextLen is the exact sealed length for a padded plaintext of bucket bytes:
// version(1) || epoch(4) || nonce(24) || ciphertext(bucket) || tag(16).
func ciphertextLen(bucket int) int { return 1 + 4 + e2ee.NonceLen + bucket + e2ee.TagLen }

// checkE2EEItem validates one item without touching the database. It returns the
// decoded ciphertext, or an error code.
func checkE2EEItem(it e2eeItemIn, currentEpoch int) ([]byte, string) {
	maxB, ok := e2eeMaxBucket[it.Purpose]
	if !ok {
		return nil, "bad_purpose"
	}
	if it.Seq <= 0 || it.Seq >= 1<<53 {
		return nil, "bad_seq"
	}
	if it.Epoch < 1 || it.Epoch > currentEpoch {
		return nil, "bad_epoch"
	}
	if !validBucket(it.SizeBucket) || it.SizeBucket > maxB {
		return nil, "bad_size_bucket"
	}
	ct, err := base64.StdEncoding.DecodeString(it.Ciphertext)
	if err != nil || len(ct) != ciphertextLen(it.SizeBucket) {
		return nil, "bad_ciphertext_length"
	}
	if ct[0] != e2ee.MsgVersion || int(binary.BigEndian.Uint32(ct[1:5])) != it.Epoch {
		return nil, "bad_header"
	}
	return ct, ""
}

// circleModes reports how many live circles of the user are private and standard.
func (s *Server) circleModes(ctx context.Context, userID string) (private, standard int, err error) {
	err = s.Pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE c.e2ee_mode = 'private'), count(*) FILTER (WHERE c.e2ee_mode <> 'private')
		FROM live_circle_members m JOIN circles c ON c.id = m.circle_id
		WHERE m.user_id = $1`, userID).Scan(&private, &standard)
	return
}

// refusePrivateOnlyPlaintext implements the downgrade rule for per-user plaintext
// location endpoints. A user whose circles are ALL private has no circle that may
// receive a plaintext position, so the write is refused (409). A user in both a
// private and a standard circle may upload plaintext, but only the standard circles
// can ever see it (circles.Authz excludes private circles from every location
// visibility check); the private circle gets sealed copies. Returns true if refused.
func (s *Server) refusePrivateOnlyPlaintext(w http.ResponseWriter, r *http.Request, userID string) bool {
	private, standard, err := s.circleModes(r.Context(), userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to check circle privacy")
		return true
	}
	if private > 0 && standard == 0 {
		writeE2EECode(w, http.StatusConflict, "e2ee_private_circle",
			"all of your circles are end-to-end encrypted; send positions through the encrypted channel")
		return true
	}
	return false
}

// circleIsPrivate reports whether the circle is in private mode.
func (s *Server) circleIsPrivate(ctx context.Context, circleID string) bool {
	if circleID == "" {
		return false
	}
	var mode string
	if err := s.Pool.QueryRow(ctx, `SELECT e2ee_mode FROM circles WHERE id = $1`, circleID).Scan(&mode); err != nil {
		return false
	}
	return mode == "private"
}

// E2EEPostBatch accepts a batch of sealed items from one of the caller's sender
// devices. POST /circles/{id}/e2ee/batch.
func (s *Server) E2EEPostBatch(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eebatch:user:"+uid, e2eeBatchPerUser, e2eeBatchWindow) {
		return
	}
	var req e2eeBatchReq
	r.Body = http.MaxBytesReader(w, r.Body, e2eeMaxBatchBody)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if e2ee.CheckID(req.DeviceID) != nil {
		writeError(w, http.StatusBadRequest, "device_id is required")
		return
	}
	if len(req.Items) == 0 || len(req.Items) > e2eeMaxBatchItems {
		writeError(w, http.StatusBadRequest, "send 1 to 50 items per batch")
		return
	}
	ctx := r.Context()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(ctx)
	// Serialise inserts per circle so cursor ids become visible in order.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "e2eeitems:"+m.CircleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store items")
		return
	}
	var mode string
	var curEpoch int
	if err := tx.QueryRow(ctx, `SELECT e2ee_mode, e2ee_epoch FROM circles WHERE id = $1`, m.CircleID).Scan(&mode, &curEpoch); err != nil {
		writeError(w, http.StatusNotFound, "circle not found")
		return
	}
	if mode != "private" {
		writeE2EECode(w, http.StatusConflict, "circle_not_private", "circle is not end-to-end encrypted")
		return
	}
	// The sender device must be the caller's own, active, allowed to upload and
	// approved in this circle. Someone else's device answers 404 (no probing).
	var owner string
	var kind string
	var canUpload, active, approved bool
	err = tx.QueryRow(ctx, `
		SELECT d.user_id::text, d.kind, d.can_upload, d.revoked_at IS NULL, `+e2eeApprovedExpr("$2")+`
		FROM device_keys d WHERE d.device_id = $1`, req.DeviceID, m.CircleID).Scan(&owner, &kind, &canUpload, &active, &approved)
	if err != nil || owner != uid {
		writeError(w, http.StatusNotFound, "device not found")
		return
	}
	if !active {
		writeE2EECode(w, http.StatusForbidden, "device_revoked", "this device key is revoked")
		return
	}
	if kind == "recovery" || !canUpload {
		writeE2EECode(w, http.StatusForbidden, "device_read_only", "this device may read but not upload")
		return
	}
	if !approved {
		writeE2EECode(w, http.StatusForbidden, "device_not_approved", "this device is not approved in this circle")
		return
	}

	var retentionDays int
	if err := tx.QueryRow(ctx, `SELECT COALESCE(location_retention_days, 0) FROM users WHERE id = $1`, uid).Scan(&retentionDays); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store items")
		return
	}
	if retentionDays <= 0 {
		retentionDays = config.LocationRetentionDays()
	}
	now := time.Now().UTC()
	coarse := now.Truncate(time.Minute)

	results := make([]e2eeItemResult, 0, len(req.Items))
	var stored []e2eeItemOut
	var wake bool
	placeCount := -1
	for _, it := range req.Items {
		ct, code := checkE2EEItem(it, curEpoch)
		if code != "" {
			results = append(results, e2eeItemResult{Seq: it.Seq, Status: "rejected", Error: code})
			continue
		}
		if it.Purpose == "place" {
			if placeCount < 0 {
				if err := tx.QueryRow(ctx, `SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND purpose = 'place'`, m.CircleID).Scan(&placeCount); err != nil {
					writeError(w, http.StatusInternalServerError, "failed to store items")
					return
				}
			}
			if placeCount >= e2eeMaxPlaceItems {
				results = append(results, e2eeItemResult{Seq: it.Seq, Status: "rejected", Error: "too_many_places"})
				continue
			}
		}
		var expires *time.Time
		switch it.Purpose {
		case "fix", "event":
			t := now.Add(e2eeLiveTTL())
			expires = &t
		case "history", "checkin", "chat":
			d := retentionDays
			if it.Purpose != "history" {
				d = int(checkinRetention / (24 * time.Hour))
			}
			t := now.AddDate(0, 0, d)
			expires = &t
		}
		var id int64
		err := tx.QueryRow(ctx, `
			INSERT INTO e2ee_items (circle_id, device_id, seq, purpose, epoch, size_bucket, ciphertext, received_at, expires_at)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
			ON CONFLICT (circle_id, device_id, seq) DO NOTHING
			RETURNING id`, m.CircleID, req.DeviceID, it.Seq, it.Purpose, it.Epoch, it.SizeBucket, ct, coarse, expires).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			results = append(results, e2eeItemResult{Seq: it.Seq, Status: "duplicate"})
			continue
		}
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to store items")
			return
		}
		if it.Purpose == "place" {
			placeCount++
		}
		results = append(results, e2eeItemResult{Seq: it.Seq, Status: "stored", ID: id})
		stored = append(stored, e2eeItemOut{Type: "e2ee_item", CircleID: m.CircleID, ID: id, DeviceID: req.DeviceID, Seq: it.Seq,
			Purpose: it.Purpose, Epoch: it.Epoch, SizeBucket: it.SizeBucket, Ciphertext: it.Ciphertext, ReceivedAt: coarse})
		if e2eeWakePurposes[it.Purpose] {
			wake = true
		}
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}

	if len(stored) > 0 {
		circleID, sender := m.CircleID, uid
		postCommitRunner.Submit(func() { s.fanOutE2EEItems(circleID, sender, stored, wake) })
	}
	status := http.StatusCreated
	if len(stored) == 0 {
		status = http.StatusOK
	}
	writeJSON(w, status, map[string]any{"results": results})
}

// fanOutE2EEItems relays stored ciphertext frames to the circle's sockets and,
// for event-like purposes, sends a content-free wake-up push. The push says only
// that something is waiting in a circle: no person, place or position.
func (s *Server) fanOutE2EEItems(circleID, senderID string, items []e2eeItemOut, wake bool) {
	if s.hub != nil {
		for _, it := range items {
			b, err := json.Marshal(it)
			if err != nil {
				continue
			}
			s.hub.broadcastCircles([]string{circleID}, "", b)
		}
	}
	if !wake || s.Push == nil {
		return
	}
	if s.LocationLimit != nil && !s.LocationLimit.Allow("e2eewake:"+circleID, 1, e2eeWakeEvery) {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text FROM live_circle_members WHERE circle_id = $1 AND user_id <> $2`, circleID, senderID)
	if err != nil {
		return
	}
	var users []string
	for rows.Next() {
		var u string
		if rows.Scan(&u) == nil {
			users = append(users, u)
		}
	}
	rows.Close()
	body, _ := json.Marshal(map[string]string{"type": "e2ee_wake", "circle_id": circleID})
	for _, u := range users {
		s.dispatchSilentCommand(ctx, "OpenFamily", body, u)
	}
}

// E2EEListItems returns ciphertext after a cursor. GET /circles/{id}/e2ee/items.
// Allowed for a live member who owns at least one ACTIVE, APPROVED key in the
// circle (any kind: phone, web viewer, service bridge). Read-only kinds pull
// exactly like phones.
func (s *Server) E2EEListItems(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eepull:user:"+uid, e2eePullPerUser, e2eePullWindow) {
		return
	}
	q := r.URL.Query()
	var after int64
	if v := q.Get("after"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			writeError(w, http.StatusBadRequest, "after must be a non-negative integer cursor")
			return
		}
		after = n
	}
	limit := e2eeDefaultPull
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			writeError(w, http.StatusBadRequest, "limit must be a positive integer")
			return
		}
		limit = min(n, e2eeMaxPull)
	}
	purposes := []string{}
	if v := q.Get("purpose"); v != "" {
		for _, p := range strings.Split(v, ",") {
			if _, ok := e2eeMaxBucket[p]; !ok {
				writeError(w, http.StatusBadRequest, "unknown purpose")
				return
			}
			purposes = append(purposes, p)
		}
	}
	devFilter := q.Get("device_id")
	if devFilter != "" && e2ee.CheckID(devFilter) != nil {
		writeError(w, http.StatusBadRequest, "bad device_id")
		return
	}
	pullDev := q.Get("as_device")
	if pullDev != "" && e2ee.CheckID(pullDev) != nil {
		writeError(w, http.StatusBadRequest, "bad as_device")
		return
	}
	ctx := r.Context()
	var mode string
	if err := s.Pool.QueryRow(ctx, `SELECT e2ee_mode FROM circles WHERE id = $1`, m.CircleID).Scan(&mode); err != nil {
		writeError(w, http.StatusNotFound, "circle not found")
		return
	}
	if mode != "private" {
		writeE2EECode(w, http.StatusConflict, "circle_not_private", "circle is not end-to-end encrypted")
		return
	}
	var okDev bool
	if err := s.Pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM device_keys d
		  WHERE d.user_id = $1 AND d.revoked_at IS NULL AND d.kind <> 'recovery'
		    AND ($3 = '' OR d.device_id::text = $3)
		    AND `+e2eeApprovedExpr("$2")+`)`, uid, m.CircleID, pullDev).Scan(&okDev); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to authorize")
		return
	}
	if !okDev {
		writeE2EECode(w, http.StatusForbidden, "no_approved_device", "no approved device key for this circle")
		return
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT id, device_id::text, seq, purpose, epoch, size_bucket, ciphertext, received_at
		FROM e2ee_items
		WHERE circle_id = $1 AND id > $2
		  AND (expires_at IS NULL OR expires_at > now())
		  AND (cardinality($3::text[]) = 0 OR purpose = ANY($3))
		  AND ($4 = '' OR device_id::text = $4)
		ORDER BY id LIMIT $5`, m.CircleID, after, purposes, devFilter, limit+1)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load items")
		return
	}
	defer rows.Close()
	out := make([]e2eeItemOut, 0, limit)
	more := false
	for rows.Next() {
		var it e2eeItemOut
		var ct []byte
		if err := rows.Scan(&it.ID, &it.DeviceID, &it.Seq, &it.Purpose, &it.Epoch, &it.SizeBucket, &ct, &it.ReceivedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load items")
			return
		}
		if len(out) == limit {
			more = true
			break
		}
		it.CircleID = m.CircleID
		it.Ciphertext = base64.StdEncoding.EncodeToString(ct)
		out = append(out, it)
	}
	next := after
	if len(out) > 0 {
		next = out[len(out)-1].ID
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": out, "next_cursor": next, "has_more": more})
}

// E2EEEraseItems deletes ciphertext. DELETE /circles/{id}/e2ee/items
//
//	default / ?scope=mine : the caller's own uploads (all their keys)
//	?scope=circle         : every item of the circle (circle admin only)
//	?purpose=a,b          : restrict to purposes;  ?before=RFC3339 : only older (by receive time)
func (s *Server) E2EEEraseItems(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeerase:user:"+uid, e2eeEraseOpPerUser, time.Minute) {
		return
	}
	q := r.URL.Query()
	scope := q.Get("scope")
	if scope == "" {
		scope = "mine"
	}
	if scope != "mine" && scope != "circle" {
		writeError(w, http.StatusBadRequest, "scope must be mine or circle")
		return
	}
	if scope == "circle" && m.Role != circles.RoleAdmin {
		writeError(w, http.StatusForbidden, "admin only")
		return
	}
	purposes := []string{}
	if v := q.Get("purpose"); v != "" {
		for _, p := range strings.Split(v, ",") {
			if _, ok := e2eeMaxBucket[p]; !ok {
				writeError(w, http.StatusBadRequest, "unknown purpose")
				return
			}
			purposes = append(purposes, p)
		}
	}
	before := time.Now().Add(time.Hour)
	if v := q.Get("before"); v != "" {
		t, err := parseRFC3339(v)
		if err != nil {
			writeError(w, http.StatusBadRequest, "before must be RFC3339")
			return
		}
		before = t
	}
	tag, err := s.Pool.Exec(r.Context(), `
		DELETE FROM e2ee_items i
		WHERE i.circle_id = $1 AND i.received_at < $2
		  AND (cardinality($3::text[]) = 0 OR i.purpose = ANY($3))
		  AND ($4 = 'circle' OR i.device_id IN (SELECT device_id FROM device_keys WHERE user_id = $5))`,
		m.CircleID, before, purposes, scope, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to erase")
		return
	}
	s.auditCircle(r.Context(), uid, m.CircleID, "e2ee.items_erased", "scope "+scope+" count "+strconv.FormatInt(tag.RowsAffected(), 10), clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"deleted": tag.RowsAffected()})
}

// eraseUserE2EELocationItems removes a user's location-bearing ciphertext in every
// circle (used by "delete my location history"). Sealed places are config, not
// a trail, and stay.
func (s *Server) eraseUserE2EELocationItems(ctx context.Context, userID string, before time.Time) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `
		DELETE FROM e2ee_items i
		USING device_keys d
		WHERE d.device_id = i.device_id AND d.user_id = $1 AND i.purpose <> 'place' AND i.received_at < $2`, userID, before)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// PurgeE2EEItems deletes expired ciphertext and, for each user with a personal
// retention window, history older than it.
func (s *Server) PurgeE2EEItems(ctx context.Context) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM e2ee_items WHERE expires_at IS NOT NULL AND expires_at < now()`)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// RunE2EEItemPurge enforces ciphertext retention until ctx is cancelled.
func (s *Server) RunE2EEItemPurge(ctx context.Context) {
	t := time.NewTicker(e2eeItemsInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if n, err := s.PurgeE2EEItems(ctx); err != nil {
				slog.Warn("e2ee item purge", "err", err)
			} else if n > 0 {
				slog.Info("e2ee item purge", "deleted", n)
			}
		}
	}
}

// E2EEPurgePlaintext removes the legacy plaintext places, geofences and bubbles
// of a circle that was switched to private, once the admin's phone has re-sealed
// them. POST /circles/{id}/e2ee/purge-plaintext (admin, private circles only).
func (s *Server) E2EEPurgePlaintext(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeadmin:user:"+uid, e2eeAdminOpPerUser, e2eeAdminOpWindow) {
		return
	}
	ctx := r.Context()
	if !s.circleIsPrivate(ctx, m.CircleID) {
		writeE2EECode(w, http.StatusConflict, "circle_not_private", "circle is not end-to-end encrypted")
		return
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(ctx)
	counts := map[string]int64{}
	for name, sql := range map[string]string{
		"bubbles":   `DELETE FROM bubbles WHERE circle_id = $1`,
		"geofences": `DELETE FROM geofences WHERE family_id = $1`,
		"places":    `DELETE FROM places WHERE COALESCE(circle_id, family_id) = $1`,
	} {
		tag, err := tx.Exec(ctx, sql, m.CircleID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to purge")
			return
		}
		counts[name] = tag.RowsAffected()
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.auditCircle(ctx, uid, m.CircleID, "e2ee.plaintext_purged", "legacy plaintext places removed", clientIP(r))
	writeJSON(w, http.StatusOK, counts)
}

// refuseIfPrivateCircle answers 409 when any of the circles is in private mode:
// the downgrade rule for endpoints that would store a plaintext position or
// place for that circle. Empty ids are ignored.
func (s *Server) refuseIfPrivateCircle(w http.ResponseWriter, ctx context.Context, circleIDs ...string) bool {
	for _, id := range circleIDs {
		if id != "" && s.circleIsPrivate(ctx, id) {
			writeE2EECode(w, http.StatusConflict, "e2ee_private_circle",
				"this circle is end-to-end encrypted; places and positions are stored as encrypted items by the phones")
			return true
		}
	}
	return false
}

// placePrivate reports whether an existing place belongs to a private circle.
func (s *Server) placePrivate(ctx context.Context, placeID string) bool {
	var private bool
	err := s.Pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM places p JOIN circles c ON c.id = COALESCE(p.circle_id, p.family_id)
		               WHERE p.id::text = $1 AND c.e2ee_mode = 'private')`, placeID).Scan(&private)
	return err == nil && private
}
