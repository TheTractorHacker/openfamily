package e2eebridge

// Server mode (docs/design/E2EE.md, "Trusted-server mode"): the bridge is the
// Orbitly server's own approved device. It verifies and decrypts exactly like
// a phone or the Dawarich bridge, then hands the plaintext positions to the
// Orbitly API (POST /internal/e2ee/ingest), authenticated by the server-device
// token, so the server's normal tables, map, history, geofencing and Dawarich
// sync work for the circles whose members all consented.

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// pointSink delivers verified positions (Dawarich or the Orbitly server).
type pointSink interface {
	flush(ctx context.Context, pts []point, hw map[string]int64, commit func() error) (sent int, dropped map[string]int64, err error)
	setBackoff(bo backoff)
}

func (d *dawarichSink) setBackoff(bo backoff) { d.bo = bo }

// errServerKeyGone: the API has no active server key with this id any more (it was revoked,
// for example when the owner account's keys were reset). Not an ingest-token problem.
var errServerKeyGone = errors.New("the Orbitly server no longer has an active key for this server (it was revoked)")

var errIngestAuth = errors.New("the Orbitly server refused the ingest token (401/404); check E2EE_SERVER_INGEST_TOKEN on both sides")

type serverSink struct {
	cfg  *config
	http *http.Client
	bo   backoff
	log  *slog.Logger
	dev  string // our device id
}

func newServerSink(cfg *config, deviceID string, log *slog.Logger) *serverSink {
	return &serverSink{cfg: cfg, http: &http.Client{Timeout: 60 * time.Second}, bo: defaultBackoff(), log: log, dev: deviceID}
}

func (s *serverSink) setBackoff(bo backoff) { s.bo = bo }

type ingestResp struct {
	Stored    int            `json:"stored"`
	Duplicate int            `json:"duplicate"`
	Rejected  map[string]int `json:"rejected"`
}

// call sends one JSON request with the token, retrying transient failures.
func (s *serverSink) call(ctx context.Context, method, path string, body any, out any) (int, error) {
	raw, _ := json.Marshal(body)
	var lastErr error
	for attempt := 0; attempt < s.bo.Attempts; attempt++ {
		req, _ := http.NewRequestWithContext(ctx, method, s.cfg.Ingest.URL+path, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+s.cfg.Ingest.token)
		resp, err := s.http.Do(req)
		var retryAfter time.Duration
		status := 0
		if err != nil {
			if ctx.Err() != nil {
				return 0, ctx.Err()
			}
			lastErr = fmt.Errorf("could not reach the Orbitly server: %w", scrubNetErr(err))
		} else {
			data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
			resp.Body.Close()
			status = resp.StatusCode
			retryAfter = parseRetryAfter(resp.Header.Get("Retry-After"))
			switch {
			case status >= 200 && status < 300:
				if out != nil {
					_ = json.Unmarshal(data, out)
				}
				return status, nil
			case status == 404 && strings.Contains(errText(data), "no active server key"):
				return status, errServerKeyGone
			case status == 401 || status == 404:
				return status, errIngestAuth
			case !retryableStatus(status):
				return status, &apiError{Status: status, Msg: errText(data)}
			}
			lastErr = fmt.Errorf("the Orbitly server answered %d", status)
		}
		if attempt+1 >= s.bo.Attempts {
			break
		}
		if err := s.bo.Sleep(ctx, s.bo.delay(attempt, retryAfter)); err != nil {
			return status, err
		}
	}
	return 0, fmt.Errorf("the Orbitly server is unavailable after %d attempts: %w", s.bo.Attempts, lastErr)
}

func errText(data []byte) string {
	var e struct {
		Error string `json:"error"`
		Code  string `json:"code"`
	}
	if json.Unmarshal(data, &e) == nil && e.Error != "" {
		return e.Code + " " + e.Error
	}
	return "unexpected answer"
}

// pin tells the server which key is its own device. Idempotent.
func (s *serverSink) pin(ctx context.Context) error {
	_, err := s.call(ctx, http.MethodPut, "/internal/e2ee/server-device", map[string]string{"device_id": s.dev}, nil)
	return err
}

func (s *serverSink) flush(ctx context.Context, pts []point, hw map[string]int64, commit func() error) (int, map[string]int64, error) {
	dropped := map[string]int64{}
	byCircle := map[string][]point{}
	var circles []string
	for _, p := range pts {
		if _, ok := byCircle[p.circle]; !ok {
			circles = append(circles, p.circle)
		}
		byCircle[p.circle] = append(byCircle[p.circle], p)
	}
	sort.Strings(circles)
	sent := 0
	for _, c := range circles {
		list := byCircle[c]
		sort.SliceStable(list, func(i, j int) bool { return list[i].tsMs < list[j].tsMs })
		for i := 0; i < len(list); i += 500 {
			batch := list[i:min(i+500, len(list))]
			in := make([]map[string]any, len(batch))
			for j, p := range batch {
				m := map[string]any{"kind": p.kind, "user_id": p.user, "sender_device_id": p.device, "ts_ms": p.tsMs, "lat": p.lat, "lon": p.lon}
				if p.acc != nil {
					m["acc"] = *p.acc
				}
				if p.alt != nil {
					m["alt"] = *p.alt
				}
				if p.spd != nil {
					m["spd"] = *p.spd
				}
				if p.batt != nil {
					m["bat"] = *p.batt
				}
				in[j] = m
			}
			var res ingestResp
			if _, err := s.call(ctx, http.MethodPost, "/internal/e2ee/ingest",
				map[string]any{"circle_id": c, "server_device_id": s.dev, "points": in}, &res); err != nil {
				return sent, dropped, err
			}
			sent += res.Stored
			dropped["duplicate"] += int64(res.Duplicate)
			for k, v := range res.Rejected {
				dropped["server_"+k] += int64(v)
			}
			if err := commit(); err != nil {
				return sent, dropped, err
			}
		}
	}
	return sent, dropped, nil
}

// ---- consents, verified independently of the server

type consentWire struct {
	UserID           string `json:"user_id"`
	ApproverDeviceID string `json:"approver_device_id"`
	Signature        string `json:"signature"`
}

// verifiedConsents returns the members whose consent for THIS server key and this
// circle verifies against a phone key that the verified key log vouches for.
func (b *bridge) verifiedConsents(circle string, st *circleState, wire []consentWire) map[string]bool {
	ok := map[string]bool{}
	for _, c := range wire {
		dev, mem := st.device(c.ApproverDeviceID)
		if dev == nil || mem == nil || mem.UserID != c.UserID || dev.Kind != "device" {
			continue
		}
		if b.trust(st).AuthorizeSender(dev, mem) != nil {
			continue
		}
		pub, err1 := base64.StdEncoding.DecodeString(dev.Ed25519Pub)
		sig, err2 := base64.StdEncoding.DecodeString(c.Signature)
		if err1 != nil || err2 != nil {
			continue
		}
		if e2ee.VerifyServerConsent(ed25519.PublicKey(pub), circle, c.UserID, b.id.f.DeviceID, b.id.fp, sig) == nil {
			ok[c.UserID] = true
		}
	}
	return ok
}

// consentsComplete: EVERY member of the circle has a verified consent (a member
// without a phone key cannot consent, so the circle stays closed). A circle that is not complete is not read at all.
func consentsComplete(st *circleState, ok map[string]bool) (missing []string) {
	for _, m := range st.Members {
		if !ok[m.UserID] {
			missing = append(missing, m.UserID)
		}
	}
	return missing
}
