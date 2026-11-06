package handlers

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// Pushes for the optional notification categories low_battery and
// completed_drives. Both go only to people who share a circle with the
// subject in which the subject shares their location and has not paused
// sharing, and both honour the recipient's own switch (notification_prefs)
// and their per-member settings (member_notification_prefs, incl. quiet
// hours). SOS and help alerts are untouched and stay always-on.

const (
	lowBatteryBelow = 20.0 // percent: crossing under this notifies once
	lowBatteryReset = 30.0 // percent: back above this re-arms the alert
	lowBatteryEvery = 3 * time.Hour

	driveMinMeters  = 800.0
	driveMinSeconds = 120.0
	driveLookback   = 30 * time.Minute
)

// EnsureNotifyEventsSchema creates the small de-duplication tables. Idempotent;
// not a numbered migration so it cannot collide with concurrent work.
func (s *Server) EnsureNotifyEventsSchema(ctx context.Context) error {
	if _, err := s.Pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS low_battery_notified (
			user_id      UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
			last_sent_at TIMESTAMPTZ NOT NULL
		)`); err != nil {
		return err
	}
	_, err := s.Pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS drive_notified (
			trip_id     UUID PRIMARY KEY REFERENCES trips(id) ON DELETE CASCADE,
			notified_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)`)
	return err
}

// sharingRecipients returns the users who may be told about subjectID: members
// of a circle the subject shares their location in, unless sharing is paused.
func (s *Server) sharingRecipients(ctx context.Context, subjectID string) (map[string]bool, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT DISTINCT v.user_id::text
		FROM circle_members s
		JOIN circle_members v ON v.circle_id = s.circle_id AND v.user_id <> s.user_id
		WHERE s.user_id = $1 AND s.sharing_enabled
		  AND NOT `+pausedExprSQL("s.user_id"), subjectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = true
	}
	return out, rows.Err()
}

// notifySharers pushes about subjectID to the people allowed to hear it.
// category is the recipient-level switch (notification_prefs); memberCat the
// per-member category ("" for none).
func (s *Server) notifySharers(ctx context.Context, subjectID, title, body, category, memberCat string) (sent, failed int) {
	return s.notifySharersRender(ctx, subjectID, category, memberCat, fixedRender(title, body))
}

// notifySharersRender is notifySharers with the copy rendered per recipient, so
// the subject's name only reaches recipients who opted in (or VERBOSE_PUSH).
func (s *Server) notifySharersRender(ctx context.Context, subjectID, category, memberCat string, render pushRender) (sent, failed int) {
	if s.Push == nil {
		return 0, 0
	}
	familyID, err := s.familyIDForUser(ctx, subjectID)
	if err != nil || familyID == "" {
		return 0, 0
	}
	only, err := s.sharingRecipients(ctx, subjectID)
	if err != nil {
		slog.Warn("notify: list recipients", "err", err)
		return 0, 0
	}
	if memberCat != "" {
		for uid := range notifSuppressed(ctx, s.Pool, subjectID, memberCat, time.Now()) {
			delete(only, uid)
		}
	}
	if len(only) == 0 {
		return 0, 0
	}
	return s.pushFamilyAlertRender(ctx, familyID, subjectID, "", category, only, render)
}

// formatDistanceWhole is formatDistance rounded to whole units.
func formatDistanceWhole(m float64, units string) string {
	if units == "metric" {
		return fmt.Sprintf("%.0f km", m/1000)
	}
	return fmt.Sprintf("%.0f mi", m/1609.344)
}

// ---- low battery ----------------------------------------------------------

// batteryTracker remembers, per user, whether their battery is currently under
// the alert line, so a drop is announced once and not on every fix.
type batteryTracker struct {
	mu    sync.Mutex
	below map[string]bool
}

var lowBattery = &batteryTracker{below: map[string]bool{}}

// crossed reports whether this reading is a fresh drop under the alert line.
func (t *batteryTracker) crossed(user string, pct float64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if pct > lowBatteryReset {
		delete(t.below, user)
		return false
	}
	if pct < lowBatteryBelow && !t.below[user] {
		t.below[user] = true
		return true
	}
	return false
}

// noteBattery is called after a live location is stored. It is cheap (a map
// lookup) on every fix and only does work when the battery newly drops low.
func (s *Server) noteBattery(ownerID string, pct *float64) {
	if pct == nil || *pct <= 0 { // 0 means "unknown" from some devices
		return
	}
	v := *pct
	if !lowBattery.crossed(ownerID, v) {
		return
	}
	postCommitRunner.Submit(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		s.notifyLowBattery(ctx, ownerID, v)
	})
}

func (s *Server) notifyLowBattery(ctx context.Context, ownerID string, pct float64) {
	// At most one push per person per lowBatteryEvery, even across restarts.
	var one int
	err := s.Pool.QueryRow(ctx, `
		INSERT INTO low_battery_notified (user_id, last_sent_at) VALUES ($1, now())
		ON CONFLICT (user_id) DO UPDATE SET last_sent_at = now()
		WHERE low_battery_notified.last_sent_at < now() - $2::interval
		RETURNING 1`, ownerID, fmt.Sprintf("%d seconds", int(lowBatteryEvery.Seconds()))).Scan(&one)
	if errors.Is(err, pgx.ErrNoRows) {
		return
	}
	if err != nil {
		slog.Warn("low battery: claim", "err", err)
		return
	}
	var name string
	_ = s.Pool.QueryRow(ctx, `SELECT name FROM users WHERE id = $1`, ownerID).Scan(&name)
	s.haEnqueue(ctx, "low_battery", ownerID, fmt.Sprintf("lowbat:%s:%d", ownerID, time.Now().Unix()), "", "", "", time.Now(),
		map[string]any{"battery_pct": int(pct)})
	s.notifySharersRender(ctx, ownerID, "low_battery", notifLowBattery, func(rc pushRecipient) (string, string) {
		who := nameIf(rc.Show, name)
		return who + "'s battery is low", fmt.Sprintf("%s's phone is at %d%%.", who, int(pct))
	})
}

// ---- completed drives -----------------------------------------------------

func driveBody(distM, durS float64, units string) string {
	return fmt.Sprintf("%s, %d min", formatDistance(distM, units), int((durS+30)/60))
}

// formatDistance writes metres in the recipient's unit system with one decimal.
func formatDistance(m float64, units string) string {
	if units == "metric" {
		return fmt.Sprintf("%.1f km", m/1000)
	}
	return fmt.Sprintf("%.1f mi", m/1609.344)
}

// RunDriveNotifier announces drives the trip worker has just finished.
func (s *Server) RunDriveNotifier(ctx context.Context) {
	timer := time.NewTimer(time.Minute)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		s.notifyCompletedDrives(ctx)
		timer.Reset(2 * time.Minute)
	}
}

func (s *Server) notifyCompletedDrives(ctx context.Context) {
	rows, err := s.Pool.Query(ctx, `
		SELECT t.id::text, t.user_id::text, u.name, t.distance_m,
		       EXTRACT(EPOCH FROM (t.ended_at - t.started_at))
		FROM trips t JOIN users u ON u.id = t.user_id
		WHERE t.mode = 'driving' AND t.ended_at > now() - $1::interval
		  AND t.distance_m >= $2
		  AND EXTRACT(EPOCH FROM (t.ended_at - t.started_at)) >= $3
		  AND NOT EXISTS (SELECT 1 FROM drive_notified n WHERE n.trip_id = t.id)
		ORDER BY t.ended_at LIMIT 50`,
		fmt.Sprintf("%d seconds", int(driveLookback.Seconds())), driveMinMeters, driveMinSeconds)
	if err != nil {
		slog.Warn("drive notify: list trips", "err", err)
		return
	}
	type drive struct {
		trip, user, name string
		distM, durS      float64
	}
	var ds []drive
	for rows.Next() {
		var d drive
		if rows.Scan(&d.trip, &d.user, &d.name, &d.distM, &d.durS) == nil {
			ds = append(ds, d)
		}
	}
	rows.Close()
	for _, d := range ds {
		tag, err := s.Pool.Exec(ctx,
			`INSERT INTO drive_notified (trip_id) VALUES ($1) ON CONFLICT DO NOTHING`, d.trip)
		if err != nil || tag.RowsAffected() != 1 {
			continue
		}
		d := d
		s.notifySharersRender(ctx, d.user, "completed_drives", notifDriving, func(rc pushRecipient) (string, string) {
			return nameIf(rc.Show, d.name) + " completed a drive", driveBody(d.distM, d.durS, rc.Units)
		})
	}
}
