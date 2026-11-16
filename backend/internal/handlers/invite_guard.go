package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"time"
)

// Invite-code brute-force guard. The per-IP limiter alone is not enough: an
// attacker with many addresses (or an IPv6 range) can spread guesses, and a
// guessed code that is merely used-up or expired must not be distinguishable
// from an unknown one. Failed redemptions are therefore also counted per code
// (the same code cannot be hammered), per signed-in user, and across the whole
// server (a distributed guess run hits a ceiling). Only FAILURES are charged,
// so legitimate joins are not slowed down. The in-memory limiter resets on
// restart, like the other auth limiters.
const (
	inviteFailPerCode   = 5
	inviteFailPerUser   = 10
	inviteFailGlobal    = 600
	inviteFailWindow    = 15 * time.Minute
	inviteFailGlobalWin = time.Hour
)

func inviteCodeKey(code string) string {
	h := sha256.Sum256([]byte(code))
	return "invite:fail:code:" + hex.EncodeToString(h[:8])
}

func inviteUserKey(uid string) string { return "invite:fail:user:" + uid }

const inviteGlobalKey = "invite:fail:global"

// inviteLocked answers 429 (generic text) when this code, this user, or the
// server as a whole has used up its failed-redemption budget. It consumes
// nothing. uid may be empty (sign-up).
func (s *Server) inviteLocked(w http.ResponseWriter, code, uid string) bool {
	l := s.AuthLimit
	if l == nil {
		return false
	}
	if l.Exceeded(inviteCodeKey(code), inviteFailPerCode, inviteFailWindow) ||
		(uid != "" && l.Exceeded(inviteUserKey(uid), inviteFailPerUser, inviteFailWindow)) ||
		l.Exceeded(inviteGlobalKey, inviteFailGlobal, inviteFailGlobalWin) {
		writeError(w, http.StatusTooManyRequests, "too many attempts, try again later")
		return true
	}
	return false
}

// inviteFailed charges one failed redemption (unknown, expired and used-up
// codes all count alike).
func (s *Server) inviteFailed(code, uid string) {
	l := s.AuthLimit
	if l == nil {
		return
	}
	l.Record(inviteCodeKey(code), inviteFailWindow)
	if uid != "" {
		l.Record(inviteUserKey(uid), inviteFailWindow)
	}
	l.Record(inviteGlobalKey, inviteFailGlobalWin)
}

// inviteGenericMsg is the one message every failed redemption gets, so a
// guesser cannot tell an unknown code from an expired or used-up one.
const inviteGenericMsg = "invalid invite code"
