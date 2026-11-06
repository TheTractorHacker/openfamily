package main

// Dawarich delivery. The mapping matches backend/internal/handlers/dawarich.go:
// POST {base}/api/v1/points with Bearer auth and
// {"locations":[GeoJSON Feature ...]}, batches of 500, optional LAN fallback.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"time"
)

const dawarichBatch = 500

// point is one validated position ready for delivery.
type point struct {
	tgt       target
	name      string // member display name -> properties.device_id
	device    string // sender device id -> properties.unique_id
	tsMs      int64
	lat, lon  float64
	acc, alt  *float64
	spd, batt *float64
}

func (p point) feature() map[string]any {
	props := map[string]any{
		"timestamp": time.UnixMilli(p.tsMs).UTC().Format(time.RFC3339),
		"device_id": p.name,
		"unique_id": p.device,
	}
	if p.acc != nil {
		props["horizontal_accuracy"] = *p.acc
	}
	if p.alt != nil {
		props["altitude"] = *p.alt
	}
	if p.spd != nil {
		props["speed"] = *p.spd
	}
	if p.batt != nil {
		props["battery_level"] = *p.batt / 100
	}
	return map[string]any{
		"type":       "Feature",
		"geometry":   map[string]any{"type": "Point", "coordinates": []float64{p.lon, p.lat}},
		"properties": props,
	}
}

// errDawarichAuth: Dawarich refuses the API key (config problem, stop).
var errDawarichAuth = errors.New("Dawarich refused the API key (401/403); fix the key in the bridge config")

// floor is what Dawarich already holds for an account.
type floor struct {
	queried bool
	known   bool
	tsSec   int64
	name    string // device name of the newest point, when Dawarich exposes one
	hasName bool
}

type dawarichSink struct {
	cfg    *config
	http   *http.Client
	bo     backoff
	log    *slog.Logger
	now    func() time.Time
	floors map[string]*floor
}

func newSink(cfg *config, log *slog.Logger) *dawarichSink {
	return &dawarichSink{cfg: cfg, http: &http.Client{Timeout: 60 * time.Second}, bo: defaultBackoff(), log: log,
		now: time.Now, floors: map[string]*floor{}}
}

func (d *dawarichSink) bases() []string {
	out := []string{d.cfg.Dawarich.BaseURL}
	if l := d.cfg.Dawarich.LocalURL; l != "" && l != d.cfg.Dawarich.BaseURL {
		out = append(out, l)
	}
	return out
}

// queryFloor asks Dawarich for the newest existing point of the account. Any
// failure or unexpected shape is "unknown" (local state still protects).
func (d *dawarichSink) queryFloor(ctx context.Context, key string) *floor {
	f := &floor{queried: true}
	start := d.cfg.since
	if start.IsZero() {
		start = d.now().Add(-90 * 24 * time.Hour)
	}
	q := url.Values{}
	q.Set("start_at", start.UTC().Format(time.RFC3339))
	q.Set("end_at", d.now().Add(24*time.Hour).UTC().Format(time.RFC3339))
	q.Set("per_page", "1")
	q.Set("order", "desc")
	for _, base := range d.bases() {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/api/v1/points?"+q.Encode(), nil)
		if err != nil {
			continue
		}
		req.Header.Set("Authorization", "Bearer "+key)
		resp, err := d.http.Do(req)
		if err != nil {
			continue
		}
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return f
		}
		if ts, name, hasName, ok := parseNewestPoint(data); ok {
			f.known, f.tsSec, f.name, f.hasName = true, ts, name, hasName
		}
		return f
	}
	return f
}

// parseNewestPoint adapts tolerantly to what Dawarich may answer: a JSON array
// of points, or an object wrapping one under points/data/items.
func parseNewestPoint(data []byte) (tsSec int64, name string, hasName, ok bool) {
	var arr []map[string]any
	if json.Unmarshal(data, &arr) != nil {
		var obj map[string]json.RawMessage
		if json.Unmarshal(data, &obj) != nil {
			return
		}
		for _, k := range []string{"points", "data", "items", "locations"} {
			if raw, found := obj[k]; found && json.Unmarshal(raw, &arr) == nil {
				break
			}
		}
	}
	if len(arr) == 0 {
		return
	}
	p := arr[0]
	for _, k := range []string{"timestamp", "tracked_at", "recorded_at"} {
		if v, found := p[k]; found {
			if ts, good := toUnixSec(v); good {
				tsSec, ok = ts, true
				break
			}
		}
	}
	if !ok {
		return
	}
	for _, k := range []string{"device_id", "tracker_id", "unique_id"} {
		if s, isStr := p[k].(string); isStr && s != "" {
			if _, err := strconv.Atoi(s); err != nil { // a numeric id is not a name
				name, hasName = s, true
				break
			}
		}
	}
	return
}

func toUnixSec(v any) (int64, bool) {
	switch x := v.(type) {
	case float64:
		if x > 1e11 { // milliseconds
			return int64(x / 1000), true
		}
		return int64(x), x > 0
	case string:
		if n, err := strconv.ParseFloat(x, 64); err == nil {
			return toUnixSec(n)
		}
		if t, err := time.Parse(time.RFC3339, x); err == nil {
			return t.Unix(), true
		}
	}
	return 0, false
}

// applies reports whether the account's newest point bounds this person.
func (f *floor) applies(t target, name string) bool {
	if !f.known {
		return false
	}
	if f.hasName {
		return f.name == name
	}
	return t.perUser
}

// flush delivers the points. It filters (since, per-device high-water, Dawarich
// floor, duplicates), sorts by time, posts in batches of 500 and raises the
// per-device high-water mark (persisted through commit) after EACH successful
// batch. dropped counts points not sent, by reason.
func (d *dawarichSink) flush(ctx context.Context, pts []point, hw map[string]int64, commit func() error) (sent int, dropped map[string]int64, err error) {
	dropped = map[string]int64{}
	byKey := map[string][]point{}
	var keys []string
	for _, p := range pts {
		if _, ok := byKey[p.tgt.key]; !ok {
			keys = append(keys, p.tgt.key)
		}
		byKey[p.tgt.key] = append(byKey[p.tgt.key], p)
	}
	sort.Strings(keys)
	for _, key := range keys {
		list := byKey[key]
		sort.SliceStable(list, func(i, j int) bool { return list[i].tsMs < list[j].tsMs })
		out := d.filter(list, hw, nil, dropped)
		if len(out) == 0 {
			continue
		}
		// Ask Dawarich what it already has, once per start and account, and only
		// when something would really be sent.
		fl := d.floors[key]
		if fl == nil {
			fl = d.queryFloor(ctx, key)
			d.floors[key] = fl
			if !fl.known {
				d.log.Info("dawarich: newest existing point unknown, relying on local state", "target", list[0].tgt.label)
			}
		}
		out = d.filter(out, hw, fl, dropped)
		for i := 0; i < len(out); i += dawarichBatch {
			batch := out[i:min(i+dawarichBatch, len(out))]
			feats := make([]map[string]any, len(batch))
			for j, p := range batch {
				feats[j] = p.feature()
			}
			body, _ := json.Marshal(map[string]any{"locations": feats})
			ok, perr := d.post(ctx, key, body)
			if perr != nil {
				return sent, dropped, perr
			}
			if !ok { // Dawarich rejected the batch for good (4xx): do not wedge on it
				dropped["rejected_by_dawarich"] += int64(len(batch))
			} else {
				sent += len(batch)
			}
			for _, p := range batch {
				if p.tsMs > hw[p.device] {
					hw[p.device] = p.tsMs
				}
			}
			if cerr := commit(); cerr != nil {
				return sent, dropped, cerr
			}
		}
	}
	return sent, dropped, nil
}

// filter applies since, the per-device delivery marks, Dawarich's newest point
// (when known) and in-batch duplicate removal. The input is sorted by time.
func (d *dawarichSink) filter(list []point, hw map[string]int64, fl *floor, dropped map[string]int64) []point {
	var out []point
	seen := map[string]bool{}
	for _, p := range list {
		id := p.device + "/" + strconv.FormatInt(p.tsMs, 10)
		switch {
		case !d.cfg.since.IsZero() && p.tsMs < d.cfg.since.UnixMilli():
			dropped["older_than_since"]++
		case p.tsMs <= hw[p.device]:
			dropped["already_sent"]++
		case fl != nil && fl.applies(p.tgt, p.name) && p.tsMs/1000 <= fl.tsSec:
			dropped["already_in_dawarich"]++
		case seen[id]:
			dropped["duplicate"]++
		default:
			seen[id] = true
			out = append(out, p)
		}
	}
	return out
}

// post sends one batch. (true,nil) = stored; (false,nil) = permanently refused
// (4xx other than auth); error = retry later (transient, after retries) or
// errDawarichAuth.
func (d *dawarichSink) post(ctx context.Context, key string, body []byte) (bool, error) {
	var lastErr error
	for attempt := 0; attempt < d.bo.Attempts; attempt++ {
		var retryAfter time.Duration
		status := 0
		// An unreachable address falls through to the next; an HTTP answer does not.
		for _, base := range d.bases() {
			req, _ := http.NewRequestWithContext(ctx, http.MethodPost, base+"/api/v1/points", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Authorization", "Bearer "+key)
			resp, err := d.http.Do(req)
			if err != nil {
				if ctx.Err() != nil {
					return false, ctx.Err()
				}
				lastErr = fmt.Errorf("could not reach Dawarich: %w", scrubNetErr(err))
				continue
			}
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
			resp.Body.Close()
			status = resp.StatusCode
			retryAfter = parseRetryAfter(resp.Header.Get("Retry-After"))
			break
		}
		switch {
		case status >= 200 && status < 300:
			return true, nil
		case status == 401 || status == 403:
			return false, errDawarichAuth
		case status != 0 && !retryableStatus(status):
			d.log.Warn("dawarich refused a batch", "status", status)
			return false, nil
		case status != 0:
			lastErr = fmt.Errorf("Dawarich answered %d", status)
		}
		if attempt+1 >= d.bo.Attempts {
			break
		}
		if err := d.bo.Sleep(ctx, d.bo.delay(attempt, retryAfter)); err != nil {
			return false, err
		}
	}
	return false, fmt.Errorf("Dawarich unavailable after %d attempts: %w", d.bo.Attempts, lastErr)
}
