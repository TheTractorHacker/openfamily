package handlers

import (
	"net"
	"net/http"
	"time"
)

const (
	loginPerIP     = 20
	loginPerEmail  = 8
	loginWindow    = 15 * time.Minute
	registerPerIP  = 5
	registerWindow = time.Hour
	refreshPerIP   = 60
	refreshWindow  = 15 * time.Minute
	joinPerIP      = 10
	joinWindow     = 15 * time.Minute

	// Previously unthrottled endpoints (BSEC-006).
	passwordFailsPerUser = 5
	passwordFailsWindow  = 15 * time.Minute
	deleteMePerUser      = 3
	deleteMeWindow       = time.Hour
	deviceCreatePerUser  = 10
	deviceCreateWindow   = time.Hour
	heartbeatPerUser     = 120
	heartbeatWindow      = time.Minute
	sharePerIP           = 60
	shareWindow          = time.Minute
)

// allowAuth records a hit against AuthLimit. When the limiter is nil (tests),
// the request is allowed. A 429 is written when the window is exhausted.
func (s *Server) allowAuth(w http.ResponseWriter, key string, max int, window time.Duration) bool {
	if s.AuthLimit == nil {
		return true
	}
	if s.AuthLimit.Allow(key, max, window) {
		return true
	}
	writeError(w, http.StatusTooManyRequests, "too many requests")
	return false
}

// allowKey is allowAuth for per-user keys.
func (s *Server) allowKey(w http.ResponseWriter, key string, max int, window time.Duration) bool {
	return s.allowAuth(w, key, max, window)
}

// limiterIP normalizes an address for use in a limiter key. IPv6 clients
// usually hold a whole /64, so they are keyed by it; otherwise one host could
// mint unlimited "different" addresses.
func limiterIP(ip string) string {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return ip
	}
	if v4 := parsed.To4(); v4 != nil {
		return v4.String()
	}
	return parsed.Mask(net.CIDRMask(64, 128)).String() + "/64"
}

func authIPKey(kind, ip string) string {
	return kind + ":ip:" + limiterIP(ip)
}

// authEmailKey scopes login failures to (email, ip): an attacker can only lock
// themselves out of an account, never the account's owner connecting from
// another address.
func authEmailKey(email, ip string) string {
	return "login:email:" + email + "|" + limiterIP(ip)
}

// loginBlocked reports (and answers 429) when this (email, ip) pair has used
// up its failed-login budget. It does not consume budget itself.
func (s *Server) loginBlocked(w http.ResponseWriter, key string) bool {
	if s.AuthLimit == nil || !s.AuthLimit.Exceeded(key, loginPerEmail, loginWindow) {
		return false
	}
	writeError(w, http.StatusTooManyRequests, "too many requests")
	return true
}

// loginFailed charges one failed attempt (wrong password, TOTP, unknown email
// all count alike so the limiter does not reveal which emails exist).
func (s *Server) loginFailed(key string) {
	if s.AuthLimit != nil {
		s.AuthLimit.Record(key, loginWindow)
	}
}

func (s *Server) loginSucceeded(key string) {
	if s.AuthLimit != nil {
		s.AuthLimit.Reset(key)
	}
}
