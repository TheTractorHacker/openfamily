// Package models defines the core domain types shared across the API.
package models

import "time"

// Role is a user's permission level within a family.
type Role string

const (
	RoleAdmin  Role = "admin"
	RoleMember Role = "member"
	RoleChild  Role = "child"
)

// Valid reports whether r is a known role.
func (r Role) Valid() bool {
	switch r {
	case RoleAdmin, RoleMember, RoleChild:
		return true
	}
	return false
}

// Family groups users, devices, places, and geofences.
type Family struct {
	ID        string         `json:"id"`
	Name      string         `json:"name"`
	Settings  map[string]any `json:"settings"`
	CreatedAt time.Time      `json:"created_at"`
}

// EmergencyContact is someone who receives SOS even without the app.
type EmergencyContact struct {
	ID        string    `json:"id"`
	UserID    string    `json:"user_id"`
	Name      string    `json:"name"`
	Phone     string    `json:"phone"`
	Relation  string    `json:"relation,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// User is an account. A user belongs to at most one family.
type User struct {
	ID           string    `json:"id"`
	FamilyID     *string   `json:"family_id,omitempty"`
	Email        string    `json:"email"`
	Name         string    `json:"name"`
	Role         Role      `json:"role"`
	PasswordHash string    `json:"-"`
	TOTPSecret   string    `json:"-"`
	TOTPEnabled  bool      `json:"totp_enabled"`
	TokenVersion int       `json:"-"`
	Phone        *string   `json:"phone,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// MemberWithLocation is a family member joined to their latest location (if
// any). It embeds User for the identity fields and adds nullable location
// fields; a member who has never reported a location has null lat/lon/ts.
type MemberWithLocation struct {
	User
	// Avatar metadata is intentionally separate from the bytes. Authenticated
	// family/admin clients use it to decide whether to request the protected
	// member-avatar endpoint instead of rendering initials. AvatarVersion is a
	// durable cache key that changes on both upload and removal.
	HasAvatar       bool       `json:"has_avatar"`
	AvatarVersion   int64      `json:"avatar_version"`
	AvatarUpdatedAt *time.Time `json:"avatar_updated_at,omitempty"`
	Lat             *float64   `json:"lat,omitempty"`
	Lon             *float64   `json:"lon,omitempty"`
	TS              *time.Time `json:"ts,omitempty"`
	BatteryPct      *float64   `json:"battery_pct,omitempty"`
	SpeedMPS        *float64   `json:"speed_mps,omitempty"`
	MotionState     *string    `json:"motion_state,omitempty"`
	AccuracyMeters  *float64   `json:"accuracy_meters,omitempty"`
	// LastSeenAt is the most recent device heartbeat/ingest time across all of
	// the member's devices. It can be newer than TS (the last stored
	// position's timestamp) when the member is stationary and only heartbeats
	// are arriving; clients use it to keep "last seen" fresh without moving
	// the pin.
	LastSeenAt *time.Time `json:"last_seen_at,omitempty"`
	// CircleIDs are the circles (within the requested scope) the member shares
	// with the caller; SharingCircleIDs is the subset in which they share their
	// location. Additive: legacy clients ignore both.
	CircleIDs        []string `json:"circle_ids,omitempty"`
	SharingCircleIDs []string `json:"sharing_circle_ids,omitempty"`
}

// InviteCode gates registration: a new user presents a valid, unexpired,
// unused code to register, and is assigned the code's family and role.
type InviteCode struct {
	ID        string     `json:"id"`
	Code      string     `json:"code"`
	FamilyID  string     `json:"family_id"`
	CreatedBy *string    `json:"created_by,omitempty"`
	Role      Role       `json:"role"`
	MaxUses   int        `json:"max_uses"`
	Uses      int        `json:"uses"`
	ExpiresAt *time.Time `json:"expires_at,omitempty"`
	CreatedAt time.Time  `json:"created_at"`
}

// Device is a phone/tablet that reports location for a user.
type Device struct {
	ID                  string     `json:"id"`
	UserID              string     `json:"user_id"`
	Platform            string     `json:"platform"` // ios | android | web
	Name                string     `json:"name"`
	PushToken           string     `json:"-"`
	UnifiedPushEndpoint string     `json:"-"`
	LastSeen            *time.Time `json:"last_seen,omitempty"`
	AppVersion          string     `json:"app_version,omitempty"`
	CreatedAt           time.Time  `json:"created_at"`
}

// Location is a single reported position point.
type Location struct {
	DeviceID       string    `json:"device_id"`
	TS             time.Time `json:"ts"`
	Lat            float64   `json:"lat"`
	Lon            float64   `json:"lon"`
	AccuracyMeters *float64  `json:"accuracy_meters,omitempty"`
	AltitudeMeters *float64  `json:"altitude_meters,omitempty"`
	SpeedMPS       *float64  `json:"speed_mps,omitempty"`
	HeadingDeg     *float64  `json:"heading_deg,omitempty"`
	BatteryPct     *float64  `json:"battery_pct,omitempty"`
	MotionState    string    `json:"motion_state,omitempty"`
	Source         string    `json:"source,omitempty"`
}

// Place is a named point of interest (home, school, work, custom).
type Place struct {
	ID           string    `json:"id"`
	FamilyID     string    `json:"family_id"`
	Name         string    `json:"name"`
	Type         string    `json:"type"`
	Lat          float64   `json:"lat"`
	Lon          float64   `json:"lon"`
	RadiusMeters *float64  `json:"radius_meters,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
}

// Geofence links a place to a user with enter/exit notification flags.
type Geofence struct {
	ID          string    `json:"id"`
	FamilyID    string    `json:"family_id"`
	PlaceID     *string   `json:"place_id,omitempty"`
	UserID      *string   `json:"user_id,omitempty"`
	EnterNotify bool      `json:"enter_notify"`
	ExitNotify  bool      `json:"exit_notify"`
	Enabled     bool      `json:"enabled"`
	CreatedAt   time.Time `json:"created_at"`
}
