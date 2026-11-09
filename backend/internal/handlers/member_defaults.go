package handlers

// Member defaults (docs/design/PRIVACY_PROCESSING.md section 23): "by default
// every member is on server processing and has to opt out by hand".
//
// This is a server-wide ADVICE record read by the apps. It cannot sign, consent
// or write a processing pref: when auto_apply is on, each member's OWN phone
// signs lane=server (visible in the key log, undoable). The server only tells
// the app what the admin chose and lists who is not on the server yet.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// MemberDefaults is the effective setting.
type MemberDefaults struct {
	DefaultLane string `json:"default_lane"` // "server" | "phone"
	AutoApply   bool   `json:"auto_apply"`
	// Source: "admin" when an administrator saved it, "profile" when derived from the deployment profile.
	Source string `json:"source"`
}

// AppliesTo says whether members' own phones switch themselves to the server in a
// circle whose admin-signed policy has default_for_new = server (circleDefaultServer)
// or not. An administrator's saved choice is final; otherwise the profile-derived
// auto-apply OR the circle admin's signed "server by default" turns it on
// (section 24). The member's own phone still signs; this is advice only.
func (d MemberDefaults) AppliesTo(circleDefaultServer bool) bool {
	if d.Source == "admin" {
		return d.AutoApply
	}
	return d.AutoApply || circleDefaultServer
}

// FollowCircleDefault: no administrator choice is saved, so the circle's own signed
// default_for_new = server also means "members are on the server by default".
func (d MemberDefaults) FollowCircleDefault() bool { return d.Source != "admin" }

// memberDefaults returns the stored choice, else the one the deployment
// profile implies (home: server + auto-apply; cloud or unset: phone, prompt only).
func (s *Server) memberDefaults(ctx context.Context) MemberDefaults {
	_, _, effective := s.DeploymentProfile(ctx)
	d := MemberDefaults{DefaultLane: "phone", AutoApply: false, Source: "profile"}
	if effective == ProfileHome {
		d.DefaultLane, d.AutoApply = "server", true
	}
	if s.Pool == nil {
		return d
	}
	var lane *string
	var auto *bool
	if err := s.Pool.QueryRow(ctx, `SELECT member_default_lane, member_auto_apply FROM server_profile WHERE id = 1`).Scan(&lane, &auto); err != nil {
		return d
	}
	if lane != nil {
		d.DefaultLane, d.Source = *lane, "admin"
	}
	if auto != nil {
		d.AutoApply, d.Source = *auto, "admin"
	}
	return d
}

// RemindText is the message an admin can copy to members who are not on the server yet.
const RemindText = "Please open the Orbitly app once. Your circle uses the family server so maps, history and driving reports work. " +
	"You will see a short notice and can tap \"Keep on my phone\" if you prefer that. If the app is old, update it first."

func (s *Server) memberDefaultsJSON(ctx context.Context) map[string]any {
	d := s.memberDefaults(ctx)
	configured, _, effective := s.DeploymentProfile(ctx)
	dev, _ := s.pinnedServerDevice(ctx)
	return map[string]any{
		"default_lane":          d.DefaultLane,
		"auto_apply":            d.AutoApply,
		"source":                d.Source,
		"profile":               configured,
		"profile_effective":     effective,
		"server_pinned":         serverMemberEnabled() && dev != nil,
		"what_it_means":         "When auto-apply is on, each member's own phone signs \"use the server\" the next time they open the app, in circles where server processing is on. They see a notice and can keep their data on the phone with one tap. Someone who already chose is never changed. The server cannot do this for anyone. While you have not saved a choice here, the same also happens in every circle whose admin set \"Server processing\" as the default for members.",
		"follow_circle_default": d.FollowCircleDefault(),
		"remind_text":           RemindText,
	}
}

// AdminGetMemberDefaults: GET /api/admin/settings/member-defaults
func (s *Server) AdminGetMemberDefaults(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.memberDefaultsJSON(r.Context()))
}

// AdminPutMemberDefaults: PUT /api/admin/settings/member-defaults
// body {"default_lane":"server"|"phone","auto_apply":bool}; either field may be sent.
// "reset":true returns to the profile-derived values.
func (s *Server) AdminPutMemberDefaults(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		DefaultLane *string `json:"default_lane"`
		AutoApply   *bool   `json:"auto_apply"`
		Reset       bool    `json:"reset"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil || (req.DefaultLane == nil && req.AutoApply == nil && !req.Reset) {
		writeError(w, http.StatusBadRequest, "default_lane (server or phone) and/or auto_apply (true or false) is required")
		return
	}
	ctx := r.Context()
	if req.Reset {
		if _, err := s.Pool.Exec(ctx, `UPDATE server_profile SET member_default_lane = NULL, member_auto_apply = NULL, member_defaults_set_at = now(), member_defaults_set_by = $1, updated_at = now() WHERE id = 1`, claims.UserID); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to save setting")
			return
		}
		s.logAudit(ctx, claims.UserID, "", "admin.member_defaults_changed", "reset the member defaults to what the deployment profile implies", clientIP(r))
		writeJSON(w, http.StatusOK, s.memberDefaultsJSON(ctx))
		return
	}
	cur := s.memberDefaults(ctx)
	lane, auto := cur.DefaultLane, cur.AutoApply
	if req.DefaultLane != nil {
		lane = strings.ToLower(strings.TrimSpace(*req.DefaultLane))
		if lane != "server" && lane != "phone" {
			writeError(w, http.StatusBadRequest, "default_lane must be server or phone")
			return
		}
	}
	if req.AutoApply != nil {
		auto = *req.AutoApply
	}
	if auto && lane != "server" {
		writeError(w, http.StatusBadRequest, "auto_apply needs default_lane server")
		return
	}
	if _, err := s.Pool.Exec(ctx, `UPDATE server_profile SET member_default_lane = $1, member_auto_apply = $2, member_defaults_set_at = now(), member_defaults_set_by = $3, updated_at = now() WHERE id = 1`, lane, auto, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save setting")
		return
	}
	detail := "set the member default to " + lane + " lane"
	if auto {
		detail += " with auto-apply: members' own phones sign \"use the server\" when they next open the app (visible in the key log, one tap to undo)"
	} else {
		detail += ", prompt only (nothing is applied for anyone)"
	}
	s.logAudit(ctx, claims.UserID, "", "admin.member_defaults_changed", detail, clientIP(r))
	writeJSON(w, http.StatusOK, s.memberDefaultsJSON(ctx))
}

// AdminMembersNotOnServer: GET /api/admin/members-not-on-server
// Members of circles with server assistance on whose own signed lane is not
// "server". reason: "no_choice" (nothing signed yet; auto-apply covers them on
// their next app open), "phone" (they chose to keep data on the phone; never
// changed), "needs_update" (their app cannot sign lanes yet).
func (s *Server) AdminMembersNotOnServer(w http.ResponseWriter, r *http.Request) {
	rows, err := s.Pool.Query(r.Context(), `
		SELECT c.id::text, c.name, u.id::text, u.name, m.role,
		       COALESCE(p.lane, ''),
		       EXISTS (SELECT 1 FROM device_keys d WHERE d.user_id = u.id AND d.kind = 'device' AND d.revoked_at IS NULL AND 'lanes2' = ANY(d.caps)),
		       EXISTS (SELECT 1 FROM device_keys d WHERE d.user_id = u.id AND d.kind = 'device' AND d.revoked_at IS NULL)
		  FROM circles c
		  JOIN live_circle_members m ON m.circle_id = c.id
		  JOIN users u ON u.id = m.user_id
		  LEFT JOIN e2ee_processing_pref p ON p.circle_id = c.id AND p.user_id = u.id
		 WHERE c.server_assist AND c.e2ee_mode = 'private' AND COALESCE(p.lane, '') <> 'server'
		 ORDER BY c.name, u.name`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load members")
		return
	}
	defer rows.Close()
	type item struct {
		CircleID   string `json:"circle_id"`
		CircleName string `json:"circle_name"`
		UserID     string `json:"user_id"`
		Name       string `json:"name"`
		Role       string `json:"role"`
		Reason     string `json:"reason"`
		Remind     string `json:"remind_text"`
	}
	out := []item{}
	for rows.Next() {
		var it item
		var lane string
		var lanesCap, anyDevice bool
		if err := rows.Scan(&it.CircleID, &it.CircleName, &it.UserID, &it.Name, &it.Role, &lane, &lanesCap, &anyDevice); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load members")
			return
		}
		switch {
		case lane == "phone":
			it.Reason = "phone"
		case anyDevice && !lanesCap:
			it.Reason = "needs_update"
		default:
			it.Reason = "no_choice"
		}
		if it.Reason != "phone" {
			it.Remind = RemindText
		}
		out = append(out, it)
	}
	d := s.memberDefaults(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{"members": out, "auto_apply": d.AutoApply, "remind_text": RemindText})
}
