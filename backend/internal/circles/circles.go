// Package circles is the single authorization layer for circle membership.
//
// Every handler that reads or writes circle-scoped data must go through these
// helpers instead of comparing users.family_id or writing its own membership
// SQL. See docs/design/CIRCLES.md.
//
// Not-a-member and no-such-circle are deliberately indistinguishable
// (ErrNotFound) so an outsider cannot probe which circle ids exist (IDOR).
package circles

import (
	"context"
	"errors"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Role is a member's role inside one circle.
type Role string

const (
	RoleAdmin  Role = "admin"
	RoleMember Role = "member"
)

// Valid reports whether r is a circle role.
func (r Role) Valid() bool { return r == RoleAdmin || r == RoleMember }

var (
	// ErrNotFound means the circle does not exist or the user is not in it.
	ErrNotFound = errors.New("circle not found")
	// ErrForbidden means the user is a member but lacks the needed role.
	ErrForbidden = errors.New("circle admin only")
)

// DB is the subset of pgxpool.Pool / pgx.Tx the helpers need, so they can run
// inside a caller's transaction.
type DB interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// Authz answers membership questions against the database. It holds no cache:
// every call reads current state, so removals and sharing changes are effective
// immediately.
type Authz struct{ db DB }

// New returns an Authz over db (a pool or a transaction).
func New(db DB) *Authz { return &Authz{db: db} }

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// ValidID reports whether s is a well-formed UUID. Handlers use it to turn a
// malformed path id into a 404 instead of a database error.
func ValidID(s string) bool { return uuidRe.MatchString(s) }

// Membership is one user's standing in one circle.
type Membership struct {
	CircleID       string
	UserID         string
	Role           Role
	SharingEnabled bool
	JoinedAt       time.Time
}

// RequireMember returns the user's membership of circleID, or ErrNotFound.
func (a *Authz) RequireMember(ctx context.Context, userID, circleID string) (Membership, error) {
	m := Membership{CircleID: circleID, UserID: userID}
	if !ValidID(circleID) || !ValidID(userID) {
		return m, ErrNotFound
	}
	err := a.db.QueryRow(ctx, `
		SELECT role, sharing_enabled, joined_at FROM circle_members
		WHERE circle_id = $1 AND user_id = $2`, circleID, userID,
	).Scan(&m.Role, &m.SharingEnabled, &m.JoinedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return m, ErrNotFound
	}
	return m, err
}

// RequireAdmin returns the membership when the user is an admin of circleID.
// A non-member gets ErrNotFound; a plain member gets ErrForbidden.
func (a *Authz) RequireAdmin(ctx context.Context, userID, circleID string) (Membership, error) {
	m, err := a.RequireMember(ctx, userID, circleID)
	if err != nil {
		return m, err
	}
	if m.Role != RoleAdmin {
		return m, ErrForbidden
	}
	return m, nil
}

// CircleIDs lists every circle the user belongs to (oldest membership first).
func (a *Authz) CircleIDs(ctx context.Context, userID string) ([]string, error) {
	if !ValidID(userID) {
		return nil, nil
	}
	return a.strings(ctx, `
		SELECT circle_id::text FROM circle_members WHERE user_id = $1
		ORDER BY joined_at, circle_id`, userID)
}

// SharedWith returns the circles in which viewer and subject are both members
// AND the subject has location sharing enabled: the only circles through which
// viewer may see subject's location. A user always sees themselves, so for
// viewer == subject it returns all of their circles regardless of sharing.
func (a *Authz) SharedWith(ctx context.Context, viewerID, subjectID string) ([]string, error) {
	if !ValidID(viewerID) || !ValidID(subjectID) {
		return nil, nil
	}
	if viewerID == subjectID {
		return a.CircleIDs(ctx, viewerID)
	}
	return a.strings(ctx, `
		SELECT s.circle_id::text
		FROM circle_members v
		JOIN circle_members s ON s.circle_id = v.circle_id
		WHERE v.user_id = $1 AND s.user_id = $2 AND s.sharing_enabled
		ORDER BY s.circle_id`, viewerID, subjectID)
}

// SharingCircles returns the circles in which subject currently shares their
// location. These are the circles whose members may be sent a live update.
func (a *Authz) SharingCircles(ctx context.Context, subjectID string) ([]string, error) {
	if !ValidID(subjectID) {
		return nil, nil
	}
	return a.strings(ctx, `
		SELECT circle_id::text FROM circle_members
		WHERE user_id = $1 AND sharing_enabled ORDER BY circle_id`, subjectID)
}

// LocationVisibility lists every co-member of viewer within circleIDs
// (restricted to circles the viewer actually belongs to, so a forged id adds
// nothing) and whether viewer may see that member's location. The viewer is
// always listed and always visible to themselves.
func (a *Authz) LocationVisibility(ctx context.Context, viewerID string, circleIDs []string) (map[string]bool, error) {
	out := map[string]bool{}
	if !ValidID(viewerID) || len(circleIDs) == 0 {
		return out, nil
	}
	rows, err := a.db.Query(ctx, `
		SELECT s.user_id::text, bool_or(s.sharing_enabled OR s.user_id = v.user_id)
		FROM circle_members v
		JOIN circle_members s ON s.circle_id = v.circle_id
		WHERE v.user_id = $1 AND v.circle_id = ANY($2::uuid[])
		GROUP BY s.user_id`, viewerID, filterIDs(circleIDs))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var vis bool
		if err := rows.Scan(&id, &vis); err != nil {
			return nil, err
		}
		out[id] = vis
	}
	return out, rows.Err()
}

// MemberCircle is one circle a co-member shares with the viewer.
type MemberCircle struct {
	CircleID string
	// Sharing is true when the member shares their location in this circle
	// (always true for the viewer themselves).
	Sharing bool
}

// MemberCircles maps every co-member of viewer within circleIDs (only circles
// the viewer belongs to count) to the circles of circleIDs they share with the
// viewer. It lets a client filter one snapshot per circle.
func (a *Authz) MemberCircles(ctx context.Context, viewerID string, circleIDs []string) (map[string][]MemberCircle, error) {
	out := map[string][]MemberCircle{}
	if !ValidID(viewerID) || len(circleIDs) == 0 {
		return out, nil
	}
	rows, err := a.db.Query(ctx, `
		SELECT s.user_id::text, s.circle_id::text, (s.sharing_enabled OR s.user_id = v.user_id)
		FROM circle_members v
		JOIN circle_members s ON s.circle_id = v.circle_id
		WHERE v.user_id = $1 AND v.circle_id = ANY($2::uuid[])
		ORDER BY s.circle_id`, viewerID, filterIDs(circleIDs))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var uid string
		var mc MemberCircle
		if err := rows.Scan(&uid, &mc.CircleID, &mc.Sharing); err != nil {
			return nil, err
		}
		out[uid] = append(out[uid], mc)
	}
	return out, rows.Err()
}

func filterIDs(in []string) []string {
	out := make([]string, 0, len(in))
	for _, id := range in {
		if ValidID(id) {
			out = append(out, id)
		}
	}
	return out
}

func (a *Authz) strings(ctx context.Context, sql string, args ...any) ([]string, error) {
	rows, err := a.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}
