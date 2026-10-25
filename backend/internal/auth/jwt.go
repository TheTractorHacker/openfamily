package auth

import (
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// TokenType distinguishes access and refresh tokens.
type TokenType string

const (
	AccessToken  TokenType = "access"
	RefreshToken TokenType = "refresh"
)

// Claims is the JWT payload for both access and refresh tokens.
type Claims struct {
	UserID       string    `json:"uid"`
	FamilyID     string    `json:"fid,omitempty"`
	TokenType    TokenType `json:"typ"`
	TokenVersion int       `json:"ver"`
	jwt.RegisteredClaims
}

// TokenManager issues and validates JWTs.
type TokenManager struct {
	secret     []byte
	accessTTL  time.Duration
	refreshTTL time.Duration
}

// NewTokenManager builds a TokenManager from a signing secret and TTLs.
func NewTokenManager(secret string, accessTTL, refreshTTL time.Duration) *TokenManager {
	return &TokenManager{
		secret:     []byte(secret),
		accessTTL:  accessTTL,
		refreshTTL: refreshTTL,
	}
}

// IssueAccess creates a short-lived access token for a user.
func (m *TokenManager) IssueAccess(userID, familyID string, tokenVersion int) (string, error) {
	return m.issue(userID, familyID, tokenVersion, AccessToken, m.accessTTL)
}

// AccessTTL returns the configured access-token lifetime, for reporting the
// token's expires_in to clients.
func (m *TokenManager) AccessTTL() time.Duration {
	return m.accessTTL
}

// IssueRefresh creates a long-lived refresh token for a user.
func (m *TokenManager) IssueRefresh(userID, familyID string, tokenVersion int) (string, error) {
	return m.issue(userID, familyID, tokenVersion, RefreshToken, m.refreshTTL)
}

// IssueRefreshWithID creates a refresh token carrying a unique token id (jti).
// The id is what the server tracks to make refresh tokens single-use. Tokens
// from IssueRefresh carry no jti and are treated as legacy by the refresh
// endpoint.
func (m *TokenManager) IssueRefreshWithID(userID, familyID string, tokenVersion int, jti string) (string, error) {
	return m.issueWithID(userID, familyID, tokenVersion, RefreshToken, m.refreshTTL, jti)
}

// RefreshTTL returns the configured refresh-token lifetime.
func (m *TokenManager) RefreshTTL() time.Duration { return m.refreshTTL }

func (m *TokenManager) issue(userID, familyID string, tokenVersion int, typ TokenType, ttl time.Duration) (string, error) {
	return m.issueWithID(userID, familyID, tokenVersion, typ, ttl, "")
}

func (m *TokenManager) issueWithID(userID, familyID string, tokenVersion int, typ TokenType, ttl time.Duration, jti string) (string, error) {
	now := time.Now()
	claims := Claims{
		UserID:       userID,
		FamilyID:     familyID,
		TokenType:    typ,
		TokenVersion: tokenVersion,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    "openfamily",
			Subject:   userID,
			ID:        jti,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(m.secret)
}

// Parse validates a token and returns its claims, enforcing the expected type.
func (m *TokenManager) Parse(tokenString string, want TokenType) (*Claims, error) {
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenString, claims, func(t *jwt.Token) (any, error) {
		// Pin to HS256 exactly: reject any other algorithm (including other
		// HMAC variants like HS384/HS512) to prevent algorithm confusion.
		if t.Method != jwt.SigningMethodHS256 {
			return nil, fmt.Errorf("unexpected signing method %v", t.Header["alg"])
		}
		return m.secret, nil
	})
	if err != nil {
		return nil, err
	}
	if !token.Valid {
		return nil, errors.New("invalid token")
	}
	if claims.TokenType != want {
		return nil, fmt.Errorf("wrong token type: got %q want %q", claims.TokenType, want)
	}
	return claims, nil
}
