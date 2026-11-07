package e2eebridge

// OpenFamily API client: login/refresh with a rotating refresh token that is
// persisted atomically after every rotation (access tokens live in memory only),
// and robust retry (exponential backoff with jitter, Retry-After, 5xx/429/network).

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	// errReauth: the refresh token no longer works; the user must log in again.
	errReauth = errors.New("the OpenFamily session is no longer valid: re-run `e2ee-bridge enroll` with --email to log in again")
	// errNoApproved: the server refuses to serve ciphertext to this key.
	errNoApproved = errors.New("the server reports no approved device key for this circle (the bridge was revoked, or its key is no longer approved)")
)

// apiError is an HTTP error answer from OpenFamily.
type apiError struct {
	Status int
	Code   string
	Msg    string
}

func (e *apiError) Error() string {
	if e.Code != "" {
		return fmt.Sprintf("server answered %d (%s): %s", e.Status, e.Code, e.Msg)
	}
	return fmt.Sprintf("server answered %d: %s", e.Status, e.Msg)
}

// backoff computes retry delays.
type backoff struct {
	Base, Max time.Duration
	Attempts  int
	Sleep     func(ctx context.Context, d time.Duration) error
}

func defaultBackoff() backoff {
	return backoff{Base: time.Second, Max: 60 * time.Second, Attempts: 6, Sleep: sleepCtx}
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// delay is min(Max, Base*2^attempt) with full jitter in [d/2, d], raised to the
// server's Retry-After when it is larger (but at most 10 minutes).
func (b backoff) delay(attempt int, retryAfter time.Duration) time.Duration {
	d := b.Base << min(attempt, 20)
	if d > b.Max || d <= 0 {
		d = b.Max
	}
	d = d/2 + time.Duration(rand.Int64N(int64(d/2)+1))
	if retryAfter > d {
		d = min(retryAfter, 10*time.Minute)
	}
	return d
}

func parseRetryAfter(h string) time.Duration {
	if h == "" {
		return 0
	}
	if n, err := strconv.Atoi(strings.TrimSpace(h)); err == nil && n >= 0 {
		return time.Duration(n) * time.Second
	}
	if t, err := http.ParseTime(h); err == nil {
		if d := time.Until(t); d > 0 {
			return d
		}
	}
	return 0
}

// retryable reports whether an HTTP status is worth retrying.
func retryableStatus(s int) bool { return s == 429 || s >= 500 || s == 408 }

type apiClient struct {
	base string
	http *http.Client
	bo   backoff

	mu      sync.Mutex
	access  string
	refresh string
	onRot   func(newRefresh string) error // persists the rotated refresh token
	// mint, when set, replaces the refresh-token login: the API's built-in server
	// device asks its host process for a short-lived access token.
	mint func(ctx context.Context) (string, error)
	// onStatus, when set, hears about every non-2xx answer (built-in device logging).
	onStatus func(method, path string, status int)
}

func newAPIClient(base string, refresh string, onRotate func(string) error) *apiClient {
	return &apiClient{
		base: strings.TrimRight(base, "/"), http: &http.Client{Timeout: 30 * time.Second},
		bo: defaultBackoff(), refresh: refresh, onRot: onRotate,
	}
}

type tokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

// send performs one request attempt with retry on transient failures. It
// returns status, body.
func (c *apiClient) send(ctx context.Context, method, path string, body []byte, bearer string) (int, []byte, error) {
	var lastErr error
	for attempt := 0; ; attempt++ {
		var rd io.Reader
		if body != nil {
			rd = bytes.NewReader(body)
		}
		req, err := http.NewRequestWithContext(ctx, method, c.base+path, rd)
		if err != nil {
			return 0, nil, err
		}
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		var retryAfter time.Duration
		resp, err := c.http.Do(req)
		if err == nil && c.onStatus != nil && (resp.StatusCode < 200 || resp.StatusCode >= 300) {
			c.onStatus(method, path, resp.StatusCode)
		}
		if err == nil {
			data, rerr := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
			resp.Body.Close()
			if rerr == nil && !retryableStatus(resp.StatusCode) {
				return resp.StatusCode, data, nil
			}
			if rerr != nil {
				err = rerr
			} else {
				err = fmt.Errorf("server answered %d", resp.StatusCode)
				retryAfter = parseRetryAfter(resp.Header.Get("Retry-After"))
				if attempt+1 >= c.bo.Attempts {
					return resp.StatusCode, data, nil
				}
			}
		}
		lastErr = scrubNetErr(err)
		if ctx.Err() != nil {
			return 0, nil, ctx.Err()
		}
		if attempt+1 >= c.bo.Attempts {
			return 0, nil, fmt.Errorf("giving up after %d attempts: %w", attempt+1, lastErr)
		}
		if err := c.bo.Sleep(ctx, c.bo.delay(attempt, retryAfter)); err != nil {
			return 0, nil, err
		}
	}
}

func decodeAPIError(status int, data []byte) *apiError {
	var e struct {
		Error string `json:"error"`
		Code  string `json:"code"`
	}
	_ = json.Unmarshal(data, &e)
	msg := e.Error
	if msg == "" {
		msg = http.StatusText(status)
	}
	return &apiError{Status: status, Code: e.Code, Msg: msg}
}

// login exchanges credentials for a token pair and remembers the refresh token.
func (c *apiClient) login(ctx context.Context, email, password, totp string) error {
	b, _ := json.Marshal(map[string]string{"email": email, "password": password, "totp_code": totp})
	st, data, err := c.send(ctx, http.MethodPost, "/auth/login", b, "")
	if err != nil {
		return err
	}
	if st != http.StatusOK {
		return decodeAPIError(st, data)
	}
	var tp tokenPair
	if err := json.Unmarshal(data, &tp); err != nil || tp.AccessToken == "" || tp.RefreshToken == "" {
		return errors.New("unexpected login answer")
	}
	c.mu.Lock()
	c.access, c.refresh = tp.AccessToken, tp.RefreshToken
	c.mu.Unlock()
	if c.onRot != nil {
		return c.onRot(tp.RefreshToken)
	}
	return nil
}

// refreshAccess rotates the refresh token. The new token is persisted BEFORE it
// is used, so a crash can never leave only a consumed token on disk.
func (c *apiClient) refreshAccess(ctx context.Context, stale string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if stale != "" && c.access != stale && c.access != "" {
		return nil // someone else refreshed meanwhile
	}
	if c.mint != nil {
		tok, err := c.mint(ctx)
		if err != nil {
			return err
		}
		c.access = tok
		return nil
	}
	if c.refresh == "" {
		return errReauth
	}
	b, _ := json.Marshal(map[string]string{"refresh_token": c.refresh})
	st, data, err := c.send(ctx, http.MethodPost, "/auth/refresh", b, "")
	if err != nil {
		return err
	}
	if st == http.StatusUnauthorized || st == http.StatusForbidden {
		return errReauth
	}
	if st != http.StatusOK {
		return decodeAPIError(st, data)
	}
	var tp tokenPair
	if err := json.Unmarshal(data, &tp); err != nil || tp.AccessToken == "" || tp.RefreshToken == "" {
		return errors.New("unexpected refresh answer")
	}
	if c.onRot != nil {
		if err := c.onRot(tp.RefreshToken); err != nil {
			return fmt.Errorf("could not persist the rotated refresh token: %w", err)
		}
	}
	c.access, c.refresh = tp.AccessToken, tp.RefreshToken
	return nil
}

// do performs an authenticated request, decoding a 2xx JSON answer into out.
// A 401 triggers exactly one refresh and one retry.
func (c *apiClient) do(ctx context.Context, method, path string, in, out any) error {
	var body []byte
	if in != nil {
		var err error
		if body, err = json.Marshal(in); err != nil {
			return err
		}
	}
	refreshed := false
	for {
		c.mu.Lock()
		tok := c.access
		c.mu.Unlock()
		if tok == "" {
			if err := c.refreshAccess(ctx, ""); err != nil {
				return err
			}
			refreshed = true
			continue
		}
		st, data, err := c.send(ctx, method, path, body, tok)
		if err != nil {
			return err
		}
		if st == http.StatusUnauthorized {
			if refreshed {
				return errReauth
			}
			if err := c.refreshAccess(ctx, tok); err != nil {
				return err
			}
			refreshed = true
			continue
		}
		if st >= 200 && st < 300 {
			if out != nil && len(data) > 0 {
				if err := json.Unmarshal(data, out); err != nil {
					return fmt.Errorf("unexpected answer from %s: %w", path, err)
				}
			}
			return nil
		}
		ae := decodeAPIError(st, data)
		if st == http.StatusForbidden && ae.Code == "no_approved_device" {
			return fmt.Errorf("%w: %v", errNoApproved, ae)
		}
		return ae
	}
}

// scrubNetErr drops the URL a *url.Error carries (it can hold query strings).
func scrubNetErr(err error) error {
	var ue *url.Error
	if errors.As(err, &ue) {
		return ue.Err
	}
	return err
}
