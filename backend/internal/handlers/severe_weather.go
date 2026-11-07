package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/config"
)

// Severe-weather pushes. Every 15 minutes the server asks the free US National
// Weather Service alerts API about each coarse (0.1 degree, roughly 11 km)
// area where someone in the US was recently seen, and pushes Severe and
// Extreme alerts to the people in that area who have the category on. Each
// person only ever hears about their OWN area: the push names the alert, never
// another person or any coordinates. NWS sees only the rounded area, never a
// name or an account. Set SEVERE_WEATHER=off to disable the worker.

const (
	nwsBase            = "https://api.weather.gov"
	weatherEvery       = 15 * time.Minute
	weatherMaxCells    = 60  // NWS lookups per pass
	weatherMaxPushes   = 200 // pushes per pass
	weatherSeenDefault = 24 * time.Hour
	weatherZeroUser    = "00000000-0000-0000-0000-000000000000" // "sender": excludes nobody
)

type nwsAlert struct {
	ID       string
	Event    string
	Severity string
	Headline string
	Expires  time.Time
}

type nwsFeatures struct {
	Features []struct {
		Properties struct {
			ID          string `json:"id"`
			Event       string `json:"event"`
			Severity    string `json:"severity"`
			Headline    string `json:"headline"`
			Status      string `json:"status"`
			MessageType string `json:"messageType"`
			Expires     string `json:"expires"`
		} `json:"properties"`
	} `json:"features"`
}

// parseSevereAlerts keeps only real (not test/exercise, not cancelled)
// Severe and Extreme alerts from an NWS /alerts/active response.
func parseSevereAlerts(body []byte) ([]nwsAlert, error) {
	var f nwsFeatures
	if err := json.Unmarshal(body, &f); err != nil {
		return nil, err
	}
	var out []nwsAlert
	for _, ft := range f.Features {
		p := ft.Properties
		if p.ID == "" || (p.Severity != "Severe" && p.Severity != "Extreme") {
			continue
		}
		if p.Status != "" && p.Status != "Actual" {
			continue
		}
		if p.MessageType == "Cancel" {
			continue
		}
		a := nwsAlert{ID: p.ID, Event: p.Event, Severity: p.Severity, Headline: p.Headline}
		if t, err := time.Parse(time.RFC3339, p.Expires); err == nil {
			a.Expires = t
		}
		out = append(out, a)
	}
	return out, nil
}

type weatherUser struct{ id, family string }

// weatherCell rounds a coordinate to 0.1 degree; the key is what NWS is asked.
func weatherCell(lat, lon float64) (key string, rlat, rlon float64) {
	rlat = math.Round(lat*10) / 10
	rlon = math.Round(lon*10) / 10
	return fmt.Sprintf("%.1f,%.1f", rlat, rlon), rlat, rlon
}

type weatherWorker struct {
	baseURL string
	client  *http.Client
	ua      string
	pause   time.Duration // spacing between NWS requests
	// push delivers one alert to one user; returns whether it was sent.
	push func(ctx context.Context, u weatherUser, title, body string) bool

	mu   sync.Mutex
	seen map[string]time.Time // userID|alertID -> forget after
}

func newWeatherWorker(push func(context.Context, weatherUser, string, string) bool) *weatherWorker {
	return &weatherWorker{
		baseURL: nwsBase,
		client:  &http.Client{Timeout: 10 * time.Second},
		ua:      "Orbitly/" + config.BuildVersion() + " (self-hosted location sharing; https://github.com/TheTractorHacker/orbitly)",
		pause:   time.Second,
		push:    push,
		seen:    map[string]time.Time{},
	}
}

func (w *weatherWorker) fetch(ctx context.Context, lat, lon float64) ([]nwsAlert, error) {
	u := fmt.Sprintf("%s/alerts/active?point=%.1f,%.1f", w.baseURL, lat, lon)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", w.ua)
	req.Header.Set("Accept", "application/geo+json")
	resp, err := w.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK { // 404/400 outside NWS coverage
		return nil, fmt.Errorf("nws: status %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return nil, err
	}
	return parseSevereAlerts(b)
}

// run looks up each cell and pushes alerts not yet sent to a user.
func (w *weatherWorker) run(ctx context.Context, cells map[string][]weatherUser, now time.Time) (pushed int) {
	w.mu.Lock()
	for k, until := range w.seen {
		if now.After(until) {
			delete(w.seen, k)
		}
	}
	w.mu.Unlock()

	looked := 0
	for key, users := range cells {
		if looked >= weatherMaxCells || pushed >= weatherMaxPushes || ctx.Err() != nil {
			break
		}
		var lat, lon float64
		if _, err := fmt.Sscanf(key, "%f,%f", &lat, &lon); err != nil {
			continue
		}
		if looked > 0 && w.pause > 0 {
			select {
			case <-ctx.Done():
				return pushed
			case <-time.After(w.pause):
			}
		}
		looked++
		alerts, err := w.fetch(ctx, lat, lon)
		if err != nil {
			slog.Debug("severe weather: lookup", "err", err)
			continue
		}
		for _, a := range alerts {
			title := "Severe weather: " + a.Event
			body := strings.TrimSpace(a.Headline)
			if len(body) > 200 {
				body = body[:200]
			}
			until := a.Expires
			if until.IsZero() || until.Before(now) {
				until = now.Add(weatherSeenDefault)
			}
			for _, u := range users {
				if pushed >= weatherMaxPushes {
					return pushed
				}
				k := u.id + "|" + a.ID
				w.mu.Lock()
				_, dup := w.seen[k]
				if !dup {
					w.seen[k] = until
				}
				w.mu.Unlock()
				if dup {
					continue
				}
				if w.push(ctx, u, title, body) {
					pushed++
				}
			}
		}
	}
	return pushed
}

// weatherCells lists recently seen US users who have severe_weather on,
// grouped by coarse area.
func (s *Server) weatherCells(ctx context.Context) (map[string][]weatherUser, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT mp.user_id::text, COALESCE(u.family_id::text, ''), mp.lat, mp.lon
		FROM member_positions mp JOIN users u ON u.id = mp.user_id
		WHERE mp.updated_at > now() - interval '6 hours' AND NOT e2ee_keeps_data_on_phone(mp.user_id)
		  AND mp.lat BETWEEN 17 AND 72 AND mp.lon BETWEEN -180 AND -65`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	muted := s.usersMuted(ctx, "severe_weather")
	cells := map[string][]weatherUser{}
	for rows.Next() {
		var u weatherUser
		var lat, lon float64
		if err := rows.Scan(&u.id, &u.family, &lat, &lon); err != nil {
			return nil, err
		}
		if muted[u.id] || u.family == "" {
			continue
		}
		key, _, _ := weatherCell(lat, lon)
		cells[key] = append(cells[key], u)
	}
	return cells, rows.Err()
}

// RunSevereWeather is the background worker; it returns at once when disabled.
func (s *Server) RunSevereWeather(ctx context.Context) {
	if strings.EqualFold(os.Getenv("SEVERE_WEATHER"), "off") || s.Push == nil {
		return
	}
	w := newWeatherWorker(func(ctx context.Context, u weatherUser, title, body string) bool {
		sent, _ := s.pushFamilyAlertOnly(ctx, u.family, weatherZeroUser, "", title, body,
			"severe_weather", map[string]bool{u.id: true})
		return sent > 0
	})
	timer := time.NewTimer(2 * time.Minute)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		pctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
		if cells, err := s.weatherCells(pctx); err != nil {
			slog.Warn("severe weather: list areas", "err", err)
		} else if n := w.run(pctx, cells, time.Now()); n > 0 {
			slog.Info("severe weather: pushed", "alerts", n)
		}
		cancel()
		timer.Reset(weatherEvery)
	}
}
