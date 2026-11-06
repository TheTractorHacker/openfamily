// Package middleware provides HTTP middleware for the API.
package middleware

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type contextKey string

const claimsKey contextKey = "claims"

// ClaimsFromContext returns the authenticated claims, or nil.
func ClaimsFromContext(ctx context.Context) *auth.Claims {
	c, _ := ctx.Value(claimsKey).(*auth.Claims)
	return c
}

// ContextWithClaims injects claims into ctx. Used by RequireAuth and tests.
func ContextWithClaims(ctx context.Context, c *auth.Claims) context.Context {
	return context.WithValue(ctx, claimsKey, c)
}

// RequireAuth validates the Bearer access token and injects claims into the
// request context. It returns 401 on missing/invalid tokens.
func RequireAuth(tm *auth.TokenManager) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			header := r.Header.Get("Authorization")
			if !strings.HasPrefix(header, "Bearer ") {
				http.Error(w, `{"error":"missing bearer token"}`, http.StatusUnauthorized)
				return
			}
			token := strings.TrimPrefix(header, "Bearer ")
			claims, err := tm.Parse(token, auth.AccessToken)
			if err != nil {
				http.Error(w, `{"error":"invalid or expired token"}`, http.StatusUnauthorized)
				return
			}
			next.ServeHTTP(w, r.WithContext(ContextWithClaims(r.Context(), claims)))
		})
	}
}

// RequireTokenVersion rejects JWTs whose ver claim does not match users.token_version.
// Run after RequireAuth. Logout, password change, and admin reset bump the column
// so outstanding access and refresh tokens die immediately.
func RequireTokenVersion(pool *pgxpool.Pool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims := ClaimsFromContext(r.Context())
			if claims == nil {
				http.Error(w, `{"error":"unauthenticated"}`, http.StatusUnauthorized)
				return
			}
			var version int
			err := pool.QueryRow(r.Context(),
				`SELECT token_version FROM users WHERE id = $1`, claims.UserID,
			).Scan(&version)
			// Only a definite mismatch (or a deleted user) is an auth failure. A
			// database hiccup (restart, pool exhaustion) must not read as 401:
			// clients treat 401 as "session dead" and sign the user out.
			if errors.Is(err, pgx.ErrNoRows) || (err == nil && version != claims.TokenVersion) {
				http.Error(w, `{"error":"invalid or expired token"}`, http.StatusUnauthorized)
				return
			}
			if err != nil {
				http.Error(w, `{"error":"temporarily unavailable"}`, http.StatusServiceUnavailable)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// RequirePlatformAdmin enforces the platform-admin privilege boundary. It must
// run after RequireAuth (so claims are present). It re-reads the platform_admin
// flag from the database on every request — never trusting the JWT — so a
// revoked/changed admin flag takes effect immediately without a reissue. A 403
// is returned when the authenticated user is not a platform admin; a 500 when
// the lookup fails.
//
// Platform admin is distinct from family admin: the family-scoped role column
// (admin/member/child) is unchanged and irrelevant here.
func RequirePlatformAdmin(pool *pgxpool.Pool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims := ClaimsFromContext(r.Context())
			if claims == nil {
				http.Error(w, `{"error":"unauthenticated"}`, http.StatusUnauthorized)
				return
			}
			var platformAdmin bool
			err := pool.QueryRow(r.Context(),
				`SELECT platform_admin FROM users WHERE id = $1`, claims.UserID,
			).Scan(&platformAdmin)
			if err != nil {
				http.Error(w, `{"error":"failed to verify platform admin"}`, http.StatusInternalServerError)
				return
			}
			if !platformAdmin {
				http.Error(w, `{"error":"platform admin required"}`, http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// AdminMFARequiredMessage is returned (with HTTP 403) to a platform admin who
// has not enabled two-factor authentication while REQUIRE_ADMIN_MFA is on.
const AdminMFARequiredMessage = "two-factor authentication is required for administrators: turn it on in the OpenFamily app (Settings, Security), then sign out and sign in again with your two-factor code"

// AdminMFASatisfied reports whether a session may use the admin surfaces when
// two-factor is mandatory: the account must still have TOTP enabled AND this
// session's token must record a passed TOTP challenge (amr claim). Tokens
// issued before TOTP was enabled, or without a challenge, fail closed.
func AdminMFASatisfied(totpEnabled bool, claims *auth.Claims) bool {
	return totpEnabled && claims != nil && claims.AMR == auth.AMRTOTP
}

// RequireAdminMFA, when enabled, refuses admin API access to a platform admin
// whose account has no TOTP configured or whose session did not pass a TOTP
// challenge. It must run after RequireAuth and
// RequirePlatformAdmin. The flag is re-read from the database on every request
// so enabling TOTP takes effect at once. Disabled, it is a pass-through.
func RequireAdminMFA(pool *pgxpool.Pool, enabled bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		if !enabled {
			return next
		}
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims := ClaimsFromContext(r.Context())
			if claims == nil {
				http.Error(w, `{"error":"unauthenticated"}`, http.StatusUnauthorized)
				return
			}
			var totp bool
			if err := pool.QueryRow(r.Context(),
				`SELECT totp_enabled FROM users WHERE id = $1`, claims.UserID).Scan(&totp); err != nil {
				http.Error(w, `{"error":"failed to verify two-factor status"}`, http.StatusInternalServerError)
				return
			}
			if !AdminMFASatisfied(totp, claims) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(`{"error":"` + AdminMFARequiredMessage + `","code":"admin_mfa_required"}`))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
