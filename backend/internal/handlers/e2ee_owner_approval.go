package handlers

// Owner approval (docs/design/E2EE.md "Owner approval").
//
// A replacement device that is not cross-signed by an earlier key of its user
// normally needs another circle admin's approval. In a circle whose only admin
// is its creator, that admin's own "set this phone up again" therefore locks
// them out. The per-circle policy owner_approval lets the creator (while a
// circle admin) approve their OWN replacement device, after re-entering their
// password (and 2FA code when enabled). Switching it on or off is a signed
// key-log action (12) so every member's phone can see who changed it and when,
// and each self-approval is marked so phones can say "approved by the owner
// without a second admin". It trades a little security for recoverability.

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// codeSelfApproval is the machine-readable code of a refused self-approval.
const codeSelfApproval = "self_approval_not_allowed"

// stepUpFields carries the re-authentication of a sensitive E2EE action.
type stepUpFields struct {
	Password string `json:"password"`
	TOTPCode string `json:"totp_code"`
}

type ownerApprovalReq struct {
	Enabled *bool `json:"enabled"`
	signedAction
	stepUpFields
}

// ownerApprovalInfo is what the server knows about a caller and a circle's
// owner-approval rule.
type ownerApprovalInfo struct {
	creator     bool // the caller created the circle
	policyOn    bool
	otherAdmins int // live admins other than the caller
}

func loadOwnerApprovalInfo(ctx context.Context, q querier, circleID, uid string) (ownerApprovalInfo, error) {
	var o ownerApprovalInfo
	err := q.QueryRow(ctx, `SELECT COALESCE(c.created_by = $2::uuid, FALSE), c.owner_approval,
		(SELECT count(*) FROM live_circle_members m WHERE m.circle_id = c.id AND m.role = 'admin' AND m.user_id <> $2::uuid)
		FROM circles c WHERE c.id = $1`, circleID, uid).Scan(&o.creator, &o.policyOn, &o.otherAdmins)
	return o, err
}

// selfApprovalRefusal is the actionable text for an admin who tried to approve
// their own device without the policy.
func selfApprovalRefusal(o ownerApprovalInfo) string {
	var msg string
	if o.otherAdmins == 0 {
		msg = "You're the only admin. Make another member an admin so they can approve this phone"
		if o.creator {
			msg += ", or turn on owner approval for this circle."
		} else {
			msg += "."
		}
		return msg
	}
	msg = "Another circle admin must approve your own device."
	if o.creator {
		msg += " Or turn on owner approval for this circle."
	}
	return msg
}

func writeSelfApprovalRefusal(w http.ResponseWriter, o ownerApprovalInfo) {
	writeJSON(w, http.StatusForbidden, map[string]any{
		"error":                     selfApprovalRefusal(o),
		"code":                      codeSelfApproval,
		"sole_admin":                o.otherAdmins == 0,
		"can_enable_owner_approval": o.creator,
	})
}

// E2EESetOwnerApproval switches the circle's owner-approval rule. Turning it
// ON is reserved to the circle's creator (who must be a circle admin) and needs
// the password (plus 2FA code when enabled). Any circle admin may turn it OFF.
// The change is a signed key-log entry (action 12).
func (s *Server) E2EESetOwnerApproval(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeadmin:user:"+uid, e2eeAdminOpPerUser, e2eeAdminOpWindow) {
		return
	}
	var req ownerApprovalReq
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	if req.Enabled == nil {
		writeError(w, http.StatusBadRequest, "enabled is required")
		return
	}
	on := *req.Enabled
	ctx := r.Context()
	tx, mode, _, ok := s.e2eeCircleTx(w, r, m.CircleID)
	if !ok {
		return
	}
	defer tx.Rollback(ctx)
	if mode != "private" {
		writeError(w, http.StatusConflict, "circle is not private")
		return
	}
	info, err := loadOwnerApprovalInfo(ctx, tx, m.CircleID, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load circle")
		return
	}
	if on && !info.creator {
		writeError(w, http.StatusForbidden, "only the person who created this circle can turn on owner approval")
		return
	}
	if info.policyOn == on {
		writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "owner_approval": on})
		return
	}
	if on && !s.stepUp(w, r, uid, req.Password, req.TOTPCode) {
		return
	}
	ref, err := e2ee.OwnerApprovalRef(m.CircleID, uid, on)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid ids")
		return
	}
	if !s.verifyCircleAction(w, r, tx, e2ee.ActOwnerApproval, uid, m.CircleID, 0, "", ref, req.signedAction) {
		return
	}
	var seq int64
	if err := tx.QueryRow(ctx, `SELECT seq FROM e2ee_log ORDER BY seq DESC LIMIT 1`).Scan(&seq); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to log action")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE circles SET owner_approval = $2, owner_approval_seq = $3 WHERE id = $1`, m.CircleID, on, seq); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update circle")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	action, word := "e2ee.owner_approval_off", "off"
	if on {
		action, word = "e2ee.owner_approval_on", "on"
	}
	s.auditCircle(ctx, uid, m.CircleID, action, "owner approval turned "+word, clientIP(r))
	if on {
		s.notifyCircleOthers(ctx, uid, m.CircleID, "Owner approval turned on",
			"The owner of %s can now approve their own new phone without a second admin. Your phone will tell you when that happens.")
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "owner_approval": on})
}

// checkSelfApproval decides an admin's approval of their OWN device. It writes
// the response and returns false when it is refused.
func (s *Server) checkSelfApproval(w http.ResponseWriter, r *http.Request, tx pgx.Tx, uid, circleID string, su stepUpFields) bool {
	// Serialise with a concurrent policy change.
	if _, err := tx.Exec(r.Context(), `SELECT 1 FROM circles WHERE id = $1 FOR UPDATE`, circleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to approve")
		return false
	}
	info, err := loadOwnerApprovalInfo(r.Context(), tx, circleID, uid)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "circle not found")
		return false
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to approve")
		return false
	}
	if !info.creator || !info.policyOn {
		writeSelfApprovalRefusal(w, info)
		return false
	}
	return s.stepUp(w, r, uid, su.Password, su.TOTPCode)
}

// notifyCircleOthers pushes a notice to every other live member. bodyFmt holds
// one %s for the circle label (its name only with verbose push). Best effort.
func (s *Server) notifyCircleOthers(ctx context.Context, actor, circleID, title, bodyFmt string) {
	if s.Pool == nil {
		return
	}
	var name string
	_ = s.Pool.QueryRow(ctx, `SELECT name FROM circles WHERE id = $1`, circleID).Scan(&name)
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text FROM live_circle_members WHERE circle_id = $1 AND user_id <> $2`, circleID, actor)
	if err != nil {
		return
	}
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	if len(ids) == 0 {
		return
	}
	label := "a circle"
	if s.VerbosePush && name != "" {
		label = name
	}
	go s.pushUsers(context.WithoutCancel(ctx), ids, title, fmt.Sprintf(bodyFmt, label))
}
