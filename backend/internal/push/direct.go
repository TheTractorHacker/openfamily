package push

// The "direct" channel: OpenFamily's own push transport, with no third-party
// distributor (no ntfy app, no Google services).
//
// Events for a device wait in the push_outbox table (bounded per device, with a
// TTL) and are streamed to the app over an authenticated long-lived HTTP
// connection (handlers/push_stream.go) whenever it is connected. Delivery is
// at-least-once: an event stays queued until the device acknowledges it, is
// re-sent on reconnect, and is deduplicated by (device, dedupe id).
//
// Privacy: payloads are built here from the same title/body the UnifiedPush and
// APNs senders get, so they carry no coordinates, and no sender name unless
// VERBOSE_PUSH is on (the caller decides that when it builds the copy).

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Event kinds.
const (
	KindAlert   = "alert"   // SOS / help / check-in / resolved (tied to an alert id)
	KindCommand = "command" // machine-to-machine, e.g. a location refresh request
	KindNotice  = "notice"  // everything else, e.g. geofence arrivals
)

// Defaults for a broker.
const (
	DefaultMaxQueuePerDevice = 50
	DefaultMaxConnsPerUser   = 8

	alertTTL   = 6 * time.Hour
	noticeTTL  = time.Hour
	commandTTL = 5 * time.Minute
)

// ErrTooManyConnections is returned by Connect when the user already holds the
// maximum number of device streams.
var ErrTooManyConnections = errors.New("push: too many direct connections")

// DirectEvent is one queued event.
type DirectEvent struct {
	ID        string
	DeviceID  string
	UserID    string
	DedupeID  string
	Kind      string
	AlertID   string
	Payload   json.RawMessage
	ExpiresAt time.Time
}

// DirectBroker owns the outbox and the registry of live device streams. A nil
// *DirectBroker is valid and behaves as "disabled" for the read-only helpers.
type DirectBroker struct {
	pool *pgxpool.Pool

	MaxQueuePerDevice int
	MaxConnsPerUser   int

	mu    sync.Mutex
	conns map[string]*DirectConn // by device id
}

// NewDirectBroker builds a broker over the given pool.
func NewDirectBroker(pool *pgxpool.Pool) *DirectBroker {
	return &DirectBroker{
		pool:              pool,
		MaxQueuePerDevice: DefaultMaxQueuePerDevice,
		MaxConnsPerUser:   DefaultMaxConnsPerUser,
		conns:             map[string]*DirectConn{},
	}
}

// DirectConn is one live device stream.
type DirectConn struct {
	UserID   string
	DeviceID string

	wake   chan struct{}
	done   chan struct{}
	once   sync.Once
	broker *DirectBroker

	replaced atomic.Bool
}

// Replaced reports whether a newer stream of the same device took over.
func (c *DirectConn) Replaced() bool { return c.replaced.Load() }

// Wake is signalled (coalesced) when new events are queued for the device.
func (c *DirectConn) Wake() <-chan struct{} { return c.wake }

// Done is closed when the connection is closed by the server (replaced by a
// newer connection of the same device, revoked, or the device was deleted).
func (c *DirectConn) Done() <-chan struct{} { return c.done }

// Close releases the connection. It is safe to call more than once.
func (c *DirectConn) Close() {
	c.once.Do(func() {
		close(c.done)
		c.broker.mu.Lock()
		if c.broker.conns[c.DeviceID] == c {
			delete(c.broker.conns, c.DeviceID)
		}
		c.broker.mu.Unlock()
	})
}

// Connect registers a live stream for a device. A second stream for the same
// device replaces (closes) the first, so a flapping client never counts twice.
// A user already at MaxConnsPerUser distinct devices gets ErrTooManyConnections.
func (b *DirectBroker) Connect(userID, deviceID string) (*DirectConn, error) {
	b.mu.Lock()
	old := b.conns[deviceID]
	if old == nil {
		n := 0
		for _, c := range b.conns {
			if c.UserID == userID {
				n++
			}
		}
		if b.MaxConnsPerUser > 0 && n >= b.MaxConnsPerUser {
			b.mu.Unlock()
			return nil, ErrTooManyConnections
		}
	}
	c := &DirectConn{UserID: userID, DeviceID: deviceID, wake: make(chan struct{}, 1), done: make(chan struct{}), broker: b}
	b.conns[deviceID] = c
	b.mu.Unlock()
	if old != nil {
		old.replaced.Store(true)
		old.once.Do(func() { close(old.done) }) // already replaced in the map
	}
	return c, nil
}

// IsConnected reports whether the device currently holds a live stream.
func (b *DirectBroker) IsConnected(deviceID string) bool {
	if b == nil {
		return false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.conns[deviceID] != nil
}

// CloseDevice drops a device's stream (device deleted or key revoked).
func (b *DirectBroker) CloseDevice(deviceID string) {
	if b == nil {
		return
	}
	b.mu.Lock()
	c := b.conns[deviceID]
	b.mu.Unlock()
	if c != nil {
		c.Close()
	}
}

// CloseUser drops every stream of a user (logout, password change).
func (b *DirectBroker) CloseUser(userID string) {
	if b == nil {
		return
	}
	b.mu.Lock()
	var cs []*DirectConn
	for _, c := range b.conns {
		if c.UserID == userID {
			cs = append(cs, c)
		}
	}
	b.mu.Unlock()
	for _, c := range cs {
		c.Close()
	}
}

func (b *DirectBroker) wakeDevice(deviceID string) {
	b.mu.Lock()
	c := b.conns[deviceID]
	b.mu.Unlock()
	if c != nil {
		select {
		case c.wake <- struct{}{}:
		default:
		}
	}
}

// directKind picks the event kind for a notification.
func directKind(n Notification) string {
	switch {
	case n.Silent:
		return KindCommand
	case n.AlertID != "":
		return KindAlert
	default:
		return KindNotice
	}
}

func directTTL(kind string) time.Duration {
	switch kind {
	case KindAlert:
		return alertTTL
	case KindCommand:
		return commandTTL
	default:
		return noticeTTL
	}
}

// NewDedupeID returns a random event id.
func NewDedupeID() string {
	var b [12]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// BuildDirectPayload renders the JSON the app receives. It only ever contains
// the notification's title and body (already stripped of coordinates and, unless
// VERBOSE_PUSH, of names by the caller), the alert id, and a command object for
// machine messages.
func BuildDirectPayload(n Notification, dedupeID string) (kind string, payload []byte, err error) {
	kind = directKind(n)
	m := map[string]any{"v": 1, "id": dedupeID, "kind": kind}
	if n.AlertID != "" {
		m["alert_id"] = n.AlertID
	}
	if kind == KindCommand {
		var raw json.RawMessage
		if json.Unmarshal([]byte(n.Body), &raw) == nil {
			m["command"] = raw
		} else {
			m["command"] = n.Body
		}
	} else {
		m["title"] = n.Title
		if n.Body != "" && n.Body != n.Title {
			m["body"] = n.Body
		}
	}
	payload, err = json.Marshal(m)
	return kind, payload, err
}

// Enqueue stores an event in the device's outbox and wakes its live stream.
// Enqueueing an already-known dedupe id is a successful no-op.
func (b *DirectBroker) Enqueue(ctx context.Context, n Notification) error {
	if n.DeviceID == "" || n.UserID == "" {
		return &PermanentError{Err: errors.New("push: direct notification needs device and user")}
	}
	id := n.DedupeID
	if id == "" {
		id = NewDedupeID()
	}
	kind, payload, err := BuildDirectPayload(n, id)
	if err != nil {
		return &PermanentError{Err: err}
	}
	var alertID any
	if n.AlertID != "" {
		alertID = n.AlertID
	}
	expires := time.Now().Add(directTTL(kind))
	if _, err := b.pool.Exec(ctx, `
		INSERT INTO push_outbox (device_id, user_id, dedupe_id, kind, alert_id, payload, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (device_id, dedupe_id) DO NOTHING`,
		n.DeviceID, n.UserID, id, kind, alertID, payload, expires); err != nil {
		return fmt.Errorf("push: enqueue direct: %w", err)
	}
	// Bound the queue: keep only the newest MaxQueuePerDevice undelivered rows.
	if b.MaxQueuePerDevice > 0 {
		_, _ = b.pool.Exec(ctx, `
			UPDATE push_outbox SET state = 'expired'
			WHERE id IN (
			    SELECT id FROM push_outbox
			    WHERE device_id = $1 AND state IN ('queued','sent')
			    ORDER BY created_at DESC, id DESC OFFSET $2)`,
			n.DeviceID, b.MaxQueuePerDevice)
	}
	b.wakeDevice(n.DeviceID)
	return nil
}

// Pending returns the device's unexpired, unacknowledged events, oldest first.
// That includes events already sent but not acked, so a reconnect re-sends them.
func (b *DirectBroker) Pending(ctx context.Context, deviceID string, limit int) ([]DirectEvent, error) {
	rows, err := b.pool.Query(ctx, `
		SELECT id, device_id, user_id, dedupe_id, kind, COALESCE(alert_id::text, ''), payload, expires_at
		FROM push_outbox
		WHERE device_id = $1 AND state IN ('queued','sent') AND expires_at > now()
		ORDER BY created_at, id LIMIT $2`, deviceID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DirectEvent
	for rows.Next() {
		var e DirectEvent
		if err := rows.Scan(&e.ID, &e.DeviceID, &e.UserID, &e.DedupeID, &e.Kind, &e.AlertID, &e.Payload, &e.ExpiresAt); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// MarkSent records that an event was written to the device's stream.
func (b *DirectBroker) MarkSent(ctx context.Context, id string) error {
	_, err := b.pool.Exec(ctx, `
		UPDATE push_outbox SET attempts = attempts + 1, sent_at = now(),
		       state = CASE WHEN state = 'queued' THEN 'sent' ELSE state END
		WHERE id = $1`, id)
	return err
}

// Ack marks events acknowledged by the device and returns the ones that
// changed state (so callers can record delivery). Unknown ids are ignored, and
// ids belonging to another device are never touched.
func (b *DirectBroker) Ack(ctx context.Context, deviceID string, dedupeIDs []string) ([]DirectEvent, error) {
	if len(dedupeIDs) == 0 {
		return nil, nil
	}
	rows, err := b.pool.Query(ctx, `
		UPDATE push_outbox SET state = 'acked', acked_at = now()
		WHERE device_id = $1 AND dedupe_id = ANY($2) AND state <> 'acked'
		RETURNING id, device_id, user_id, dedupe_id, kind, COALESCE(alert_id::text, ''), payload, expires_at`,
		deviceID, dedupeIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DirectEvent
	for rows.Next() {
		var e DirectEvent
		if err := rows.Scan(&e.ID, &e.DeviceID, &e.UserID, &e.DedupeID, &e.Kind, &e.AlertID, &e.Payload, &e.ExpiresAt); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// AckAlertForUser retires every undelivered event of an alert for a user, used
// when they acknowledge the alert from the app (so other devices stop alerting).
func (b *DirectBroker) AckAlertForUser(ctx context.Context, alertID, userID string) {
	if b == nil {
		return
	}
	_, _ = b.pool.Exec(ctx, `
		UPDATE push_outbox SET state = 'acked', acked_at = now()
		WHERE alert_id = $1 AND user_id = $2 AND state IN ('queued','sent')`, alertID, userID)
}

// TouchSeen records that the device's stream is alive (used to prefer the
// direct channel for devices that connected recently).
func (b *DirectBroker) TouchSeen(ctx context.Context, deviceID string) {
	_, _ = b.pool.Exec(ctx, `UPDATE devices SET direct_seen_at = now() WHERE id = $1`, deviceID)
}

// ExpireDue marks events past their TTL as expired and returns the alert-linked
// ones so the caller can record a failed delivery. It also deletes rows that
// expired more than a day ago.
func (b *DirectBroker) ExpireDue(ctx context.Context) ([]DirectEvent, error) {
	rows, err := b.pool.Query(ctx, `
		UPDATE push_outbox SET state = 'expired'
		WHERE state IN ('queued','sent') AND expires_at <= now()
		RETURNING id, device_id, user_id, dedupe_id, kind, COALESCE(alert_id::text, ''), payload, expires_at`)
	if err != nil {
		return nil, err
	}
	var out []DirectEvent
	for rows.Next() {
		var e DirectEvent
		if err := rows.Scan(&e.ID, &e.DeviceID, &e.UserID, &e.DedupeID, &e.Kind, &e.AlertID, &e.Payload, &e.ExpiresAt); err != nil {
			rows.Close()
			return nil, err
		}
		out = append(out, e)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	_, _ = b.pool.Exec(ctx, `DELETE FROM push_outbox WHERE expires_at < now() - interval '1 day'`)
	return out, nil
}
