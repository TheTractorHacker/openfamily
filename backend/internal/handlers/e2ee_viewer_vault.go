package handlers

// Web access from any browser: the account-bound viewer vault
// (docs/design/WEB_VIEWER_ANYWHERE.md).
//
// The server stores, per account, one opaque blob: a web viewer key (an
// ordinary `web` device key, registered and cross-signed by a phone exactly as
// before) sealed in the browser under a key stretched from the owner's vault
// passphrase. The server never sees the passphrase, the key or a circle key,
// and nothing here changes the key log or any trust rule: the blob only lets the
// owner carry the SAME approved viewer key from one browser to another.
//
// What the server adds: a pepper (a random file outside the database) mixed
// into the browser's key derivation, so a stolen database alone is not enough
// to start guessing the passphrase; a step-up (password + 2FA) before the blob
// is released; rate limits; audit entries; and a push to the owner's phones
// when a browser that never unlocked the vault before does so.

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

const (
	viewerVaultMaxBlob     = 8 << 10
	viewerVaultMaxPin      = 1 << 10
	viewerVaultTicketTTL   = 10 * time.Minute
	viewerVaultUnlockPerHr = 10
	viewerVaultWritePerHr  = 30
	viewerVaultPinPerMin   = 30
)

// ViewerVaultConfig is set by main from the environment.
type ViewerVaultConfig struct {
	// Off is the operator's hard switch (E2EE_VIEWER_VAULT=off).
	Off bool
	// Pepper is the content of the pepper file (nil: unavailable, feature off).
	Pepper []byte
	// PepperErr explains why Pepper is nil (shown to admins, never secret).
	PepperErr string
}

type vaultTicket struct {
	uid string
	exp time.Time
}

// viewerVaultTickets: one-time permissions to save a blob, issued by a
// successful step-up so a save needs no second 2FA code.
type viewerVaultTickets struct {
	mu sync.Mutex
	m  map[string]vaultTicket
}

func (t *viewerVaultTickets) issue(uid string) string {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return ""
	}
	tok := base64.RawURLEncoding.EncodeToString(raw)
	h := sha256.Sum256([]byte(tok))
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.m == nil {
		t.m = map[string]vaultTicket{}
	}
	now := time.Now()
	for k, v := range t.m {
		if now.After(v.exp) {
			delete(t.m, k)
		}
	}
	t.m[hex.EncodeToString(h[:])] = vaultTicket{uid: uid, exp: now.Add(viewerVaultTicketTTL)}
	return tok
}

// take consumes a ticket; it is valid once, for its own user, before expiry.
func (t *viewerVaultTickets) take(uid, tok string) bool {
	if tok == "" {
		return false
	}
	h := sha256.Sum256([]byte(tok))
	k := hex.EncodeToString(h[:])
	t.mu.Lock()
	defer t.mu.Unlock()
	v, ok := t.m[k]
	if !ok {
		return false
	}
	delete(t.m, k)
	return v.uid == uid && time.Now().Before(v.exp)
}

// LoadViewerVaultPepper reads the pepper file, creating it (32 random bytes,
// hex, mode 0600) when it does not exist. The file must live OUTSIDE the
// database and its backups; losing it makes every vault unopenable (the owner
// then sets web access up again from a phone).
func LoadViewerVaultPepper(path string) ([]byte, error) {
	if b, err := os.ReadFile(path); err == nil {
		raw, derr := hex.DecodeString(strings.TrimSpace(string(b)))
		if derr != nil || len(raw) < 32 {
			return nil, errors.New("the viewer vault pepper file is not 32+ bytes of hex")
		}
		return raw, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrExist) { // a concurrent start wrote it first
			return LoadViewerVaultPepper(path)
		}
		return nil, err
	}
	if _, err := f.WriteString(hex.EncodeToString(raw) + "\n"); err != nil {
		f.Close()
		return nil, err
	}
	if err := f.Close(); err != nil {
		return nil, err
	}
	return raw, nil
}

func (s *Server) pepperFor(uid string) []byte {
	m := hmac.New(sha256.New, s.ViewerVault.Pepper)
	m.Write([]byte("OFE2EE-AVAULT1-PEPPER\x00"))
	m.Write([]byte(uid))
	return m.Sum(nil)
}

func (s *Server) pepperID() string {
	if len(s.ViewerVault.Pepper) == 0 {
		return ""
	}
	m := hmac.New(sha256.New, s.ViewerVault.Pepper)
	m.Write([]byte("OFE2EE-AVAULT1-PEPPER-ID"))
	return hex.EncodeToString(m.Sum(nil))[:16]
}

func (s *Server) viewerVaultSetting(ctx context.Context) bool {
	var v bool
	if err := s.Pool.QueryRow(ctx, `SELECT e2ee_viewer_vault_enabled FROM app_theme_settings WHERE id = 1`).Scan(&v); err != nil {
		return true // the column defaults to on; a missing settings row is not an off switch
	}
	return v
}

// viewerVaultReason returns "" when the caller may use the vault, else why not.
func (s *Server) viewerVaultReason(ctx context.Context, uid string) string {
	switch {
	case s.ViewerVault.Off:
		return "off_by_operator"
	case len(s.ViewerVault.Pepper) == 0:
		return "pepper_unavailable"
	case !s.viewerVaultSetting(ctx):
		return "off_in_settings"
	case !s.isPlatformAdmin(ctx, uid):
		return "admins_only"
	}
	return ""
}

// viewerVaultGate writes 404 (feature unknown to this caller) unless usable.
func (s *Server) viewerVaultGate(w http.ResponseWriter, r *http.Request) (string, bool) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return "", false
	}
	if why := s.viewerVaultReason(r.Context(), uid); why != "" {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "web access from any browser is not available", "code": "viewer_vault_" + why})
		return "", false
	}
	return uid, true
}

type viewerVaultRow struct {
	deviceID  string
	blob      json.RawMessage
	pin       json.RawMessage
	pinSeq    int64
	pepperID  string
	created   time.Time
	updated   time.Time
	lastOpen  *time.Time
	keyActive bool
}

func (s *Server) loadViewerVault(ctx context.Context, uid string) (*viewerVaultRow, error) {
	var v viewerVaultRow
	err := s.Pool.QueryRow(ctx, `
		SELECT v.device_id::text, v.blob, v.pin, v.pin_seq, v.pepper_id, v.created_at, v.updated_at, v.last_opened_at,
		       (k.revoked_at IS NULL AND k.kind = 'web' AND k.user_id = v.user_id)
		FROM e2ee_viewer_vaults v JOIN device_keys k ON k.device_id = v.device_id
		WHERE v.user_id = $1`, uid).Scan(&v.deviceID, &v.blob, &v.pin, &v.pinSeq, &v.pepperID, &v.created, &v.updated, &v.lastOpen, &v.keyActive)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &v, nil
}

// E2EEViewerVaultStatus: GET /e2ee/viewer-vault. Never returns the blob.
func (s *Server) E2EEViewerVaultStatus(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeread:user:"+uid, e2eeReadPerUser, e2eeReadWindow) {
		return
	}
	why := s.viewerVaultReason(r.Context(), uid)
	out := map[string]any{"available": why == "", "reason": why, "exists": false}
	if why == "admins_only" {
		writeJSON(w, http.StatusOK, out)
		return
	}
	v, err := s.loadViewerVault(r.Context(), uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load web access")
		return
	}
	if v != nil {
		out["exists"] = true
		out["device_id"] = v.deviceID
		out["created_at"] = v.created
		out["updated_at"] = v.updated
		out["last_opened_at"] = v.lastOpen
		out["pepper_changed"] = v.pepperID != s.pepperID()
		out["key_active"] = v.keyActive
	}
	writeJSON(w, http.StatusOK, out)
}

type viewerVaultUnlockReq struct {
	stepUpFields
	// BrowserID is a random id this browser keeps (not secret); only its hash is stored.
	BrowserID string `json:"browser_id"`
}

// E2EEViewerVaultUnlock: POST /e2ee/viewer-vault/unlock. Step-up, then the blob
// (if any), its sealed pin, this account's pepper and a one-time save ticket.
func (s *Server) E2EEViewerVaultUnlock(w http.ResponseWriter, r *http.Request) {
	uid, ok := s.viewerVaultGate(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "vvault:unlock:"+uid, viewerVaultUnlockPerHr, time.Hour) {
		return
	}
	var req viewerVaultUnlockReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if !s.stepUp(w, r, uid, req.Password, req.TOTPCode) {
		return
	}
	ctx := r.Context()
	v, err := s.loadViewerVault(ctx, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load web access")
		return
	}
	out := map[string]any{
		"pepper":    base64.StdEncoding.EncodeToString(s.pepperFor(uid)),
		"ticket":    s.viewerVaultTickets.issue(uid),
		"blob":      nil,
		"pin":       nil,
		"device_id": nil,
	}
	if v != nil {
		if v.pepperID != s.pepperID() {
			writeJSON(w, http.StatusConflict, map[string]any{"error": "the server's vault key file changed since web access was set up; set it up again", "code": "viewer_vault_pepper_changed"})
			return
		}
		if !v.keyActive {
			writeJSON(w, http.StatusConflict, map[string]any{"error": "the web access key was revoked; set it up again", "code": "viewer_vault_key_revoked"})
			return
		}
		out["blob"] = v.blob
		if len(v.pin) > 0 {
			out["pin"] = v.pin
		}
		out["device_id"] = v.deviceID
		_, _ = s.Pool.Exec(ctx, `UPDATE e2ee_viewer_vaults SET last_opened_at = now() WHERE user_id = $1`, uid)
		s.logAudit(ctx, uid, "", "e2ee.viewer_vault_opened", "web access vault released after re-authentication", clientIP(r))
		s.noteViewerVaultBrowser(ctx, uid, req.BrowserID)
	}
	writeJSON(w, http.StatusOK, out)
}

// noteViewerVaultBrowser records the browser and pushes a notice to the owner's
// phones the first time a browser unlocks (owner decision D5).
func (s *Server) noteViewerVaultBrowser(ctx context.Context, uid, browserID string) {
	id := strings.TrimSpace(browserID)
	if len(id) < 16 || len(id) > 128 {
		id = "" // no id: treat as a new browser every time (and do not store)
	}
	isNew := true
	if id != "" {
		h := sha256.Sum256([]byte("OFE2EE-AVAULT1-BROWSER\x00" + uid + "\x00" + id))
		var inserted bool
		err := s.Pool.QueryRow(ctx, `
			INSERT INTO e2ee_viewer_vault_browsers (user_id, browser) VALUES ($1, $2)
			ON CONFLICT (user_id, browser) DO UPDATE SET last_seen = now()
			RETURNING (xmax = 0)`, uid, hex.EncodeToString(h[:])).Scan(&inserted)
		if err != nil {
			slog.Warn("viewer vault: record browser", "err", err)
		} else {
			isNew = inserted
		}
	}
	if !isNew {
		return
	}
	s.logAudit(ctx, uid, "", "e2ee.viewer_vault_new_browser", "web access unlocked in a browser not seen before", "")
	if s.Push != nil {
		go s.pushUsers(context.WithoutCancel(ctx), []string{uid}, "Private circles opened in a new browser",
			"Web access was unlocked in a browser that never used it before. If this was not you, revoke the web viewer on your phone and change your password.")
	}
}

type viewerVaultBlob struct {
	V         int               `json:"v"`
	UserID    string            `json:"user_id"`
	DeviceID  string            `json:"device_id"`
	Unlockers []json.RawMessage `json:"unlockers"`
	Nonce     string            `json:"nonce"`
	Sealed    string            `json:"sealed"`
}

type viewerVaultPutReq struct {
	Ticket string          `json:"ticket"`
	Blob   json.RawMessage `json:"blob"`
}

// E2EEViewerVaultPut: PUT /e2ee/viewer-vault. Saves (or replaces) the blob. Needs
// a ticket from a step-up in the last 10 minutes; the blob must name the caller
// and one of the caller's ACTIVE web keys. The server checks shape only.
func (s *Server) E2EEViewerVaultPut(w http.ResponseWriter, r *http.Request) {
	uid, ok := s.viewerVaultGate(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "vvault:write:"+uid, viewerVaultWritePerHr, time.Hour) {
		return
	}
	var req viewerVaultPutReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, viewerVaultMaxBlob+1024)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if !s.viewerVaultTickets.take(uid, req.Ticket) {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": "confirm your password again", "code": "viewer_vault_reauth"})
		return
	}
	var compact bytes.Buffer
	if len(req.Blob) == 0 || json.Compact(&compact, req.Blob) != nil || compact.Len() > viewerVaultMaxBlob {
		writeError(w, http.StatusBadRequest, "blob must be a JSON object of at most 8 KiB")
		return
	}
	var b viewerVaultBlob
	if err := json.Unmarshal(compact.Bytes(), &b); err != nil || b.V != 1 || b.UserID != uid || e2ee.CheckID(b.DeviceID) != nil ||
		len(b.Unlockers) == 0 || len(b.Unlockers) > 4 || b.Nonce == "" || b.Sealed == "" {
		writeError(w, http.StatusBadRequest, "not a viewer vault for this account")
		return
	}
	ctx := r.Context()
	var kind string
	var active bool
	err := s.Pool.QueryRow(ctx, `SELECT kind, revoked_at IS NULL FROM device_keys WHERE device_id = $1 AND user_id = $2`, b.DeviceID, uid).Scan(&kind, &active)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (!active || kind != "web")) {
		writeError(w, http.StatusBadRequest, "the vault must hold one of your active web viewer keys")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to check the key")
		return
	}
	// A new key starts a new pin history; the same key keeps its pin.
	if _, err := s.Pool.Exec(ctx, `
		INSERT INTO e2ee_viewer_vaults (user_id, device_id, blob, pepper_id) VALUES ($1, $2, $3, $4)
		ON CONFLICT (user_id) DO UPDATE SET
			blob = EXCLUDED.blob, pepper_id = EXCLUDED.pepper_id, updated_at = now(),
			pin = CASE WHEN e2ee_viewer_vaults.device_id = EXCLUDED.device_id THEN e2ee_viewer_vaults.pin END,
			pin_seq = CASE WHEN e2ee_viewer_vaults.device_id = EXCLUDED.device_id THEN e2ee_viewer_vaults.pin_seq ELSE 0 END,
			device_id = EXCLUDED.device_id`,
		uid, b.DeviceID, compact.Bytes(), s.pepperID()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save web access")
		return
	}
	s.logAudit(ctx, uid, "", "e2ee.viewer_vault_saved", "web access vault saved (sealed in the browser)", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"saved": true, "device_id": b.DeviceID})
}

// E2EEViewerVaultPin: PUT /e2ee/viewer-vault/pin. Stores the sealed key-log head;
// the public seq may only grow (an older pin can never replace a newer one).
func (s *Server) E2EEViewerVaultPin(w http.ResponseWriter, r *http.Request) {
	uid, ok := s.viewerVaultGate(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "vvault:pin:"+uid, viewerVaultPinPerMin, time.Minute) {
		return
	}
	var req struct {
		Pin json.RawMessage `json:"pin"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, viewerVaultMaxPin+256)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	var compact bytes.Buffer
	var p struct {
		V      int    `json:"v"`
		Seq    int64  `json:"seq"`
		Nonce  string `json:"nonce"`
		Sealed string `json:"sealed"`
	}
	if len(req.Pin) == 0 || json.Compact(&compact, req.Pin) != nil || compact.Len() > viewerVaultMaxPin ||
		json.Unmarshal(compact.Bytes(), &p) != nil || p.V != 1 || p.Seq < 1 || p.Nonce == "" || p.Sealed == "" {
		writeError(w, http.StatusBadRequest, "invalid pin")
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `UPDATE e2ee_viewer_vaults SET pin = $2, pin_seq = $3 WHERE user_id = $1 AND pin_seq < $3`,
		uid, compact.Bytes(), p.Seq)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"stored": tag.RowsAffected() == 1})
}

// E2EEViewerVaultDelete: DELETE /e2ee/viewer-vault. Removes the stored blob (the
// key itself is revoked separately, from a phone or the unlocked browser).
// Deleting only ever reduces access, so it needs no step-up and works even
// when the feature is switched off.
func (s *Server) E2EEViewerVaultDelete(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `DELETE FROM e2ee_viewer_vaults WHERE user_id = $1`, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete")
		return
	}
	if tag.RowsAffected() > 0 {
		s.logAudit(r.Context(), uid, "", "e2ee.viewer_vault_deleted", "web access vault deleted", clientIP(r))
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": tag.RowsAffected() > 0})
}

func (s *Server) viewerVaultAdminJSON(ctx context.Context) map[string]any {
	var vaults int
	_ = s.Pool.QueryRow(ctx, `SELECT count(*) FROM e2ee_viewer_vaults`).Scan(&vaults)
	return map[string]any{
		"enabled":          s.viewerVaultSetting(ctx),
		"off_by_operator":  s.ViewerVault.Off,
		"pepper_available": len(s.ViewerVault.Pepper) > 0,
		"pepper_error":     s.ViewerVault.PepperErr,
		"vaults":           vaults,
	}
}

// AdminGetViewerVault: GET /api/admin/settings/e2ee-viewer-vault
func (s *Server) AdminGetViewerVault(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.viewerVaultAdminJSON(r.Context()))
}

// AdminPutViewerVault: PUT /api/admin/settings/e2ee-viewer-vault {enabled}.
// Turning it off stops every unlock and save at once; stored vaults stay
// (sealed, useless without the passphrase) until their owners delete them.
func (s *Server) AdminPutViewerVault(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Enabled *bool `json:"enabled"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil || req.Enabled == nil {
		writeError(w, http.StatusBadRequest, "enabled (true or false) is required")
		return
	}
	if _, err := s.Pool.Exec(r.Context(),
		`UPDATE app_theme_settings SET e2ee_viewer_vault_enabled = $1, updated_at = now() WHERE id = 1`, *req.Enabled); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save setting")
		return
	}
	detail := "turned web access from any browser off"
	if *req.Enabled {
		detail = "turned web access from any browser on"
	}
	s.logAudit(r.Context(), claims.UserID, "", "admin.e2ee_viewer_vault_changed", detail, clientIP(r))
	writeJSON(w, http.StatusOK, s.viewerVaultAdminJSON(r.Context()))
}
