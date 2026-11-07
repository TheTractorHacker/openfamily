package handlers

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/atrest"
	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Home Assistant integration tokens (docs/integrations/home-assistant.md).
//
// A token is a read-only, revocable credential owned by one user and limited
// to scopes and circles chosen at creation. It sees at most what its owner
// sees as a circle member (never platform-admin powers, so ADMIN_LOCATION_ACCESS
// is neither needed nor bypassed), and nothing at all for a Private (E2EE)
// circle unless the circle is in trusted-server mode.

const (
	haTokenPrefix = "ofha_"
	haTokenBytes  = 32
	// haTokenLen = len("ofha_") + 43 base64url characters.
	haTokenLen = 5 + 43

	haMaxActiveTokens  = 10
	haMaxCirclesPerTok = 20
	haCreatePerHour    = 10
	haManagePerMin     = 60
	haTestPerMin       = 6
	haAPIPerMin        = 120 // per token
	haBadTokenPerIP    = 30  // bad-token lookups per 15 minutes per address
	haBadTokenWindow   = 15 * time.Minute
	haUsedThrottle     = time.Minute
	haReadAuditEvery   = 15 * time.Minute

	haStateUnavailablePrivate = "unavailable_private_circle"
	haStateSharingOff         = "sharing_off"
)

// Scopes. All are read scopes; there is no write scope.
const (
	haScopePresence = "presence" // state, battery, speed, last seen
	haScopeLocation = "location" // lat/lon/accuracy (implies presence)
	haScopePlaces   = "places"   // list of places (zones)
	haScopeEvents   = "events"   // webhook + events feed + SOS/crash flags
	haScopeDriving  = "driving"  // 24 h driving summaries, trip events
)

var haAllScopes = []string{haScopePresence, haScopeLocation, haScopePlaces, haScopeEvents, haScopeDriving}

// Event kinds a webhook can receive.
var haEventKinds = []string{"arrival", "departure", "sos", "crash", "trip_start", "trip_end", "low_battery"}

var haTokenRe = regexp.MustCompile(`^ofha_[A-Za-z0-9_-]{43}$`)

// haOwnerOKSQL: the token's owner must still be an adult account (not a child)
// and must not have had a credential event since the token was minted
// (password change/reset, logout everywhere, TOTP change bump token_version).
const haOwnerOKSQL = `EXISTS (SELECT 1 FROM users ou WHERE ou.id = ha_integrations.user_id
	AND ou.role IN ('admin', 'member') AND ou.token_version = ha_integrations.owner_token_version)`

func haHashToken(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}

func haNewToken() (string, error) {
	b := make([]byte, haTokenBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return haTokenPrefix + base64.RawURLEncoding.EncodeToString(b), nil
}

func haNewSecret() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// haIntegration is the loaded token row (never contains the token itself).
type haIntegration struct {
	ID, UserID, Name string
	Scopes           []string
	CircleIDs        []string
	CreatedAt        time.Time
	LastUsedAt       *time.Time

	WebhookURL, WebhookSecret string
	AllowPrivate              bool
	WebhookEvents             []string
	WebhookCursor             int64
	WebhookFailures           int

	LastDeliveryAt    *time.Time
	LastDeliveryOK    *bool
	LastDeliveryCode  *int
	LastDeliveryError string
	LastDeliveryEvent string
}

func (i *haIntegration) has(scope string) bool {
	for _, s := range i.Scopes {
		if s == scope {
			return true
		}
	}
	return false
}

const haCols = `id::text, user_id::text, name, scopes, circle_ids::text[], created_at, last_used_at,
	webhook_url, webhook_secret, webhook_allow_private, webhook_events, webhook_cursor, webhook_failures,
	last_delivery_at, last_delivery_ok, last_delivery_code, last_delivery_error, last_delivery_event`

func scanHA(row pgx.Row) (*haIntegration, error) {
	var i haIntegration
	err := row.Scan(&i.ID, &i.UserID, &i.Name, &i.Scopes, &i.CircleIDs, &i.CreatedAt, &i.LastUsedAt,
		&i.WebhookURL, &i.WebhookSecret, &i.AllowPrivate, &i.WebhookEvents, &i.WebhookCursor, &i.WebhookFailures,
		&i.LastDeliveryAt, &i.LastDeliveryOK, &i.LastDeliveryCode, &i.LastDeliveryError, &i.LastDeliveryEvent)
	if err == nil {
		err = i.openSecret()
	}
	return &i, err
}

const haSecretLabel = "ha_integrations.webhook_secret"

// openSecret turns the stored webhook secret (sealed when OPENFAMILY_DATA_KEY is
// configured, plaintext otherwise or on older rows) into the usable value.
func (i *haIntegration) openSecret() error {
	v, err := atrest.Open(haSecretLabel, i.WebhookSecret)
	if err != nil {
		return err
	}
	i.WebhookSecret = v
	return nil
}

func haSealSecret(v string) string {
	out, err := atrest.Seal(haSecretLabel, v)
	if err != nil {
		return v
	}
	return out
}

// haTokenJSON is the management representation. The token and webhook secret
// appear only in the response that created or rotated them.
type haTokenJSON struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	TokenHint  string     `json:"token_hint"`
	Scopes     []string   `json:"scopes"`
	CircleIDs  []string   `json:"circle_ids"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at"`

	WebhookConfigured bool       `json:"webhook_configured"`
	WebhookURLMasked  string     `json:"webhook_url_masked"`
	WebhookAllowPriv  bool       `json:"webhook_allow_private"`
	WebhookEvents     []string   `json:"webhook_events"`
	WebhookFailures   int        `json:"webhook_failures"`
	LastDeliveryAt    *time.Time `json:"last_delivery_at"`
	LastDeliveryOK    *bool      `json:"last_delivery_ok"`
	LastDeliveryCode  *int       `json:"last_delivery_code"`
	LastDeliveryError string     `json:"last_delivery_error"`
	LastDeliveryEvent string     `json:"last_delivery_event"`

	Token         string `json:"token,omitempty"`
	WebhookSecret string `json:"webhook_secret,omitempty"`
}

func (i *haIntegration) json(hint string) haTokenJSON {
	ev := i.WebhookEvents
	if len(ev) == 0 {
		ev = haEventKinds
	}
	return haTokenJSON{
		ID: i.ID, Name: i.Name, TokenHint: hint, Scopes: i.Scopes, CircleIDs: i.CircleIDs,
		CreatedAt: i.CreatedAt, LastUsedAt: i.LastUsedAt,
		WebhookConfigured: i.WebhookURL != "", WebhookURLMasked: haMaskURL(i.WebhookURL),
		WebhookAllowPriv: i.AllowPrivate, WebhookEvents: ev, WebhookFailures: i.WebhookFailures,
		LastDeliveryAt: i.LastDeliveryAt, LastDeliveryOK: i.LastDeliveryOK, LastDeliveryCode: i.LastDeliveryCode,
		LastDeliveryError: i.LastDeliveryError, LastDeliveryEvent: i.LastDeliveryEvent,
	}
}

// ---- management (user session) --------------------------------------------

func (s *Server) haAudit(r *http.Request, userID, action, detail string) {
	s.auditSharing(r, userID, action, detail)
}

// CreateHAToken mints a token: {"name","scopes"?,"circle_ids"}.
func (s *Server) CreateHAToken(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Name      string   `json:"name"`
		Scopes    []string `json:"scopes"`
		CircleIDs []string `json:"circle_ids"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" || len([]rune(name)) > 60 {
		writeError(w, http.StatusBadRequest, "name must be 1-60 characters")
		return
	}
	scopes, bad := haNormalizeScopes(req.Scopes)
	if bad != "" {
		writeError(w, http.StatusBadRequest, "unknown scope: "+bad)
		return
	}
	if len(req.CircleIDs) == 0 || len(req.CircleIDs) > haMaxCirclesPerTok {
		writeError(w, http.StatusBadRequest, "choose between 1 and 20 circles")
		return
	}
	can, err := s.userCanManage(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load role")
		return
	}
	if !can {
		writeError(w, http.StatusForbidden, "child accounts cannot create integration tokens")
		return
	}
	// Every circle must be one the caller is a live member of; anything else is
	// a uniform 404 (no probing of other people's circle ids).
	az := circles.New(s.Pool)
	seen := map[string]bool{}
	var ids []string
	for _, id := range req.CircleIDs {
		id = strings.ToLower(strings.TrimSpace(id))
		if seen[id] {
			continue
		}
		if _, err := az.RequireMember(r.Context(), claims.UserID, id); err != nil {
			if errors.Is(err, circles.ErrNotFound) {
				writeError(w, http.StatusNotFound, "circle not found")
				return
			}
			writeError(w, http.StatusInternalServerError, "failed to check circle")
			return
		}
		seen[id] = true
		ids = append(ids, id)
	}
	if !s.allowKey(w, "ha:create:"+claims.UserID, haCreatePerHour, time.Hour) {
		return
	}
	token, err := haNewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create token")
		return
	}
	secret, err := haNewSecret()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create token")
		return
	}
	hint := "…" + token[len(token)-4:]
	row := s.Pool.QueryRow(r.Context(), `
		INSERT INTO ha_integrations (user_id, name, token_hash, token_hint, scopes, circle_ids, webhook_secret, owner_token_version)
		SELECT $1, $2, $3, $4, $5, $6::uuid[], $7, (SELECT token_version FROM users WHERE id = $1)
		WHERE (SELECT count(*) FROM ha_integrations WHERE user_id = $1 AND revoked_at IS NULL) < $8
		RETURNING `+haCols,
		claims.UserID, name, haHashToken(token), hint, scopes, ids, haSealSecret(secret), haMaxActiveTokens)
	integ, err := scanHA(row)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusConflict, "too many active tokens; revoke one first")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create token")
		return
	}
	s.haAudit(r, claims.UserID, "integration.ha.token_created",
		"token "+integ.ID+" ("+name+") scopes="+strings.Join(scopes, ",")+" circles="+strconv.Itoa(len(ids)))
	out := integ.json(hint)
	out.Token = token
	out.WebhookSecret = secret
	writeJSON(w, http.StatusCreated, out)
}

// ListHATokens returns the caller's active tokens (never a token or secret).
func (s *Server) ListHATokens(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT `+haCols+`, token_hint FROM ha_integrations
		WHERE user_id = $1 AND revoked_at IS NULL ORDER BY created_at DESC, id`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list tokens")
		return
	}
	defer rows.Close()
	out := []haTokenJSON{}
	for rows.Next() {
		var i haIntegration
		var hint string
		if err := rows.Scan(&i.ID, &i.UserID, &i.Name, &i.Scopes, &i.CircleIDs, &i.CreatedAt, &i.LastUsedAt,
			&i.WebhookURL, &i.WebhookSecret, &i.AllowPrivate, &i.WebhookEvents, &i.WebhookCursor, &i.WebhookFailures,
			&i.LastDeliveryAt, &i.LastDeliveryOK, &i.LastDeliveryCode, &i.LastDeliveryError, &i.LastDeliveryEvent, &hint); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read tokens")
			return
		}
		if err := i.openSecret(); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read tokens")
			return
		}
		out = append(out, i.json(hint))
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read tokens")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// loadOwnHA loads an integration owned by the caller. Anyone else's, a
// revoked one and a malformed id are the same uniform 404.
func (s *Server) loadOwnHA(w http.ResponseWriter, r *http.Request, userID string) (*haIntegration, string, bool) {
	id := chi.URLParam(r, "id")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "token not found")
		return nil, "", false
	}
	var hint string
	var i haIntegration
	err := s.Pool.QueryRow(r.Context(), `SELECT `+haCols+`, token_hint FROM ha_integrations
		WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL`, id, userID).Scan(
		&i.ID, &i.UserID, &i.Name, &i.Scopes, &i.CircleIDs, &i.CreatedAt, &i.LastUsedAt,
		&i.WebhookURL, &i.WebhookSecret, &i.AllowPrivate, &i.WebhookEvents, &i.WebhookCursor, &i.WebhookFailures,
		&i.LastDeliveryAt, &i.LastDeliveryOK, &i.LastDeliveryCode, &i.LastDeliveryError, &i.LastDeliveryEvent, &hint)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "token not found")
		return nil, "", false
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load token")
		return nil, "", false
	}
	if err := i.openSecret(); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load token")
		return nil, "", false
	}
	return &i, hint, true
}

// RevokeHAToken revokes a token immediately and stops its webhook.
func (s *Server) RevokeHAToken(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	integ, _, ok := s.loadOwnHA(w, r, claims.UserID)
	if !ok {
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `
		UPDATE ha_integrations SET revoked_at = now(), webhook_url = '', webhook_secret = ''
		WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL`, integ.ID, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke token")
		return
	}
	if tag.RowsAffected() == 1 {
		s.haAudit(r, claims.UserID, "integration.ha.token_revoked", "token "+integ.ID+" ("+integ.Name+")")
	}
	w.WriteHeader(http.StatusNoContent)
}

// UpdateHAToken edits the name and the webhook:
// {"name"?, "webhook_url"?, "webhook_allow_private"?, "webhook_events"?, "rotate_webhook_secret"?}.
func (s *Server) UpdateHAToken(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Name          *string   `json:"name"`
		WebhookURL    *string   `json:"webhook_url"`
		AllowPrivate  *bool     `json:"webhook_allow_private"`
		WebhookEvents *[]string `json:"webhook_events"`
		RotateSecret  bool      `json:"rotate_webhook_secret"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	integ, hint, ok := s.loadOwnHA(w, r, claims.UserID)
	if !ok {
		return
	}
	if !s.allowKey(w, "ha:manage:"+claims.UserID, haManagePerMin, time.Minute) {
		return
	}
	if req.Name != nil {
		n := strings.TrimSpace(*req.Name)
		if n == "" || len([]rune(n)) > 60 {
			writeError(w, http.StatusBadRequest, "name must be 1-60 characters")
			return
		}
		integ.Name = n
	}
	if req.AllowPrivate != nil && *req.AllowPrivate != integ.AllowPrivate {
		if *req.AllowPrivate {
			// Reaching a private network from the server is an operator decision.
			var admin bool
			if err := s.Pool.QueryRow(r.Context(), `SELECT platform_admin FROM users WHERE id = $1`, claims.UserID).Scan(&admin); err != nil {
				writeError(w, http.StatusInternalServerError, "failed to load role")
				return
			}
			if !admin {
				writeError(w, http.StatusForbidden, "only a server administrator can allow webhooks to the local network")
				return
			}
		}
		integ.AllowPrivate = *req.AllowPrivate
	}
	if req.WebhookEvents != nil {
		var evs []string
		for _, e := range *req.WebhookEvents {
			if !haKnownKind(e) {
				writeError(w, http.StatusBadRequest, "unknown event: "+e)
				return
			}
			evs = append(evs, e)
		}
		sort.Strings(evs)
		integ.WebhookEvents = evs
	}
	urlChanged := false
	newSecret := ""
	if req.WebhookURL != nil {
		raw := strings.TrimSpace(*req.WebhookURL)
		if raw == "" {
			integ.WebhookURL = ""
		} else {
			u, err := haParseWebhookURL(raw)
			if err != nil {
				writeError(w, http.StatusBadRequest, err.Error())
				return
			}
			if err := haCheckWebhookHost(r.Context(), u, integ.AllowPrivate); err != nil {
				msg := err.Error()
				if errors.Is(err, errHAWebhookBlocked) {
					msg = "that address is not allowed (loopback, link-local and metadata addresses are always refused; private LAN addresses need the local-network option, which a server administrator must enable)"
				}
				writeError(w, http.StatusBadRequest, msg)
				return
			}
			integ.WebhookURL = u.String()
			urlChanged = true
		}
	} else if integ.WebhookURL != "" && req.AllowPrivate != nil && !integ.AllowPrivate {
		// Turning the LAN option off re-validates the stored URL.
		if u, err := haParseWebhookURL(integ.WebhookURL); err == nil {
			if err := haCheckWebhookHost(r.Context(), u, false); err != nil {
				writeError(w, http.StatusBadRequest, "the saved webhook address needs the local-network option; change the URL first")
				return
			}
		}
	}
	if req.RotateSecret {
		sec, err := haNewSecret()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to rotate secret")
			return
		}
		integ.WebhookSecret = sec
		newSecret = sec
	}
	// A new URL starts at "now": history is never replayed to a fresh target.
	_, err := s.Pool.Exec(r.Context(), `
		UPDATE ha_integrations SET name = $3, webhook_url = $4, webhook_secret = $5, webhook_allow_private = $6,
		       webhook_events = $7,
		       webhook_cursor = CASE WHEN $8 THEN COALESCE((SELECT max(id) FROM ha_events), 0) ELSE webhook_cursor END,
		       webhook_failures = CASE WHEN $8 THEN 0 ELSE webhook_failures END,
		       webhook_next_attempt = CASE WHEN $8 THEN NULL ELSE webhook_next_attempt END
		WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL`,
		integ.ID, claims.UserID, integ.Name, integ.WebhookURL, haSealSecret(integ.WebhookSecret), integ.AllowPrivate, nonNilStrings(integ.WebhookEvents), urlChanged)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update token")
		return
	}
	if req.WebhookURL != nil {
		detail := "token " + integ.ID + " webhook cleared"
		if integ.WebhookURL != "" {
			detail = "token " + integ.ID + " webhook set to " + haMaskURL(integ.WebhookURL)
		}
		s.haAudit(r, claims.UserID, "integration.ha.webhook_updated", detail)
	}
	if req.RotateSecret {
		s.haAudit(r, claims.UserID, "integration.ha.webhook_secret_rotated", "token "+integ.ID)
	}
	fresh, hint2, ok := s.loadOwnHA(w, r, claims.UserID)
	if !ok {
		return
	}
	_ = hint
	out := fresh.json(hint2)
	out.WebhookSecret = newSecret
	writeJSON(w, http.StatusOK, out)
}

func nonNilStrings(in []string) []string {
	if in == nil {
		return []string{}
	}
	return in
}

// TestHAWebhook sends one synthetic signed "test" event to the configured URL
// and reports the outcome (status code and an error class only).
func (s *Server) TestHAWebhook(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	integ, _, ok := s.loadOwnHA(w, r, claims.UserID)
	if !ok {
		return
	}
	if integ.WebhookURL == "" {
		writeError(w, http.StatusBadRequest, "no webhook URL is configured")
		return
	}
	if !s.allowKey(w, "ha:test:"+claims.UserID, haTestPerMin, time.Minute) {
		return
	}
	body, _ := json.Marshal(map[string]any{
		"id": 0, "type": "test", "occurred_at": time.Now().UTC().Format(time.RFC3339),
		"message": "Orbitly test event",
	})
	code, class := haSend(r.Context(), integ.WebhookURL, integ.WebhookSecret, s.haEffectiveAllowPrivate(r.Context(), integ), "test", 0, body)
	s.haRecordDelivery(r.Context(), integ.ID, "test", code, class)
	s.haAudit(r, claims.UserID, "integration.ha.webhook_test", "token "+integ.ID+" result="+haResultWord(class))
	writeJSON(w, http.StatusOK, map[string]any{"ok": class == "", "status_code": code, "error": class})
}

// haEffectiveAllowPrivate: the LAN option only counts while its owner is still a
// platform administrator (a demoted admin's webhook loses LAN access).
func (s *Server) haEffectiveAllowPrivate(ctx context.Context, integ *haIntegration) bool {
	if !integ.AllowPrivate {
		return false
	}
	var admin bool
	if err := s.Pool.QueryRow(ctx, `SELECT platform_admin FROM users WHERE id = $1`, integ.UserID).Scan(&admin); err != nil {
		return false
	}
	return admin
}

func haResultWord(class string) string {
	if class == "" {
		return "ok"
	}
	return class
}

func (s *Server) haRecordDelivery(ctx context.Context, id, kind string, code int, class string) {
	var c any
	if code != 0 {
		c = code
	}
	if _, err := s.Pool.Exec(ctx, `
		UPDATE ha_integrations SET last_delivery_at = now(), last_delivery_ok = $2, last_delivery_code = $3,
		       last_delivery_error = $4, last_delivery_event = $5 WHERE id = $1`,
		id, class == "", c, class, kind); err != nil {
		haLogErr("record delivery", err)
	}
}

func haNormalizeScopes(in []string) ([]string, string) {
	if len(in) == 0 {
		in = []string{haScopePresence}
	}
	set := map[string]bool{}
	for _, sc := range in {
		sc = strings.ToLower(strings.TrimSpace(sc))
		known := false
		for _, k := range haAllScopes {
			if k == sc {
				known = true
			}
		}
		if !known {
			return nil, sc
		}
		set[sc] = true
	}
	if set[haScopeLocation] {
		set[haScopePresence] = true
	}
	var out []string
	for _, k := range haAllScopes {
		if set[k] {
			out = append(out, k)
		}
	}
	return out, ""
}

func haKnownKind(k string) bool {
	for _, e := range haEventKinds {
		if e == k {
			return true
		}
	}
	return false
}

// ---- token authentication (integration API) -------------------------------

// haAuth authenticates an integration API request and enforces the scope and
// rate limits. It writes the error response and returns false when refused.
// Only integration tokens (ofha_...) are accepted: a user's session JWT is not.
func (s *Server) haAuth(w http.ResponseWriter, r *http.Request, scope string) (*haIntegration, bool) {
	w.Header().Set("Cache-Control", "no-store")
	ip := clientIP(r)
	missKey := "ha:miss:" + limiterIP(ip)
	deny := func(status int, code string) (*haIntegration, bool) {
		if status == http.StatusUnauthorized {
			w.Header().Set("WWW-Authenticate", `Bearer realm="openfamily-ha"`)
		}
		writeJSON(w, status, map[string]string{"error": code})
		return nil, false
	}
	if s.AuthLimit != nil && s.AuthLimit.Exceeded(missKey, haBadTokenPerIP, haBadTokenWindow) {
		w.Header().Set("Retry-After", "900")
		return deny(http.StatusTooManyRequests, "too_many_requests")
	}
	authz := r.Header.Get("Authorization")
	token := ""
	if len(authz) > 7 && strings.EqualFold(authz[:7], "bearer ") {
		token = strings.TrimSpace(authz[7:])
	}
	miss := func() (*haIntegration, bool) {
		if s.AuthLimit != nil {
			s.AuthLimit.Record(missKey, haBadTokenWindow)
		}
		if s.viewAudit == nil || s.viewAudit.Allow("ha:authfail:"+limiterIP(ip), 1, haReadAuditEvery) {
			s.logAudit(r.Context(), "", "", "integration.ha.auth_failed", "invalid or revoked integration token", ip)
		}
		return deny(http.StatusUnauthorized, "invalid_token")
	}
	if len(token) != haTokenLen || !haTokenRe.MatchString(token) {
		return miss()
	}
	row := s.Pool.QueryRow(r.Context(), `SELECT `+haCols+` FROM ha_integrations
		WHERE token_hash = $1 AND revoked_at IS NULL AND `+haOwnerOKSQL, haHashToken(token))
	integ, err := scanHA(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return miss()
	}
	if err != nil {
		return deny(http.StatusInternalServerError, "server_error")
	}
	if scope != "" && !integ.has(scope) {
		return deny(http.StatusForbidden, "insufficient_scope")
	}
	if s.AuthLimit != nil && !s.AuthLimit.Allow("ha:rate:"+integ.ID, haAPIPerMin, time.Minute) {
		w.Header().Set("Retry-After", "60")
		return deny(http.StatusTooManyRequests, "rate_limited")
	}
	if _, err := s.Pool.Exec(r.Context(), `
		UPDATE ha_integrations SET last_used_at = now()
		WHERE id = $1 AND (last_used_at IS NULL OR last_used_at < now() - $2::interval)`,
		integ.ID, strconv.Itoa(int(haUsedThrottle.Seconds()))+" seconds"); err != nil {
		haLogErr("last used", err)
	}
	if s.viewAudit == nil || s.viewAudit.Allow("ha:read:"+integ.ID, 1, haReadAuditEvery) {
		if fid, err := s.familyIDForUser(r.Context(), integ.UserID); err == nil {
			s.logAudit(r.Context(), integ.UserID, fid, "integration.ha.read", "token "+integ.ID+" "+r.Method+" "+r.URL.Path, ip)
		}
	}
	return integ, true
}
