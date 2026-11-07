package handlers

import (
	"context"
	"net/http"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/compat"
)

// Delivery health of a Private circle (GET /circles/{id}/delivery).
//
// A Private circle shows nobody's position on the server, so "no location yet"
// used to be the only symptom of many different problems (a phone that never
// fetched the circle key, an app that is too old, a phone that is switched
// off). This endpoint answers WHY, from metadata the server already holds:
// who is a member, whether each of their phones holds a key wrap, when a sealed
// item last arrived, the app version, and whether sharing is paused. It never
// returns or touches a position, and nothing in it is new information for the
// circle's members: item times are the minute-coarse receipt times the relay
// already stores, and the roster is in GET /circles/{id}/e2ee.

// Reasons a member's updates are not arriving. Plain codes; the app turns them
// into sentences.
const (
	DeliveryOK            = "ok"
	DeliverySharingPaused = "sharing_paused"
	DeliveryUpdateNeeded  = "update_needed"
	DeliveryNoDevice      = "no_device"
	DeliveryNotApproved   = "not_approved"
	DeliveryNoKeyWrap     = "no_key_wrap"
	DeliveryNeverSent     = "never_sent"
	DeliveryQuiet         = "quiet"
)

// deliveryQuietAfter is how long a member can be silent before the reason is
// "quiet". A moving phone sends about once a minute; a still one less often.
const deliveryQuietAfter = 30 * time.Minute

type deliveryDevice struct {
	DeviceID     string     `json:"device_id"`
	Label        string     `json:"label"`
	Kind         string     `json:"kind"`
	Approved     bool       `json:"approved"`
	CanUpload    bool       `json:"can_upload"`
	HasKeyWrap   bool       `json:"has_key_wrap"`
	WrapEpoch    int        `json:"wrap_epoch"`
	LastItemAt   *time.Time `json:"last_item_at"`
	LastFixAt    *time.Time `json:"last_fix_at"`
	Lanes2       bool       `json:"lanes2"`
	RegisteredAt time.Time  `json:"registered_at"`
}

type deliveryMember struct {
	UserID         string           `json:"user_id"`
	Name           string           `json:"name"`
	Role           string           `json:"role"`
	You            bool             `json:"you"`
	SharingEnabled bool             `json:"sharing_enabled"`
	Lane           string           `json:"lane"` // "phone" or "server"
	AppVersion     string           `json:"app_version,omitempty"`
	AppPlatform    string           `json:"app_platform,omitempty"`
	AppBucket      string           `json:"app_bucket"` // current | ok | update_needed | unknown
	LastContactAt  *time.Time       `json:"last_contact_at"`
	LastItemAt     *time.Time       `json:"last_item_at"`
	LastFixAt      *time.Time       `json:"last_fix_at"`
	Reason         string           `json:"reason"`
	Devices        []deliveryDevice `json:"devices"`
}

type deliveryReport struct {
	CircleID     string           `json:"circle_id"`
	Mode         string           `json:"mode"`
	Epoch        int              `json:"epoch"`
	ServerAssist bool             `json:"server_assist"`
	Now          time.Time        `json:"now"`
	Members      []deliveryMember `json:"members"`
	Summary      string           `json:"summary"`
}

// appBucket classifies an app version for delivery: "update_needed" below the
// sealed channel (0.16), "current" at or above the newest feature, else "ok".
func appBucket(version string) string {
	if version == "" {
		return "unknown"
	}
	v, ok := compat.Parse(version)
	if !ok {
		return "unknown"
	}
	if !compat.Supports("private_channel", v, true) {
		return "update_needed"
	}
	if compat.Supports("processing_lanes", v, true) {
		return "current"
	}
	return "ok"
}

// deliveryReason is the single most useful explanation for one member. Order
// matters: the first cause that applies is the one to fix first.
func deliveryReason(m deliveryMember, now time.Time) string {
	if !m.SharingEnabled {
		return DeliverySharingPaused
	}
	if m.AppBucket == "update_needed" {
		return DeliveryUpdateNeeded
	}
	uploadable, approved, wrapped := false, false, false
	for _, d := range m.Devices {
		if d.Kind != "device" {
			continue
		}
		uploadable = uploadable || d.CanUpload
		approved = approved || d.Approved
		wrapped = wrapped || (d.Approved && d.HasKeyWrap)
	}
	if !uploadable {
		return DeliveryNoDevice
	}
	if !approved {
		return DeliveryNotApproved
	}
	if !wrapped {
		return DeliveryNoKeyWrap
	}
	if m.LastItemAt == nil {
		return DeliveryNeverSent
	}
	if now.Sub(*m.LastItemAt) > deliveryQuietAfter {
		return DeliveryQuiet
	}
	return DeliveryOK
}

// loadDeliveryReport builds the report for one circle. viewer may be empty (admin use).
func (s *Server) loadDeliveryReport(ctx context.Context, circleID, viewer string) (deliveryReport, error) {
	rep := deliveryReport{CircleID: circleID, Now: time.Now().UTC(), Members: []deliveryMember{}}
	if err := s.Pool.QueryRow(ctx, `SELECT e2ee_mode, e2ee_epoch, server_assist FROM circles WHERE id = $1`, circleID).
		Scan(&rep.Mode, &rep.Epoch, &rep.ServerAssist); err != nil {
		return rep, err
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT m.user_id::text, u.name, m.role, m.sharing_enabled,
		       CASE WHEN e2ee_pref_lane_server(m.circle_id, m.user_id) THEN 'server' ELSE 'phone' END,
		       COALESCE(av.app_version, ''), COALESCE(av.platform, ''),
		       GREATEST(rs.last_report_at, (SELECT max(dv.last_seen) FROM devices dv WHERE dv.user_id = m.user_id))
		FROM live_circle_members m
		JOIN users u ON u.id = m.user_id
		LEFT JOIN member_report_state rs ON rs.user_id = m.user_id
		LEFT JOIN LATERAL (SELECT app_version, platform FROM app_client_versions a WHERE a.user_id = m.user_id
		                   ORDER BY a.last_seen DESC LIMIT 1) av ON TRUE
		WHERE m.circle_id = $1
		ORDER BY u.name, m.user_id`, circleID)
	if err != nil {
		return rep, err
	}
	byUser := map[string]int{}
	for rows.Next() {
		var d deliveryMember
		if err := rows.Scan(&d.UserID, &d.Name, &d.Role, &d.SharingEnabled, &d.Lane, &d.AppVersion, &d.AppPlatform, &d.LastContactAt); err != nil {
			rows.Close()
			return rep, err
		}
		d.You = d.UserID == viewer
		d.AppBucket = appBucket(d.AppVersion)
		d.Devices = []deliveryDevice{}
		byUser[d.UserID] = len(rep.Members)
		rep.Members = append(rep.Members, d)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return rep, err
	}

	// Phones of the members: key state and last sealed item (receipt times only).
	drows, err := s.Pool.Query(ctx, `
		SELECT d.user_id::text, d.device_id::text, d.label, d.kind, `+e2eeApprovedExpr("$1")+`, d.can_upload, 'lanes2' = ANY(d.caps), d.created_at,
		       COALESCE((SELECT max(w.epoch) FROM circle_key_wraps w
		                  WHERE w.circle_id = $1 AND w.recipient_device_id = d.device_id AND w.key_line = 'phone'), 0),
		       EXISTS (SELECT 1 FROM circle_key_wraps w WHERE w.circle_id = $1 AND w.recipient_device_id = d.device_id
		                  AND w.key_line = 'phone' AND w.epoch = (SELECT e2ee_epoch FROM circles WHERE id = $1)),
		       (SELECT max(i.received_at) FROM e2ee_items i WHERE i.circle_id = $1 AND i.device_id = d.device_id),
		       (SELECT max(i.received_at) FROM e2ee_items i WHERE i.circle_id = $1 AND i.device_id = d.device_id AND i.purpose = 'fix')
		FROM device_keys d
		WHERE d.revoked_at IS NULL AND d.kind IN ('device')
		  AND d.user_id IN (SELECT user_id FROM live_circle_members WHERE circle_id = $1)
		ORDER BY d.created_at`, circleID)
	if err != nil {
		return rep, err
	}
	for drows.Next() {
		var uid string
		var dv deliveryDevice
		if err := drows.Scan(&uid, &dv.DeviceID, &dv.Label, &dv.Kind, &dv.Approved, &dv.CanUpload, &dv.Lanes2, &dv.RegisteredAt,
			&dv.WrapEpoch, &dv.HasKeyWrap, &dv.LastItemAt, &dv.LastFixAt); err != nil {
			drows.Close()
			return rep, err
		}
		if i, ok := byUser[uid]; ok {
			m := &rep.Members[i]
			m.Devices = append(m.Devices, dv)
			if dv.LastItemAt != nil && (m.LastItemAt == nil || dv.LastItemAt.After(*m.LastItemAt)) {
				t := *dv.LastItemAt
				m.LastItemAt = &t
			}
			if dv.LastFixAt != nil && (m.LastFixAt == nil || dv.LastFixAt.After(*m.LastFixAt)) {
				t := *dv.LastFixAt
				m.LastFixAt = &t
			}
		}
	}
	drows.Close()
	if err := drows.Err(); err != nil {
		return rep, err
	}

	problems := 0
	senders := 0
	for i := range rep.Members {
		m := &rep.Members[i]
		m.Reason = deliveryReason(*m, rep.Now)
		if m.Reason != DeliveryOK {
			problems++
		}
		if m.LastItemAt != nil && rep.Now.Sub(*m.LastItemAt) <= deliveryQuietAfter {
			senders++
		}
	}
	switch {
	case rep.Mode != "private":
		rep.Summary = "normal"
	case problems == 0:
		rep.Summary = "ok"
	case senders == 0:
		rep.Summary = "nobody_sending"
	default:
		rep.Summary = "some_not_sending"
	}
	return rep, nil
}

// E2EEDelivery answers GET /circles/{id}/delivery for a member of the circle.
func (s *Server) E2EEDelivery(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	rep, err := s.loadDeliveryReport(r.Context(), m.CircleID, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load delivery state")
		return
	}
	writeJSON(w, http.StatusOK, rep)
}
