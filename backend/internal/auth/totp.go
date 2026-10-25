package auth

import (
	"crypto/subtle"
	"fmt"
	"strings"
	"time"

	"github.com/pquerna/otp"
	"github.com/pquerna/otp/hotp"
	"github.com/pquerna/otp/totp"
)

// GenerateTOTPSecret creates a new TOTP secret for a user and returns the
// base32 secret plus a provisioning URI for the authenticator app.
func GenerateTOTPSecret(issuer, account string) (secret string, uri string, err error) {
	key, err := totp.Generate(totp.GenerateOpts{
		Issuer:      issuer,
		AccountName: account,
	})
	if err != nil {
		return "", "", fmt.Errorf("generate totp: %w", err)
	}
	return key.Secret(), key.URL(), nil
}

// ValidateTOTP checks a user-supplied code against a stored base32 secret.
func ValidateTOTP(secret, code string) bool {
	return totp.Validate(code, secret)
}

// ValidateTOTPWithSkew checks a code allowing a small time-step skew.
func ValidateTOTPWithSkew(secret, code string, skew uint) bool {
	ok, err := totp.ValidateCustom(code, secret, time.Now(), totp.ValidateOpts{Skew: skew})
	if err != nil {
		return false
	}
	return ok
}

// TOTPPeriod is the RFC 6238 time step in seconds.
const TOTPPeriod = 30

// MatchTOTPStep returns the time step (unix/30) for which code is valid,
// accepting one step of clock skew either side of now. The caller must record
// the returned step and reject any step <= the last accepted one: that is the
// replay guard (a code, or any older code, works at most once).
func MatchTOTPStep(secret, code string, now time.Time) (int64, bool) {
	code = strings.TrimSpace(code)
	if len(code) != 6 {
		return 0, false
	}
	cur := now.Unix() / TOTPPeriod
	// Prefer the newest matching step so a fresh code advances the guard.
	for _, step := range []int64{cur + 1, cur, cur - 1} {
		want, err := hotp.GenerateCodeCustom(secret, uint64(step), hotp.ValidateOpts{Digits: otp.DigitsSix, Algorithm: otp.AlgorithmSHA1})
		if err != nil {
			return 0, false
		}
		if subtle.ConstantTimeCompare([]byte(want), []byte(code)) == 1 {
			return step, true
		}
	}
	return 0, false
}
