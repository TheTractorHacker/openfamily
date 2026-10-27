package handlers

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/config"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// "Share your live location with anyone": a revocable, expiring link whose
// public viewer needs no app or account. Only SHA-256(token) is stored; the
// token (256 random bits) is returned once, at creation. See
// docs/share-links.md.
const (
	shareLinkTokenBytes = 32
	// base64.RawURLEncoding of 32 bytes is always 43 characters.
	shareLinkTokenLen = 43
	minShareLink      = time.Minute
	maxShareLink      = 72 * time.Hour
	maxActiveLinks    = 10

	shareLinkViewPerIP   = 150 // page + data polls (~12/min per open viewer)
	shareLinkViewWindow  = time.Minute
	shareLinkMissPerIP   = 30 // lookups that found nothing
	shareLinkMissWindow  = 15 * time.Minute
	shareLinkCreatePerHr = 30
)

var shareLinkTokenRe = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)

func hashShareToken(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}

func newShareLinkToken() (string, error) {
	b := make([]byte, shareLinkTokenBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// ---- authenticated management ---------------------------------------------

type shareLinkJSON struct {
	ID        string    `json:"id"`
	Label     string    `json:"label"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
	// Token and URL are present only in the response to POST /share-links.
	Token string `json:"token,omitempty"`
	URL   string `json:"url,omitempty"`
}

// CreateShareLink mints a link: {"minutes": 1..4320, "label"?}.
func (s *Server) CreateShareLink(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Minutes int    `json:"minutes"`
		Label   string `json:"label"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if d := time.Duration(req.Minutes) * time.Minute; d < minShareLink || d > maxShareLink {
		writeError(w, http.StatusBadRequest, "minutes must be between 1 and 4320")
		return
	}
	label := strings.TrimSpace(req.Label)
	if len([]rune(label)) > 60 {
		writeError(w, http.StatusBadRequest, "label must be 60 characters or fewer")
		return
	}
	origin := s.publicOrigin(r)
	if origin == "" {
		writeError(w, http.StatusInternalServerError, "server public address is not configured")
		return
	}
	if !s.allowKey(w, "sharelink:create:"+claims.UserID, shareLinkCreatePerHr, time.Hour) {
		return
	}
	token, err := newShareLinkToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create link")
		return
	}
	out := shareLinkJSON{Label: label}
	// The cap is checked in the same statement as the insert.
	err = s.Pool.QueryRow(r.Context(), `
		INSERT INTO share_links (user_id, token_hash, label, expires_at)
		SELECT $1, $2, $3, now() + make_interval(mins => $4::int)
		WHERE (SELECT count(*) FROM share_links
		       WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now()) < $5
		RETURNING id, created_at, expires_at`,
		claims.UserID, hashShareToken(token), label, req.Minutes, maxActiveLinks,
	).Scan(&out.ID, &out.CreatedAt, &out.ExpiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusConflict, "too many active links; stop one first")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create link")
		return
	}
	out.Token = token
	out.URL = origin + "/s/" + token
	s.auditSharing(r, claims.UserID, "sharelink.create", "share link "+out.ID+" until "+out.ExpiresAt.Format(time.RFC3339))
	go s.purgeExpiredShareLinks()
	writeJSON(w, http.StatusCreated, out)
}

// ListShareLinks returns the caller's active links (never the token).
func (s *Server) ListShareLinks(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT id, label, created_at, expires_at FROM share_links
		WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now()
		ORDER BY expires_at, id`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load links")
		return
	}
	defer rows.Close()
	out := []shareLinkJSON{}
	for rows.Next() {
		var l shareLinkJSON
		if err := rows.Scan(&l.ID, &l.Label, &l.CreatedAt, &l.ExpiresAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load links")
			return
		}
		out = append(out, l)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to load links")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"links": out})
}

// DeleteShareLink stops sharing: the public viewer stops serving at once.
func (s *Server) DeleteShareLink(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "link not found")
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `
		UPDATE share_links SET revoked_at = now()
		WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL AND expires_at > now()`, id, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to stop sharing")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "link not found")
		return
	}
	s.auditSharing(r, claims.UserID, "sharelink.revoke", "stopped share link "+id)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// purgeExpiredShareLinks drops links a week after they ended.
func (s *Server) purgeExpiredShareLinks() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, _ = s.Pool.Exec(ctx, `
		DELETE FROM share_links
		WHERE expires_at < now() - interval '7 days'
		   OR revoked_at < now() - interval '7 days'`)
}

// ---- public viewer ----------------------------------------------------------

// shareViewData is everything the public viewer ever learns. There is no id,
// email, circle, or history in it.
type shareViewData struct {
	State     string     `json:"state"` // "active" | "paused" | "no_location"
	Name      string     `json:"name"`
	Initial   string     `json:"initial"`
	PhotoURL  string     `json:"photo_url,omitempty"`
	Lat       *float64   `json:"lat,omitempty"`
	Lon       *float64   `json:"lon,omitempty"`
	Accuracy  *float64   `json:"accuracy_m,omitempty"`
	Heading   *float64   `json:"heading_deg,omitempty"`
	Speed     *float64   `json:"speed_mps,omitempty"`
	Battery   *float64   `json:"battery_pct,omitempty"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
	ExpiresAt time.Time  `json:"expires_at"`
}

type shareViewRow struct {
	data      shareViewData
	hasAvatar bool
}

// lookupShareView resolves a token to the owner's current shareable state. It
// returns false for malformed, unknown, expired and revoked tokens alike. The
// hash is the index key, so lookup time reveals nothing about stored tokens;
// the stored hash is compared again in constant time.
func (s *Server) lookupShareView(ctx context.Context, token string) (shareViewRow, bool) {
	var out shareViewRow
	if !shareLinkTokenRe.MatchString(token) {
		return out, false
	}
	want := hashShareToken(token)
	var stored []byte
	var paused bool
	var lat, lon, acc, head, speed, batt *float64
	var ts *time.Time
	err := s.Pool.QueryRow(ctx, `
		SELECT sl.token_hash, sl.expires_at, u.name, u.avatar_data IS NOT NULL,
		       `+pausedExprSQL("u.id")+`,
		       mp.lat, mp.lon, mp.accuracy_meters, mp.heading_deg, mp.speed_mps, mp.battery_pct, mp.ts
		FROM share_links sl
		JOIN users u ON u.id = sl.user_id
		LEFT JOIN member_positions mp ON mp.user_id = sl.user_id
		WHERE sl.token_hash = $1 AND sl.revoked_at IS NULL AND sl.expires_at > now()`, want,
	).Scan(&stored, &out.data.ExpiresAt, &out.data.Name, &out.hasAvatar, &paused,
		&lat, &lon, &acc, &head, &speed, &batt, &ts)
	if err != nil || subtle.ConstantTimeCompare(stored, want) != 1 {
		return shareViewRow{}, false
	}
	d := &out.data
	d.Name = strings.TrimSpace(d.Name)
	if d.Name == "" {
		d.Name = "Someone"
	}
	d.Initial = strings.ToUpper(string([]rune(d.Name)[:1]))
	switch {
	case paused:
		d.State = "paused"
	case lat == nil || lon == nil:
		d.State = "no_location"
	default:
		d.State = "active"
		d.Lat, d.Lon, d.Accuracy, d.Heading, d.Speed, d.Battery, d.UpdatedAt = lat, lon, acc, head, speed, batt, ts
	}
	if out.hasAvatar {
		d.PhotoURL = "/s/" + token + "/photo"
	}
	return out, true
}

// setShareViewHeaders applies the hardening shared by every public viewer
// response, hits and misses alike. csp differs per response.
func setShareViewHeaders(w http.ResponseWriter, csp string) {
	h := w.Header()
	h.Set("Content-Security-Policy", csp)
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Frame-Options", "DENY")
	h.Set("X-Robots-Tag", "noindex, nofollow, noarchive")
	h.Set("Cache-Control", "no-store")
	h.Set("Pragma", "no-cache")
}

const shareViewDataCSP = "default-src 'none'; frame-ancestors 'none'"

// shareViewGate applies the per-IP limit; false means a 429 was written.
func (s *Server) shareViewGate(w http.ResponseWriter, r *http.Request) bool {
	if s.AuthLimit != nil && !s.AuthLimit.Allow(authIPKey("sharelink", clientIP(r)), shareLinkViewPerIP, shareLinkViewWindow) {
		w.Header().Set("Retry-After", "60")
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return false
	}
	return true
}

// shareViewMiss answers every unusable token identically and charges the IP's
// miss budget, so tokens cannot be guessed at speed.
func (s *Server) shareViewMiss(w http.ResponseWriter, r *http.Request, page bool) {
	if s.AuthLimit != nil && !s.AuthLimit.Allow(authIPKey("sharelink-miss", clientIP(r)), shareLinkMissPerIP, shareLinkMissWindow) {
		w.Header().Set("Retry-After", "900")
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}
	if page {
		setShareViewHeaders(w, "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(shareGonePage))
		return
	}
	setShareViewHeaders(w, shareViewDataCSP)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotFound)
	_, _ = w.Write([]byte(`{"error":"not found"}`))
}

// ShareViewData is GET /s/{token}/data.
func (s *Server) ShareViewData(w http.ResponseWriter, r *http.Request) {
	if !s.shareViewGate(w, r) {
		return
	}
	row, ok := s.lookupShareView(r.Context(), chi.URLParam(r, "token"))
	if !ok {
		s.shareViewMiss(w, r, false)
		return
	}
	setShareViewHeaders(w, shareViewDataCSP)
	writeJSON(w, http.StatusOK, row.data)
}

// ShareViewPhoto is GET /s/{token}/photo: the owner's avatar, only while the
// link is live.
func (s *Server) ShareViewPhoto(w http.ResponseWriter, r *http.Request) {
	if !s.shareViewGate(w, r) {
		return
	}
	token := chi.URLParam(r, "token")
	row, ok := s.lookupShareView(r.Context(), token)
	if !ok || !row.hasAvatar {
		s.shareViewMiss(w, r, false)
		return
	}
	var avatar []byte
	var ct string
	err := s.Pool.QueryRow(r.Context(), `
		SELECT u.avatar_data, u.avatar_content_type FROM share_links sl
		JOIN users u ON u.id = sl.user_id
		WHERE sl.token_hash = $1 AND u.avatar_data IS NOT NULL`, hashShareToken(token)).Scan(&avatar, &ct)
	if err != nil {
		s.shareViewMiss(w, r, false)
		return
	}
	setShareViewHeaders(w, shareViewDataCSP)
	writePrivateAvatar(w, avatar, ct)
}

// shareTileConfig turns the configured raster template into what the page
// needs: the template (https only, {s}->a, {r} dropped) and the CSP img-src
// source for its origin. ok=false when the template is unusable.
func shareTileConfig(tmpl string) (tpl, cspSrc string, ok bool) {
	tmpl = strings.TrimSpace(tmpl)
	if tmpl == "" {
		tmpl = config.DefaultTileURL
	}
	u, err := url.Parse(strings.NewReplacer("{s}", "a", "{r}", "", "{z}", "0", "{x}", "0", "{y}", "0").Replace(tmpl))
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
		return "", "", false
	}
	src := "https://" + u.Host
	if strings.Contains(tmpl, "{s}") {
		// Subdomain rotation: allow the sibling hosts of the template.
		if h := strings.SplitN(strings.TrimPrefix(tmpl, "https://"), "/", 2)[0]; strings.HasPrefix(h, "{s}.") {
			src = "https://*." + strings.TrimPrefix(h, "{s}.")
		}
	}
	tpl = strings.NewReplacer("{r}", "").Replace(tmpl)
	return tpl, src, true
}

// ShareViewPage is GET /s/{token}: the self-contained viewer. The page embeds
// no user data; it fetches /s/{token}/data. Its only external contact is the
// operator's configured tile server (img-src), the same one /config advertises.
func (s *Server) ShareViewPage(w http.ResponseWriter, r *http.Request) {
	if !s.shareViewGate(w, r) {
		return
	}
	if _, ok := s.lookupShareView(r.Context(), chi.URLParam(r, "token")); !ok {
		s.shareViewMiss(w, r, true)
		return
	}
	tpl, tileSrc, ok := shareTileConfig(s.TileURL)
	nb := make([]byte, 16)
	_, _ = rand.Read(nb)
	nonce := base64.RawStdEncoding.EncodeToString(nb)
	img := "'self' data:"
	if ok {
		img += " " + tileSrc
	}
	setShareViewHeaders(w, "default-src 'none'; script-src 'nonce-"+nonce+"'; style-src 'unsafe-inline'; img-src "+img+
		"; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = shareViewTmpl.Execute(w, struct {
		Nonce string
		Tiles string
	}{Nonce: nonce, Tiles: tpl})
}
