package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/models"
	"github.com/go-chi/chi/v5"
	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/jackc/pgx/v5"
)

// Passkeys (WebAuthn) sign-in, see docs/passkeys.md.
//
// A passkey is added by a signed-in user who proves they hold the password
// (and TOTP code when enabled), so passkeys never weaken the account: they can
// not be added by a stolen access token alone. Sign-in uses discoverable
// credentials with user verification required, so the passkey is itself a
// two-factor login (possession plus biometric/PIN) and no TOTP prompt follows.
// Recovery is unchanged: the password and reset codes keep working, and every
// passkey can be removed from a signed-in session.

const (
	passkeyChallengeTTL = 5 * time.Minute
	maxPasskeysPerUser  = 10
	passkeyBodyLimit    = 64 << 10
)

// NewWebAuthn builds the relying party. It returns nil (feature off) when rpID
// or origins are empty or invalid.
func NewWebAuthn(rpID, displayName string, origins []string) (*webauthn.WebAuthn, error) {
	if rpID == "" || len(origins) == 0 {
		return nil, nil
	}
	if displayName == "" {
		displayName = "Orbitly"
	}
	return webauthn.New(&webauthn.Config{
		RPID:          rpID,
		RPDisplayName: displayName,
		RPOrigins:     origins,
	})
}

// WebAuthnFromPublicURL derives the relying party from the public https
// origin (PUBLIC_BASE_URL) unless explicit values are given.
func WebAuthnFromPublicURL(publicBaseURL, rpID, originsCSV string) (*webauthn.WebAuthn, error) {
	var origins []string
	for _, o := range strings.Split(originsCSV, ",") {
		if o = strings.TrimSpace(o); o != "" {
			origins = append(origins, o)
		}
	}
	if u, err := url.Parse(publicBaseURL); err == nil && u.Scheme == "https" && u.Hostname() != "" {
		if rpID == "" {
			rpID = u.Hostname()
		}
		if len(origins) == 0 {
			origins = []string{u.Scheme + "://" + u.Host}
		}
	}
	return NewWebAuthn(rpID, "Orbitly", origins)
}

type passkeyUser struct {
	id    string
	name  string
	creds []webauthn.Credential
}

func (u *passkeyUser) WebAuthnID() []byte                         { return []byte(u.id) }
func (u *passkeyUser) WebAuthnName() string                       { return u.name }
func (u *passkeyUser) WebAuthnDisplayName() string                { return u.name }
func (u *passkeyUser) WebAuthnCredentials() []webauthn.Credential { return u.creds }

func (s *Server) passkeysEnabled(w http.ResponseWriter) bool {
	if s.WebAuthn == nil {
		writeError(w, http.StatusNotFound, "passkeys are not enabled on this server")
		return false
	}
	return true
}

func (s *Server) loadPasskeyUser(ctx context.Context, userID string) (*passkeyUser, error) {
	u := &passkeyUser{id: userID}
	var email, name string
	if err := s.Pool.QueryRow(ctx, `SELECT email, name FROM users WHERE id = $1`, userID).Scan(&email, &name); err != nil {
		return nil, err
	}
	u.name = email
	rows, err := s.Pool.Query(ctx, `SELECT credential FROM passkey_credentials WHERE user_id = $1`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var c webauthn.Credential
		if err := json.Unmarshal(raw, &c); err != nil {
			return nil, err
		}
		u.creds = append(u.creds, c)
	}
	return u, rows.Err()
}

func (s *Server) saveChallenge(ctx context.Context, userID, kind string, sd *webauthn.SessionData) (string, error) {
	raw, err := json.Marshal(sd)
	if err != nil {
		return "", err
	}
	var uid any
	if userID != "" {
		uid = userID
	}
	// Opportunistic cleanup keeps the table small without a janitor.
	_, _ = s.Pool.Exec(ctx, `DELETE FROM passkey_challenges WHERE expires_at < now()`)
	var id string
	err = s.Pool.QueryRow(ctx, `
		INSERT INTO passkey_challenges (user_id, kind, session_data, expires_at)
		VALUES ($1, $2, $3, $4) RETURNING id`,
		uid, kind, raw, time.Now().Add(passkeyChallengeTTL)).Scan(&id)
	return id, err
}

// takeChallenge atomically consumes a challenge: it can be used exactly once.
func (s *Server) takeChallenge(ctx context.Context, id, kind string) (webauthn.SessionData, string, bool) {
	var sd webauthn.SessionData
	if _, err := uuidParse(id); err != nil {
		return sd, "", false
	}
	var raw []byte
	var uid *string
	err := s.Pool.QueryRow(ctx, `
		DELETE FROM passkey_challenges
		WHERE id = $1 AND kind = $2 AND expires_at > now()
		RETURNING session_data, user_id::text`, id, kind).Scan(&raw, &uid)
	if err != nil {
		return sd, "", false
	}
	if json.Unmarshal(raw, &sd) != nil {
		return sd, "", false
	}
	owner := ""
	if uid != nil {
		owner = *uid
	}
	return sd, owner, true
}

func uuidParse(s string) (string, error) {
	if len(s) != 36 {
		return "", errors.New("bad id")
	}
	for i, c := range s {
		switch {
		case i == 8 || i == 13 || i == 18 || i == 23:
			if c != '-' {
				return "", errors.New("bad id")
			}
		case !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'):
			return "", errors.New("bad id")
		}
	}
	return s, nil
}

// PasskeyRegisterBegin starts adding a passkey. Requires the current password
// (and TOTP code when enabled).
func (s *Server) PasskeyRegisterBegin(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if !s.passkeysEnabled(w) {
		return
	}
	var req struct {
		Password string `json:"password"`
		TOTPCode string `json:"totp_code"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, passkeyBodyLimit)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if !s.stepUp(w, r, claims.UserID, req.Password, req.TOTPCode) {
		return
	}
	user, err := s.loadPasskeyUser(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}
	if len(user.creds) >= maxPasskeysPerUser {
		writeError(w, http.StatusConflict, "passkey limit reached; remove one first")
		return
	}
	exclude := make([]protocol.CredentialDescriptor, 0, len(user.creds))
	for _, c := range user.creds {
		exclude = append(exclude, c.Descriptor())
	}
	creation, sd, err := s.WebAuthn.BeginRegistration(user,
		webauthn.WithExclusions(exclude),
		webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementRequired),
		webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
			ResidentKey:      protocol.ResidentKeyRequirementRequired,
			UserVerification: protocol.VerificationRequired,
		}),
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to start registration")
		return
	}
	id, err := s.saveChallenge(r.Context(), claims.UserID, "register", sd)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store challenge")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"challenge_id": id, "options": creation})
}

// PasskeyRegisterFinish completes registration. The body is the credential
// JSON produced by navigator.credentials.create() (or the Android Credential
// Manager); challenge_id and an optional name are query parameters.
func (s *Server) PasskeyRegisterFinish(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if !s.passkeysEnabled(w) {
		return
	}
	sd, owner, ok := s.takeChallenge(r.Context(), r.URL.Query().Get("challenge_id"), "register")
	if !ok || owner != claims.UserID {
		writeError(w, http.StatusBadRequest, "registration expired; start again")
		return
	}
	user, err := s.loadPasskeyUser(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, passkeyBodyLimit)
	cred, err := s.WebAuthn.FinishRegistration(user, sd, r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "passkey could not be verified")
		return
	}
	raw, err := json.Marshal(cred)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store passkey")
		return
	}
	name := strings.TrimSpace(r.URL.Query().Get("name"))
	if name == "" {
		name = "Passkey"
	}
	if len(name) > 60 {
		name = name[:60]
	}
	var id string
	err = s.Pool.QueryRow(r.Context(), `
		INSERT INTO passkey_credentials (user_id, credential_id, credential, name)
		VALUES ($1, $2, $3, $4) RETURNING id`, claims.UserID, cred.ID, raw, name).Scan(&id)
	if err != nil {
		if isUniqueViolation(err) {
			writeError(w, http.StatusConflict, "this passkey is already registered")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to store passkey")
		return
	}
	s.logAudit(r.Context(), claims.UserID, claims.FamilyID, "auth.passkey_added", "passkey added", clientIP(r))
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "name": name})
}

// PasskeyLoginBegin starts a discoverable (usernameless) sign-in.
func (s *Server) PasskeyLoginBegin(w http.ResponseWriter, r *http.Request) {
	if !s.passkeysEnabled(w) {
		return
	}
	if !s.allowAuth(w, authIPKey("passkey", clientIP(r)), loginPerIP, loginWindow) {
		return
	}
	assertion, sd, err := s.WebAuthn.BeginDiscoverableLogin(
		webauthn.WithUserVerification(protocol.VerificationRequired))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to start sign-in")
		return
	}
	id, err := s.saveChallenge(r.Context(), "", "login", sd)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store challenge")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"challenge_id": id, "options": assertion})
}

// PasskeyLoginFinish verifies the assertion and returns a normal token pair.
func (s *Server) PasskeyLoginFinish(w http.ResponseWriter, r *http.Request) {
	if !s.passkeysEnabled(w) {
		return
	}
	if !s.allowAuth(w, authIPKey("passkey", clientIP(r)), loginPerIP, loginWindow) {
		return
	}
	sd, _, ok := s.takeChallenge(r.Context(), r.URL.Query().Get("challenge_id"), "login")
	if !ok {
		writeError(w, http.StatusUnauthorized, "sign-in expired; start again")
		return
	}
	fail := func() {
		s.logAudit(r.Context(), "", "", "auth.login_failed", "passkey login failed", clientIP(r))
		writeError(w, http.StatusUnauthorized, "passkey could not be verified")
	}
	handler := func(rawID, userHandle []byte) (webauthn.User, error) {
		// The user handle is the user id we set at registration; the
		// credential must also belong to that user.
		uid, err := uuidParse(string(userHandle))
		if err != nil {
			return nil, err
		}
		var owned bool
		if err := s.Pool.QueryRow(r.Context(),
			`SELECT EXISTS (SELECT 1 FROM passkey_credentials WHERE credential_id = $1 AND user_id = $2)`,
			rawID, uid).Scan(&owned); err != nil || !owned {
			return nil, errors.New("unknown credential")
		}
		return s.loadPasskeyUser(r.Context(), uid)
	}
	r.Body = http.MaxBytesReader(w, r.Body, passkeyBodyLimit)
	wu, cred, err := s.WebAuthn.FinishPasskeyLogin(handler, sd, r)
	if err != nil {
		fail()
		return
	}
	pu := wu.(*passkeyUser)
	// Persist the new sign counter and clone-warning flag.
	raw, _ := json.Marshal(cred)
	_, _ = s.Pool.Exec(r.Context(),
		`UPDATE passkey_credentials SET credential = $1, last_used_at = now() WHERE credential_id = $2`, raw, cred.ID)
	if cred.Authenticator.CloneWarning {
		s.logAudit(r.Context(), pu.id, "", "auth.passkey_clone_warning", "passkey sign counter went backwards", clientIP(r))
		writeError(w, http.StatusUnauthorized, "passkey could not be verified")
		return
	}

	var user models.User
	err = s.Pool.QueryRow(r.Context(), `
		SELECT id, family_id, email, name, role, totp_enabled, token_version, created_at, updated_at
		FROM users WHERE id = $1`, pu.id,
	).Scan(&user.ID, &user.FamilyID, &user.Email, &user.Name, &user.Role,
		&user.TOTPEnabled, &user.TokenVersion, &user.CreatedAt, &user.UpdatedAt)
	if err != nil {
		fail()
		return
	}
	familyID := ""
	if user.FamilyID != nil {
		familyID = *user.FamilyID
	}
	s.logAudit(r.Context(), user.ID, familyID, "auth.login", "passkey login for "+user.Email, clientIP(r))
	jti, err := newTokenID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to issue refresh token")
		return
	}
	if err := s.refreshSessions().Create(r.Context(), user.ID, jti, time.Now().Add(s.TM.RefreshTTL())); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to issue refresh token")
		return
	}
	s.tagSession(r, jti)
	s.issueTokens(w, user, jti, "") // no amr: admin MFA still needs a TOTP session
}

// ListPasskeys returns the caller's passkeys (never key material).
func (s *Server) ListPasskeys(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT id, name, created_at, last_used_at FROM passkey_credentials
		WHERE user_id = $1 ORDER BY created_at`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list passkeys")
		return
	}
	defer rows.Close()
	type item struct {
		ID         string     `json:"id"`
		Name       string     `json:"name"`
		CreatedAt  time.Time  `json:"created_at"`
		LastUsedAt *time.Time `json:"last_used_at"`
	}
	out := []item{}
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Name, &it.CreatedAt, &it.LastUsedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to list passkeys")
			return
		}
		out = append(out, it)
	}
	writeJSON(w, http.StatusOK, map[string]any{"enabled": s.WebAuthn != nil, "passkeys": out})
}

// DeletePasskey removes one of the caller's passkeys.
func (s *Server) DeletePasskey(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if _, err := uuidParse(id); err != nil {
		writeError(w, http.StatusNotFound, "passkey not found")
		return
	}
	tag, err := s.Pool.Exec(r.Context(),
		`DELETE FROM passkey_credentials WHERE id = $1 AND user_id = $2`, id, claims.UserID)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusInternalServerError, "failed to delete passkey")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "passkey not found")
		return
	}
	s.logAudit(r.Context(), claims.UserID, claims.FamilyID, "auth.passkey_removed", "passkey removed", clientIP(r))
	w.WriteHeader(http.StatusNoContent)
}
