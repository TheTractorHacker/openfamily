package handlers

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/push"
)

// geofenceDebounceInterval is the minimum time between fired notifications for
// the same geofence+user. It suppresses boundary-oscillation spam where a
// device jittering at the radius edge would otherwise fire an event+push on
// every flip.
//
// Unlike a naive "drop the transition" debounce, a single suppressed transition
// is left PENDING (notified_inside != inside) and is fired by the reconcile
// worker once the window elapses, so a genuine transition is not permanently
// lost. A rapid reversal within the debounce window (e.g. exit then re-enter
// before the window elapses) is intentionally dropped: the pending transition
// is superseded and the state syncs back, so no stale alert fires.
const geofenceDebounceInterval = 60 * time.Second

// geofenceReconcileInterval is how often the background reconciliation worker
// runs: it re-evaluates the latest point per user, fires pending (debounced)
// transitions whose window elapsed, and re-dispatches pushes that failed.
const geofenceReconcileInterval = 60 * time.Second

// pushRetryAttempts is how many times a failed push dispatch is retried before
// giving up, and pushRetryBackoff is the delay between attempts. Retrying
// transient network failures keeps a single blip from permanently losing the
// alert.
const (
	pushRetryAttempts = 3
	pushRetryBackoff  = 2 * time.Second
)

// maxPushAttempts is the total number of dispatch attempts (initial + redispatch)
// per device before the device is dead-lettered, so a permanently-failing token
// does not retry forever.
const maxPushAttempts = 3

// pushRedispatchMinAge is how old an event must be before the reconcile worker
// re-dispatches its failed pushes. The initial dispatch is sequential with a
// per-device timeout (pushDispatchTimeout), so its worst-case wall time is
// (number of recipient devices) × pushDispatchTimeout. This min-age is set
// comfortably above that worst case for a large family, so a just-created event
// whose dispatch is still in flight is never re-selected (which would
// double-dispatch).
const pushRedispatchMinAge = 15 * time.Minute

// pushDispatchTimeout is the per-device budget for a single dispatch (including
// retries). Each device gets its own timeout so a large family is not truncated
// by a single shared deadline.
const pushDispatchTimeout = 30 * time.Second

// geofenceCandidate is a geofence that may have been crossed by a point.
type geofenceCandidate struct {
	geofenceID  string
	enterNotify bool
	exitNotify  bool
}

// evaluateGeofences runs after a location point is stored. It determines, for
// each enabled geofence in the user's family, whether the point is inside the
// geofence's place radius, detects enter/exit transitions against the stored
// state, records events, and dispatches push notifications.
//
// Durability: evaluation is best-effort and runs after the ingest has already
// returned 201, so a failure here does not fail the ingest. Failures are logged
// loudly, and the background ReconcileGeofences worker re-evaluates the latest
// point per user on a timer, so a transient failure is self-healed on the next
// pass. A crash between the location INSERT and evaluation is likewise healed
// by the worker.
func (s *Server) evaluateGeofences(ctx context.Context, userID string, lon, lat float64, ts time.Time) {
	familyID, err := s.familyIDForUser(ctx, userID)
	if err != nil {
		slog.Error("geofence: resolve family", "user_id", userID, "err", err)
		return
	}
	if familyID == "" {
		return
	}

	// Single query: join places + geofences to find candidate geofences. A
	// geofence is a candidate when EITHER the point is inside its radius (a
	// possible enter) OR its stored state is currently inside (a possible exit)
	// OR it has no state yet (its FIRST point, which must be recorded as the
	// baseline regardless of inside/outside). The inside/outside result is still
	// re-computed later, inside processGeofence's transaction (under the
	// geofence-row lock), so a concurrent place geometry/radius change cannot
	// leave stale state. Geofences whose place has no geometry or no radius are
	// skipped.
	//
	// A family-wide geofence (user_id IS NULL) is skipped when a user-specific
	// geofence exists for the same place+user, so a place cannot fire duplicate
	// alerts from both a family-wide and a per-user geofence.
	rows, err := s.Pool.Query(ctx, `
		SELECT g.id, g.enter_notify, g.exit_notify
		FROM geofences g
		JOIN places p ON p.id = g.place_id
		LEFT JOIN geofence_states s ON s.geofence_id = g.id AND s.user_id = $2
		WHERE g.enabled = TRUE
		  AND g.family_id = $1
		  AND (g.user_id = $2 OR (g.user_id IS NULL AND NOT EXISTS (
		      SELECT 1 FROM geofences g2
		      WHERE g2.place_id = g.place_id AND g2.user_id = $2 AND g2.enabled = TRUE
		  )))
		  AND p.geom IS NOT NULL
		  AND p.radius_meters IS NOT NULL
		  AND (ST_DWithin(p.geom::geography, ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography, p.radius_meters)
		       OR s.inside = TRUE
		       OR s.geofence_id IS NULL)`,
		familyID, userID, lon, lat)
	if err != nil {
		slog.Error("geofence: query candidates", "user_id", userID, "err", err)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var c geofenceCandidate
		if err := rows.Scan(&c.geofenceID, &c.enterNotify, &c.exitNotify); err != nil {
			slog.Error("geofence: scan candidate", "user_id", userID, "err", err)
			return
		}
		s.processGeofence(ctx, userID, familyID, c, lon, lat, ts)
	}
	if err := rows.Err(); err != nil {
		slog.Error("geofence: iterate candidates", "user_id", userID, "err", err)
	}
}

// processGeofence compares the point's inside/outside result against the
// stored state and, on a change, records an event and dispatches a push. The
// read, state update, and event insert run in a single transaction that locks
// the geofence row, serializing concurrent ingests and coordinating with
// disable/delete.
//
// Pending-notification model: `inside` always reflects current reality, while
// `notified_inside` tracks the last state that was actually notified. A
// notifiable transition either fires immediately (debounce elapsed), is left
// PENDING (debounce not elapsed; `inside` advances but `notified_inside` does
// not), or is a no-op (already notified this state). A NON-notifiable
// transition silently syncs `notified_inside = inside` (no notification, no
// debounce, no last_notified_at update) so the family's belief tracks reality
// for the non-notified direction and a later notifiable transition back is
// correctly seen as pending.
func (s *Server) processGeofence(ctx context.Context, userID, familyID string, c geofenceCandidate, lon, lat float64, ts time.Time) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		slog.Error("geofence: begin tx", "geofence_id", c.geofenceID, "err", err)
		return
	}
	defer tx.Rollback(ctx)

	// Lock the geofence row to serialize concurrent evaluations and to
	// coordinate with disable/delete/reassignment. Re-check enabled, family,
	// user assignment, and place_id inside the lock so a concurrent change
	// cannot write state for the wrong user, family, or place.
	var enabled bool
	var gfUserID *string
	var gfFamilyID string
	var gfPlaceID string
	err = tx.QueryRow(ctx, `SELECT enabled, user_id, family_id, place_id FROM geofences WHERE id = $1 FOR UPDATE`, c.geofenceID).Scan(&enabled, &gfUserID, &gfFamilyID, &gfPlaceID)
	if errors.Is(err, pgx.ErrNoRows) {
		_ = tx.Commit(ctx) // geofence deleted concurrently
		return
	}
	if err != nil {
		slog.Error("geofence: lock geofence", "geofence_id", c.geofenceID, "err", err)
		return
	}
	if !enabled {
		_ = tx.Commit(ctx) // disabled concurrently
		return
	}
	if gfFamilyID != familyID || (gfUserID != nil && *gfUserID != userID) {
		_ = tx.Commit(ctx) // reassigned to another family/user concurrently
		return
	}

	// Re-compute inside/outside under the geofence-row lock using the place's
	// CURRENT id and geometry (re-read under the lock, not the candidate query's
	// possibly-stale place_id). The candidate query's ST_DWithin pre-filter ran
	// outside any lock, so a concurrent place reassignment or geometry/radius
	// change (which locks the geofence rows during its state reset) could
	// otherwise leave stale state or record the event against the old place.
	var inside bool
	var placeName string
	err = tx.QueryRow(ctx, `
		SELECT ST_DWithin(p.geom::geography, ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography, p.radius_meters), COALESCE(p.name, '')
		FROM places p
		WHERE p.id = $3 AND p.geom IS NOT NULL AND p.radius_meters IS NOT NULL`,
		lon, lat, gfPlaceID).Scan(&inside, &placeName)
	if errors.Is(err, pgx.ErrNoRows) {
		_ = tx.Commit(ctx) // place no longer alertable (geometry/radius removed)
		return
	}
	if err != nil {
		slog.Error("geofence: recompute inside", "geofence_id", c.geofenceID, "err", err)
		return
	}

	// Read the current state. The debounce-elapsed flag is computed with the
	// DB's now() (not the app host's clock) so a split DB/app host cannot
	// miscalculate the window.
	var prevInside bool
	var notifiedInside *bool
	var lastSeenTs *time.Time
	var pendingTS *time.Time
	var pendingLon, pendingLat *float64
	var debounceElapsed bool
	err = tx.QueryRow(ctx, `
		SELECT inside, notified_inside, last_seen_ts, pending_ts, pending_lon, pending_lat,
		       (last_notified_at IS NULL OR last_notified_at <= now() - ($3 * interval '1 second'))
		FROM geofence_states
		WHERE geofence_id = $1 AND user_id = $2`,
		c.geofenceID, userID, geofenceDebounceInterval.Seconds()).Scan(&prevInside, &notifiedInside, &lastSeenTs, &pendingTS, &pendingLon, &pendingLat, &debounceElapsed)
	if errors.Is(err, pgx.ErrNoRows) {
		// First observation: record the baseline. If the first point is OUTSIDE,
		// record notified_inside=FALSE (the family believes "outside"), so a later
		// entry fires "arrived". If INSIDE, record notified_inside=NULL (no
		// "arrived" on the first point, since we do not know when they arrived).
		var baselineNotified any
		if !inside {
			baselineNotified = false
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO geofence_states (geofence_id, user_id, inside, notified_inside, last_notified_at, last_seen_ts)
			VALUES ($1, $2, $3, $4, NULL, $5)
			ON CONFLICT (geofence_id, user_id) DO NOTHING`,
			c.geofenceID, userID, inside, baselineNotified, ts); err != nil {
			slog.Error("geofence: insert state", "geofence_id", c.geofenceID, "err", err)
			return
		}
		if err := tx.Commit(ctx); err != nil {
			slog.Error("geofence: commit", "geofence_id", c.geofenceID, "err", err)
		}
		return
	}
	if err != nil {
		slog.Error("geofence: read state", "geofence_id", c.geofenceID, "err", err)
		return
	}

	// Skip a stale point: a concurrent ingest may have advanced the state with
	// a newer point between the reconcile read and this lock, so re-applying an
	// older point would produce a spurious transition.
	if lastSeenTs != nil && ts.Before(*lastSeenTs) {
		_ = tx.Commit(ctx)
		return
	}

	if prevInside == inside {
		// No transition, but advance last_seen_ts so a later stale point is
		// still detected.
		if _, err := tx.Exec(ctx, `
			UPDATE geofence_states SET last_seen_ts = $3 WHERE geofence_id = $1 AND user_id = $2`,
			c.geofenceID, userID, ts); err != nil {
			slog.Error("geofence: update last seen", "geofence_id", c.geofenceID, "err", err)
			return
		}
		_ = tx.Commit(ctx)
		return
	}

	// Transition detected.
	eventType := "exit"
	if inside {
		eventType = "enter"
	}
	notifiable := (inside && c.enterNotify) || (!inside && c.exitNotify)

	// A pending transition exists when the family's belief (notified_inside)
	// differs from the previous reality (prevInside): the user moved but the
	// family was never told.
	hasPending := notifiedInside != nil && *notifiedInside != prevInside

	// Decide the action: fire the current transition, leave it pending, fire the
	// OLD pending transition (then leave the current one pending), or sync.
	fire := false
	pending := false
	firePending := false
	if notifiable {
		alreadyNotified := notifiedInside != nil && *notifiedInside == inside
		if alreadyNotified && hasPending {
			// The user returned to the previously-notified state, but there was a
			// pending transition in between. If the debounce has elapsed, fire that
			// pending transition so the family learns the user left (the current
			// transition then becomes pending). If the debounce has NOT elapsed,
			// the whole back-and-forth is a rapid reversal within the window and is
			// intentionally dropped (sync below). Never silently sync a pending
			// transition away once the debounce has elapsed.
			if debounceElapsed {
				firePending = true
			}
		} else if !alreadyNotified {
			if debounceElapsed {
				fire = true
			} else {
				pending = true
			}
		}
		// else: alreadyNotified && !hasPending — sync (advance inside only).
	}
	// else: non-notifiable — advance inside AND sync notified_inside = inside.

	// Advance `inside` (always) and `last_seen_ts`. Fire marks notified; pending
	// stores the transition's ts/location; firePending fires the OLD pending
	// transition and leaves the current one pending; otherwise sync
	// notified_inside and clear any stale pending metadata.
	switch {
	case firePending:
		if _, err := tx.Exec(ctx, `
			UPDATE geofence_states
			SET inside = $3, notified_inside = $4, last_notified_at = now(),
			    pending_ts = $5, pending_lon = $6, pending_lat = $7, last_seen_ts = $5
			WHERE geofence_id = $1 AND user_id = $2`,
			c.geofenceID, userID, inside, prevInside, ts, lon, lat); err != nil {
			slog.Error("geofence: update state", "geofence_id", c.geofenceID, "err", err)
			return
		}
	case fire:
		if _, err := tx.Exec(ctx, `
			UPDATE geofence_states
			SET inside = $3, notified_inside = $3, last_notified_at = now(),
			    pending_ts = NULL, pending_lon = NULL, pending_lat = NULL, last_seen_ts = $4
			WHERE geofence_id = $1 AND user_id = $2`,
			c.geofenceID, userID, inside, ts); err != nil {
			slog.Error("geofence: update state", "geofence_id", c.geofenceID, "err", err)
			return
		}
	case pending:
		if _, err := tx.Exec(ctx, `
			UPDATE geofence_states
			SET inside = $3, pending_ts = $4, pending_lon = $5, pending_lat = $6, last_seen_ts = $4
			WHERE geofence_id = $1 AND user_id = $2`,
			c.geofenceID, userID, inside, ts, lon, lat); err != nil {
			slog.Error("geofence: update state", "geofence_id", c.geofenceID, "err", err)
			return
		}
	default:
		if _, err := tx.Exec(ctx, `
			UPDATE geofence_states
			SET inside = $3, notified_inside = $3, pending_ts = NULL, pending_lon = NULL, pending_lat = NULL, last_seen_ts = $4
			WHERE geofence_id = $1 AND user_id = $2`,
			c.geofenceID, userID, inside, ts); err != nil {
			slog.Error("geofence: update state", "geofence_id", c.geofenceID, "err", err)
			return
		}
	}

	if !fire && !firePending {
		if err := tx.Commit(ctx); err != nil {
			slog.Error("geofence: commit", "geofence_id", c.geofenceID, "err", err)
		}
		return
	}

	// Fire (the current transition, or the OLD pending transition): record the
	// event AND its per-device delivery rows in the same transaction as the
	// state update, so a crash cannot mark notified without persisting both the
	// event and its delivery targets.
	fireEventType := eventType
	var fireTS any = ts
	var fireLon any = lon
	var fireLat any = lat
	if firePending {
		// The pending transition is the opposite direction; use its original
		// ts/location (nullable).
		fireEventType = "enter"
		if eventType == "enter" {
			fireEventType = "exit"
		}
		fireTS = pendingTS
		fireLon = pendingLon
		fireLat = pendingLat
	}

	var eventID string
	err = tx.QueryRow(ctx, `
		INSERT INTO geofence_events (geofence_id, user_id, place_id, event_type, ts, location)
		VALUES ($1, $2, $3, $4, COALESCE($5, now()), ST_SetSRID(ST_MakePoint($6, $7), 4326))
		RETURNING id`,
		c.geofenceID, userID, gfPlaceID, fireEventType, fireTS, fireLon, fireLat).Scan(&eventID)
	if err != nil {
		slog.Error("geofence: insert event", "geofence_id", c.geofenceID, "err", err)
		return
	}

	if err := s.createEventDeviceRows(ctx, tx, eventID, userID, familyID); err != nil {
		slog.Error("geofence: create device rows", "event_id", eventID, "err", err)
		return
	}

	if err := tx.Commit(ctx); err != nil {
		slog.Error("geofence: commit", "geofence_id", c.geofenceID, "err", err)
		return
	}

	s.dispatchGeofencePush(eventID, userID, placeName, fireEventType)
}

// ReconcileGeofences runs a background loop that, on a timer, re-evaluates the
// latest location point per user, fires pending (debounced) transitions, and
// re-dispatches failed pushes. It blocks until ctx is cancelled.
func (s *Server) ReconcileGeofences(ctx context.Context) {
	ticker := time.NewTicker(geofenceReconcileInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.reconcileGeofencesOnce(ctx)
		}
	}
}

// reconcileGeofencesOnce performs one reconciliation pass.
func (s *Server) reconcileGeofencesOnce(ctx context.Context) {
	s.reconcileLatestPoints(ctx)
	s.firePendingNotifications(ctx)
	s.redispatchFailedPushes(ctx)
}

// reconcileLookback bounds which users the reconcile pass revisits: only those
// whose last stored point is newer than this. Idle or offline users have no
// pending work (ingest evaluates every point, and firePendingNotifications
// covers elapsed debounces), so they are skipped instead of re-evaluated
// every minute forever.
const reconcileLookback = 24 * time.Hour

// reconcileLatestPointsSQL reads each user's latest point from member_positions
// (one row per user, maintained on every stored point) rather than running
// DISTINCT ON over the whole locations hypertable (PERF-001). The ts predicate
// bounds the work to recently active users. $1 is the lookback in seconds.
const reconcileLatestPointsSQL = `
	SELECT user_id, lon, lat, ts
	FROM member_positions
	WHERE ts > now() - make_interval(secs => $1::float8)`

// reconcileLatestPoints re-evaluates the latest point for each user. Only the
// latest point is re-evaluated so the pass is idempotent: that point is already
// reflected in the stored state, so re-evaluating it produces no transition.
// (Re-evaluating a window of older points would flip state back and forth and
// re-fire events on every pass.)
func (s *Server) reconcileLatestPoints(ctx context.Context) {
	rows, err := s.Pool.Query(ctx, reconcileLatestPointsSQL, reconcileLookback.Seconds())
	if err != nil {
		slog.Error("geofence: reconcile query", "err", err)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var userID string
		var lon, lat float64
		var ts time.Time
		if err := rows.Scan(&userID, &lon, &lat, &ts); err != nil {
			slog.Error("geofence: reconcile scan", "err", err)
			continue
		}
		s.evaluateGeofences(ctx, userID, lon, lat, ts)
	}
	if err := rows.Err(); err != nil {
		slog.Error("geofence: reconcile iterate", "err", err)
	}
}

// firePendingNotifications fires any PENDING transition (notified_inside !=
// inside) whose debounce window has elapsed. This recovers transitions that
// were suppressed by the debounce during ingest, and is idempotent: once fired,
// notified_inside == inside and the row is no longer selected.
func (s *Server) firePendingNotifications(ctx context.Context) {
	rows, err := s.Pool.Query(ctx, `
		SELECT s.geofence_id, s.user_id, g.family_id
		FROM geofence_states s
		JOIN geofences g ON g.id = s.geofence_id
		WHERE s.notified_inside IS NOT NULL
		  AND s.notified_inside IS DISTINCT FROM s.inside
		  AND g.enabled = TRUE
		  AND ((s.inside AND g.enter_notify) OR (NOT s.inside AND g.exit_notify))
		  AND s.last_notified_at <= now() - ($1 * interval '1 second')`,
		geofenceDebounceInterval.Seconds())
	if err != nil {
		slog.Error("geofence: query pending", "err", err)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var geofenceID, userID, familyID string
		if err := rows.Scan(&geofenceID, &userID, &familyID); err != nil {
			slog.Error("geofence: scan pending", "err", err)
			continue
		}
		s.firePendingNotification(ctx, geofenceID, userID, familyID)
	}
	if err := rows.Err(); err != nil {
		slog.Error("geofence: iterate pending", "err", err)
	}
}

// firePendingNotification fires a single pending transition, re-checking the
// pending state, debounce window, enabled flag, and notify flags under the
// geofence-row lock (the SAME lock processGeofence takes) so the two serialize.
func (s *Server) firePendingNotification(ctx context.Context, geofenceID, userID, familyID string) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		slog.Error("geofence: begin pending tx", "geofence_id", geofenceID, "err", err)
		return
	}
	defer tx.Rollback(ctx)

	// Lock the geofence row (same lock as processGeofence) and re-check
	// enabled, family, user, place_id, and notify flags inside the lock.
	var enabled, enterNotify, exitNotify bool
	var gfUserID *string
	var gfFamilyID string
	var gfPlaceID string
	err = tx.QueryRow(ctx, `
		SELECT enabled, user_id, family_id, place_id, enter_notify, exit_notify
		FROM geofences WHERE id = $1 FOR UPDATE`,
		geofenceID).Scan(&enabled, &gfUserID, &gfFamilyID, &gfPlaceID, &enterNotify, &exitNotify)
	if errors.Is(err, pgx.ErrNoRows) {
		_ = tx.Commit(ctx)
		return
	}
	if err != nil {
		slog.Error("geofence: lock pending geofence", "geofence_id", geofenceID, "err", err)
		return
	}
	if !enabled {
		_ = tx.Commit(ctx)
		return
	}
	if gfFamilyID != familyID || (gfUserID != nil && *gfUserID != userID) {
		_ = tx.Commit(ctx)
		return
	}

	// Re-read the place name under the geofence-row lock (the place_id was
	// re-read above), so a concurrent place reassignment cannot record the
	// event against a stale place.
	var gfPlaceName string
	err = tx.QueryRow(ctx, `SELECT COALESCE(name, '') FROM places WHERE id = $1`, gfPlaceID).Scan(&gfPlaceName)
	if errors.Is(err, pgx.ErrNoRows) {
		gfPlaceName = "" // place deleted; buildNotification falls back to "a place"
	} else if err != nil {
		slog.Error("geofence: load place name", "geofence_id", geofenceID, "err", err)
		return
	}

	// Read the state (no separate lock needed; the geofence-row lock serializes
	// with processGeofence). The debounce-active flag is computed with the DB's
	// now() so a split DB/app host cannot miscalculate the window.
	var inside bool
	var notifiedInside *bool
	var pendingTS *time.Time
	var pendingLon, pendingLat *float64
	var debounceActive bool
	err = tx.QueryRow(ctx, `
		SELECT inside, notified_inside, pending_ts, pending_lon, pending_lat,
		       (last_notified_at IS NOT NULL AND last_notified_at > now() - ($3 * interval '1 second'))
		FROM geofence_states
		WHERE geofence_id = $1 AND user_id = $2`,
		geofenceID, userID, geofenceDebounceInterval.Seconds()).Scan(&inside, &notifiedInside, &pendingTS, &pendingLon, &pendingLat, &debounceActive)
	if errors.Is(err, pgx.ErrNoRows) {
		_ = tx.Commit(ctx)
		return
	}
	if err != nil {
		slog.Error("geofence: read pending state", "geofence_id", geofenceID, "err", err)
		return
	}

	// Re-check: still pending (never-notified first observations are NOT
	// pending), debounce elapsed, and the current direction is notifiable.
	if notifiedInside == nil {
		_ = tx.Commit(ctx) // first observation, never notified — not pending
		return
	}
	if *notifiedInside == inside {
		_ = tx.Commit(ctx) // already notified (e.g. user returned)
		return
	}
	if debounceActive {
		_ = tx.Commit(ctx) // debounce not yet elapsed
		return
	}
	notifiable := (inside && enterNotify) || (!inside && exitNotify)
	if !notifiable {
		_ = tx.Commit(ctx) // direction no longer notifiable
		return
	}

	eventType := "exit"
	if inside {
		eventType = "enter"
	}

	// Fire: record the event (using the pending transition's original ts and
	// location when available), its per-device delivery rows, and mark notified
	// in the same transaction.
	var eventID string
	err = tx.QueryRow(ctx, `
		INSERT INTO geofence_events (geofence_id, user_id, place_id, event_type, ts, location)
		VALUES ($1, $2, $3, $4, COALESCE($5, now()), ST_SetSRID(ST_MakePoint($6, $7), 4326))
		RETURNING id`,
		geofenceID, userID, gfPlaceID, eventType, pendingTS, pendingLon, pendingLat).Scan(&eventID)
	if err != nil {
		slog.Error("geofence: insert pending event", "geofence_id", geofenceID, "err", err)
		return
	}

	if err := s.createEventDeviceRows(ctx, tx, eventID, userID, familyID); err != nil {
		slog.Error("geofence: create device rows", "event_id", eventID, "err", err)
		return
	}

	if _, err := tx.Exec(ctx, `
		UPDATE geofence_states
		SET notified_inside = $3, last_notified_at = now(),
		    pending_ts = NULL, pending_lon = NULL, pending_lat = NULL
		WHERE geofence_id = $1 AND user_id = $2`,
		geofenceID, userID, inside); err != nil {
		slog.Error("geofence: mark notified", "geofence_id", geofenceID, "err", err)
		return
	}

	if err := tx.Commit(ctx); err != nil {
		slog.Error("geofence: commit pending", "geofence_id", geofenceID, "err", err)
		return
	}

	s.dispatchGeofencePush(eventID, userID, gfPlaceName, eventType)
}

// redispatchFailedPushes re-dispatches the push for any device whose delivery
// failed (push_sent=false), so a network failure or crash does not permanently
// lose the alert. Each device is re-dispatched at most maxPushAttempts times in
// total before being dead-lettered. Only events old enough that their initial
// dispatch has completed (and whose geofence is still enabled) are re-selected,
// so a just-created event is never double-dispatched.
func (s *Server) redispatchFailedPushes(ctx context.Context) {
	if s.Push == nil {
		return
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT d.event_id, d.device_id, dev.platform, dev.push_token, dev.unifiedpush_endpoint,
		       e.user_id, e.event_type, COALESCE(p.name, '')
		FROM geofence_event_devices d
		JOIN geofence_events e ON e.id = d.event_id
		JOIN geofences g ON g.id = e.geofence_id
		LEFT JOIN places p ON p.id = e.place_id
		JOIN devices dev ON dev.id = d.device_id
		JOIN users tracked ON tracked.id = e.user_id
		JOIN users recipient ON recipient.id = dev.user_id
		WHERE d.push_sent = FALSE
		  AND d.push_attempts < $1
		  AND g.enabled = TRUE
		  AND tracked.family_id = g.family_id
		  AND recipient.family_id = g.family_id
		  AND e.created_at < now() - ($2 * interval '1 second')`,
		maxPushAttempts, pushRedispatchMinAge.Seconds())
	if err != nil {
		slog.Error("geofence: query failed pushes", "err", err)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var eventID, deviceID, platform, userID, eventType, placeName string
		var pushToken, unifiedPushEndpoint *string
		if err := rows.Scan(&eventID, &deviceID, &platform, &pushToken, &unifiedPushEndpoint, &userID, &eventType, &placeName); err != nil {
			slog.Error("geofence: scan failed push", "err", err)
			continue
		}
		// Count this re-dispatch attempt before dispatching so a permanently
		// failing token is dead-lettered after the cap.
		if _, err := s.Pool.Exec(ctx, `
			UPDATE geofence_event_devices SET push_attempts = push_attempts + 1
			WHERE event_id = $1 AND device_id = $2`, eventID, deviceID); err != nil {
			slog.Error("geofence: increment push attempts", "event_id", eventID, "device_id", deviceID, "err", err)
			continue
		}
		n, ok := s.buildNotification(ctx, userID, placeName, eventType, platform, pushToken, unifiedPushEndpoint)
		if !ok {
			continue
		}
		s.dispatchToDevice(ctx, eventID, deviceID, n)
	}
	if err := rows.Err(); err != nil {
		slog.Error("geofence: iterate failed pushes", "err", err)
	}
}

// dispatchGeofencePush notifies the other family members' devices about a
// transition. It runs in a goroutine with its own context so it never blocks
// or is cancelled by the ingest request. The per-device delivery rows were
// already created atomically with the event (see createEventDeviceRows), so
// this only dispatches to those rows and marks push_sent on success.
//
// Privacy: by default (VerbosePush=false) the message names the PLACE but not
// the tracked user ("A family member arrived at School"), so the push provider
// (ntfy.sh/APNs) never sees who. VerbosePush adds the user's name ("Mom arrived
// at School") and should only be enabled when the push provider is trusted.
func (s *Server) dispatchGeofencePush(eventID, trackedUserID, placeName, eventType string) {
	if s.Push == nil {
		// No push configured: nothing to send.
		return
	}

	go func() {
		// No shared deadline across devices: each device gets its own timeout
		// (see dispatchToDevice) so a large family is not truncated.
		ctx := context.Background()

		rows, err := s.Pool.Query(ctx, `
			SELECT d.device_id, dev.platform, dev.push_token, dev.unifiedpush_endpoint
			FROM geofence_event_devices d
			JOIN devices dev ON dev.id = d.device_id
			WHERE d.event_id = $1 AND d.push_sent = FALSE`,
			eventID)
		if err != nil {
			slog.Error("geofence: load devices for push", "err", err)
			return
		}
		defer rows.Close()

		for rows.Next() {
			var deviceID, platform string
			var pushToken, unifiedPushEndpoint *string
			if err := rows.Scan(&deviceID, &platform, &pushToken, &unifiedPushEndpoint); err != nil {
				slog.Error("geofence: scan device", "err", err)
				continue
			}

			n, ok := s.buildNotification(ctx, trackedUserID, placeName, eventType, platform, pushToken, unifiedPushEndpoint)
			if !ok {
				continue
			}

			deviceCtx, cancel := context.WithTimeout(context.Background(), pushDispatchTimeout)
			s.dispatchToDevice(deviceCtx, eventID, deviceID, n)
			cancel()
		}
		if err := rows.Err(); err != nil {
			slog.Error("geofence: iterate devices", "err", err)
		}
	}()
}

// createEventDeviceRows inserts a geofence_event_devices row (push_sent=false,
// push_attempts=1 for the initial dispatch) for each push-capable device of the
// tracked user's family members, in the given transaction. It is called in the
// same transaction as the event insert so the event and its delivery targets
// are persisted atomically; a crash between them cannot lose the alert.
func (s *Server) createEventDeviceRows(ctx context.Context, tx pgx.Tx, eventID, trackedUserID, familyID string) error {
	if s.Push == nil {
		// No push configured: nothing to deliver, so no device rows to track.
		return nil
	}
	rows, err := tx.Query(ctx, `
		SELECT d.id
		FROM devices d
		JOIN users u ON u.id = d.user_id
		WHERE u.family_id = $1 AND u.id <> $2
		  AND ((d.platform = 'ios' AND d.push_token IS NOT NULL AND d.push_token <> '')
		       OR (d.platform = 'android' AND d.unifiedpush_endpoint IS NOT NULL AND d.unifiedpush_endpoint <> ''))`,
		familyID, trackedUserID)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var deviceID string
		if err := rows.Scan(&deviceID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO geofence_event_devices (event_id, device_id, push_sent, push_attempts)
			VALUES ($1, $2, FALSE, 1)
			ON CONFLICT (event_id, device_id) DO NOTHING`,
			eventID, deviceID); err != nil {
			return err
		}
	}
	return rows.Err()
}

// buildNotification builds the push notification for a device, returning false
// when the device has no usable push target (no token/endpoint). On a verbose
// name-lookup failure it falls back to the non-verbose message rather than
// dropping the alert.
func (s *Server) buildNotification(ctx context.Context, trackedUserID, placeName, eventType, platform string, pushToken, unifiedPushEndpoint *string) (push.Notification, bool) {
	action := "arrived at"
	if eventType == "exit" {
		action = "left"
	}
	// Fall back to a generic label when the place name is empty (e.g. the place
	// was deleted after the event), so the message never has a blank label.
	if placeName == "" {
		placeName = "a place"
	}
	title := fmt.Sprintf("A family member %s %s", action, placeName)
	if s.VerbosePush {
		var userName string
		if err := s.Pool.QueryRow(ctx, `SELECT name FROM users WHERE id = $1`, trackedUserID).Scan(&userName); err != nil {
			// Fall back to the non-verbose message rather than dropping the alert.
			slog.Error("geofence: load tracked user name", "err", err)
		} else {
			title = fmt.Sprintf("%s %s %s", userName, action, placeName)
		}
	}

	// Body is intentionally empty: the title carries the message, and a
	// distinct body would duplicate it.
	n := push.Notification{Title: title, Body: "", Platform: platform}
	switch platform {
	case "ios":
		if pushToken == nil || *pushToken == "" {
			return n, false
		}
		n.PushToken = *pushToken
	case "android":
		if unifiedPushEndpoint == nil || *unifiedPushEndpoint == "" {
			return n, false
		}
		n.UnifiedPushEndpoint = *unifiedPushEndpoint
	default:
		return n, false
	}
	return n, true
}

// dispatchToDevice delivers a notification to a single device and marks its
// per-device delivery row as sent on success. A permanent failure dead-letters
// the row so it is not re-dispatched.
func (s *Server) dispatchToDevice(ctx context.Context, eventID, deviceID string, n push.Notification) {
	if err := s.dispatchWithRetry(ctx, n); err != nil {
		slog.Error("geofence: push dispatch failed after retries", "platform", n.Platform, "err", err)
		if push.IsPermanent(err) {
			s.deadLetterDevice(eventID, deviceID)
		}
		return
	}
	s.markDevicePushSent(eventID, deviceID)
}

// markDevicePushSent marks a device's delivery row as sent using a fresh
// context, so a dispatch that consumed most of its per-device budget cannot
// starve the mark (which would leave push_sent=FALSE and cause a duplicate).
func (s *Server) markDevicePushSent(eventID, deviceID string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := s.Pool.Exec(ctx, `
		UPDATE geofence_event_devices SET push_sent = TRUE WHERE event_id = $1 AND device_id = $2`,
		eventID, deviceID); err != nil {
		slog.Error("geofence: mark device push sent", "event_id", eventID, "device_id", deviceID, "err", err)
	}
}

// deadLetterDevice marks a device's delivery row as permanently failed (by
// bumping push_attempts to the cap) so it is excluded from redispatch.
func (s *Server) deadLetterDevice(eventID, deviceID string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := s.Pool.Exec(ctx, `
		UPDATE geofence_event_devices SET push_attempts = $3
		WHERE event_id = $1 AND device_id = $2`,
		eventID, deviceID, maxPushAttempts); err != nil {
		slog.Error("geofence: dead-letter device", "event_id", eventID, "device_id", deviceID, "err", err)
	}
}

// dispatchWithRetry delivers a notification, retrying transient failures a few
// times with backoff so a single network blip does not permanently lose the
// alert. Permanent (4xx) errors are not retried. It returns the last error (or
// nil on success).
func (s *Server) dispatchWithRetry(ctx context.Context, n push.Notification) error {
	var lastErr error
	for attempt := 1; attempt <= pushRetryAttempts; attempt++ {
		if err := s.Push.Dispatch(ctx, n); err == nil {
			return nil
		} else {
			lastErr = err
			if push.IsPermanent(err) {
				slog.Error("geofence: push dispatch failed permanently", "platform", n.Platform, "err", err)
				return err
			}
			slog.Error("geofence: push dispatch failed", "platform", n.Platform, "attempt", attempt, "err", err)
		}
		if attempt < pushRetryAttempts {
			select {
			case <-ctx.Done():
				return lastErr
			case <-time.After(pushRetryBackoff):
			}
		}
	}
	return lastErr
}
