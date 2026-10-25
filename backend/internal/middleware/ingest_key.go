package middleware

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
)

// DeviceKeyHeader carries the per-device ingest credential as
// "<device_id>.<ingest_key>". The ingest key is a write-only, device-scoped
// secret: it authorizes POST /locations and POST /devices/heartbeat only.
//
// It exists because the app's background reporter runs in a headless Flutter
// isolate where the Keystore-backed secure store (which holds the refresh
// token) is not reliably reachable, so a JWT-only design silently stops
// reporting as soon as the 15-minute access token expires. The key carries no
// absolute expiry but a sliding server-side one (see IngestKeyTTL): it ages out
// after IngestKeyTTL without use. It is revoked server-side on logout, password
// change/reset and device deletion, and can be rotated via
// POST /devices/{id}/ingest-key. The key is bound to its device: a request
// whose body names a different device_id is rejected. Server-side only its
// SHA-256 hash is persisted, so a database read does not leak usable
// credentials.
const DeviceKeyHeader = "X-Device-Key"

// GenerateDeviceIngestKey returns a new random ingest key (32 bytes,
// base64url-encoded unpadded, no '.' so header parsing by the first dot is
// unambiguous).
func GenerateDeviceIngestKey() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// HashDeviceIngestKey returns the SHA-256 of an ingest key — the only form
// stored server-side.
func HashDeviceIngestKey(key string) []byte {
	sum := sha256.Sum256([]byte(key))
	return sum[:]
}

// EncodeIngestKeyHash renders a hash for the TEXT ingest_key_hash column.
func EncodeIngestKeyHash(hash []byte) string {
	return hex.EncodeToString(hash)
}

// ParseDeviceKeyHeader splits "<device_id>.<ingest_key>". Reports false for
// missing parts, extra segments, or whitespace-padded garbage.
func ParseDeviceKeyHeader(header string) (deviceID, key string, ok bool) {
	header = strings.TrimSpace(header)
	dot := strings.IndexByte(header, '.')
	if dot <= 0 || dot == len(header)-1 {
		return "", "", false
	}
	deviceID, key = header[:dot], header[dot+1:]
	if strings.ContainsAny(deviceID, " \t") || strings.ContainsAny(key, " \t") {
		return "", "", false
	}
	return deviceID, key, true
}

// ingestKeysEqual constant-time-compares a presented key against the stored
// hex-encoded hash.
func ingestKeysEqual(storedHashHex, presentedKey string) bool {
	candidate := EncodeIngestKeyHash(HashDeviceIngestKey(presentedKey))
	return subtle.ConstantTimeCompare([]byte(storedHashHex), []byte(candidate)) == 1
}

// IngestKeyTTL is how long an ingest key stays valid without use. Each use in
// the second half of the window pushes the expiry out again, so active devices
// never notice. Zero disables server-side expiry. Set from config at startup.
var IngestKeyTTL = 90 * 24 * time.Hour

// maxIngestBody bounds the body the middleware buffers to check device
// binding; it matches the batch endpoint's own limit.
const maxIngestBody = 1 << 20

// NewIngestKeyExpiry returns the expiry to stamp on a freshly issued key, or
// nil when expiry is disabled.
func NewIngestKeyExpiry(now time.Time) *time.Time {
	if IngestKeyTTL <= 0 {
		return nil
	}
	t := now.Add(IngestKeyTTL)
	return &t
}

type deviceIDKey struct{}

// DeviceIDFromContext returns the device id a request authenticated as via
// X-Device-Key, or "" for Bearer-authenticated requests.
func DeviceIDFromContext(ctx context.Context) string {
	id, _ := ctx.Value(deviceIDKey{}).(string)
	return id
}

// deviceKeyRecord is the stored credential state for a device.
type deviceKeyRecord struct {
	OwnerID   *string
	Hash      *string
	ExpiresAt *time.Time
}

// ingestStore is the persistence the ingest middleware needs.
type ingestStore interface {
	TokenVersion(ctx context.Context, userID string) (int, error)
	DeviceKey(ctx context.Context, deviceID string) (deviceKeyRecord, error)
	ExtendDeviceKey(ctx context.Context, deviceID string, expires time.Time) error
}

type pgIngestStore struct{ pool *pgxpool.Pool }

func (p pgIngestStore) TokenVersion(ctx context.Context, userID string) (int, error) {
	var v int
	err := p.pool.QueryRow(ctx, `SELECT token_version FROM users WHERE id = $1`, userID).Scan(&v)
	return v, err
}

func (p pgIngestStore) DeviceKey(ctx context.Context, deviceID string) (deviceKeyRecord, error) {
	var rec deviceKeyRecord
	err := p.pool.QueryRow(ctx,
		`SELECT user_id, ingest_key_hash, ingest_key_expires_at FROM devices WHERE id = $1`, deviceID,
	).Scan(&rec.OwnerID, &rec.Hash, &rec.ExpiresAt)
	return rec, err
}

func (p pgIngestStore) ExtendDeviceKey(ctx context.Context, deviceID string, expires time.Time) error {
	_, err := p.pool.Exec(ctx,
		`UPDATE devices SET ingest_key_expires_at = $2 WHERE id = $1 AND ingest_key_hash IS NOT NULL`,
		deviceID, expires)
	return err
}

// deviceKeyExpired reports whether a stored expiry has passed.
func deviceKeyExpired(expires *time.Time, now time.Time) bool {
	return expires != nil && !now.Before(*expires)
}

// slideExpiry decides whether a successful use should push the expiry out and
// to when. Legacy keys (nil expiry) are stamped on first use.
func slideExpiry(expires *time.Time, now time.Time) (time.Time, bool) {
	if IngestKeyTTL <= 0 {
		return time.Time{}, false
	}
	if expires == nil || expires.Sub(now) < IngestKeyTTL/2 {
		return now.Add(IngestKeyTTL), true
	}
	return time.Time{}, false
}

// errDeviceMismatch is returned when a request body names a device other than
// the one the presented key belongs to.
var errDeviceMismatch = errors.New("device_id does not match device key")

// checkBodyDevice verifies that every device_id present in an ingest body
// (single-point {"device_id"} or batch {"points":[{"device_id"}]}) equals the
// device the key was issued for. A body that does not parse, or that names no
// device, is left for the handler to reject with its own 400.
func checkBodyDevice(body []byte, deviceID string) error {
	var req struct {
		DeviceID string `json:"device_id"`
		Points   []struct {
			DeviceID string `json:"device_id"`
		} `json:"points"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return nil
	}
	if req.DeviceID != "" && !strings.EqualFold(req.DeviceID, deviceID) {
		return errDeviceMismatch
	}
	for _, p := range req.Points {
		if p.DeviceID != "" && !strings.EqualFold(p.DeviceID, deviceID) {
			return errDeviceMismatch
		}
	}
	return nil
}

// RequireAuthOrDeviceIngestKey guards the ingest endpoints (POST /locations,
// /locations/batch and /devices/heartbeat). It accepts either:
//
//   - a valid Bearer access token (equivalent to RequireAuth +
//     RequireTokenVersion: the version is re-checked here because these routes
//     are deliberately outside the JWT route group), or
//   - DeviceKeyHeader with a valid, unexpired per-device ingest key, which is
//     only good for the device it was issued to.
//
// Both branches inject claims (at minimum the user id) so the handlers share
// one code path regardless of credential type.
func RequireAuthOrDeviceIngestKey(tm *auth.TokenManager, pool *pgxpool.Pool) func(http.Handler) http.Handler {
	return requireAuthOrDeviceIngestKey(tm, pgIngestStore{pool})
}

func requireAuthOrDeviceIngestKey(tm *auth.TokenManager, store ingestStore) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			header := r.Header.Get("Authorization")
			if strings.HasPrefix(header, "Bearer ") {
				claims, err := tm.Parse(strings.TrimPrefix(header, "Bearer "), auth.AccessToken)
				if err != nil {
					http.Error(w, `{"error":"invalid or expired token"}`, http.StatusUnauthorized)
					return
				}
				if version, err := store.TokenVersion(r.Context(), claims.UserID); err != nil || version != claims.TokenVersion {
					http.Error(w, `{"error":"invalid or expired token"}`, http.StatusUnauthorized)
					return
				}
				next.ServeHTTP(w, r.WithContext(ContextWithClaims(r.Context(), claims)))
				return
			}

			deviceKeyHeader := r.Header.Get(DeviceKeyHeader)
			if deviceKeyHeader == "" {
				http.Error(w, `{"error":"missing credentials"}`, http.StatusUnauthorized)
				return
			}
			deviceID, key, ok := ParseDeviceKeyHeader(deviceKeyHeader)
			if !ok {
				http.Error(w, `{"error":"malformed device key"}`, http.StatusUnauthorized)
				return
			}
			rec, err := store.DeviceKey(r.Context(), deviceID)
			if err != nil || rec.OwnerID == nil || rec.Hash == nil {
				http.Error(w, `{"error":"invalid device key"}`, http.StatusUnauthorized)
				return
			}
			if !ingestKeysEqual(*rec.Hash, key) {
				http.Error(w, `{"error":"invalid device key"}`, http.StatusUnauthorized)
				return
			}
			now := time.Now()
			if deviceKeyExpired(rec.ExpiresAt, now) {
				http.Error(w, `{"error":"device key expired"}`, http.StatusUnauthorized)
				return
			}

			// Bind the key to its device: it must not authorize reports for
			// another device of the same user.
			if r.Body != nil && r.Body != http.NoBody {
				r.Body = http.MaxBytesReader(w, r.Body, maxIngestBody)
				body, err := io.ReadAll(r.Body)
				if err != nil {
					http.Error(w, `{"error":"request body too large"}`, http.StatusRequestEntityTooLarge)
					return
				}
				if err := checkBodyDevice(body, deviceID); err != nil {
					http.Error(w, `{"error":"device key is not valid for this device"}`, http.StatusForbidden)
					return
				}
				r.Body = io.NopCloser(bytes.NewReader(body))
			}

			if exp, slide := slideExpiry(rec.ExpiresAt, now); slide {
				// Best effort: a failed extension must not fail ingest.
				_ = store.ExtendDeviceKey(r.Context(), deviceID, exp)
			}

			ctx := ContextWithClaims(r.Context(), &auth.Claims{UserID: *rec.OwnerID, TokenType: auth.AccessToken})
			ctx = context.WithValue(ctx, deviceIDKey{}, deviceID)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}
