package handlers

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

type e2eeAdminDevice struct {
	UserID        string     `json:"user_id"`
	UserName      string     `json:"user_name"`
	Email         string     `json:"email"`
	DeviceID      string     `json:"device_id"`
	Fingerprint   string     `json:"fingerprint"`
	Digits        string     `json:"digits"`
	Short         string     `json:"short"`
	Kind          string     `json:"kind"`
	Label         string     `json:"label"`
	CreatedAt     time.Time  `json:"created_at"`
	RevokedAt     *time.Time `json:"revoked_at"`
	RevokedReason *string    `json:"revoked_reason,omitempty"`
}

type e2eeAdminCircle struct {
	ID            string     `json:"id"`
	Name          string     `json:"name"`
	Mode          string     `json:"mode"`
	Epoch         int        `json:"epoch"`
	RekeyRequired bool       `json:"rekey_required"`
	UpdatedAt     *time.Time `json:"updated_at"`
	Members       int        `json:"members"`
	WrappedKeys   int        `json:"wrapped_keys"`
	// Lanes (counts only; the platform admin sees no per-member choice):
	// members whose server may read them vs members who keep data on their phone.
	ServerAssist     bool `json:"server_assist"`
	MembersServer    int  `json:"members_server_assisted"`
	MembersPhoneOnly int  `json:"members_phone_only"`
	LegacyTrusted    bool `json:"legacy_trusted_server"`
}

func loadE2EEAdmin(ctx context.Context, pool *pgxpool.Pool, includeRevoked bool) ([]e2eeAdminDevice, []e2eeAdminCircle, error) {
	rows, err := pool.Query(ctx, `
		SELECT d.user_id::text, u.name, u.email, d.device_id::text, d.fingerprint, d.kind, d.label, d.created_at, d.revoked_at, d.revoked_reason
		FROM device_keys d JOIN users u ON u.id = d.user_id
		WHERE $1 OR d.revoked_at IS NULL
		ORDER BY lower(u.email), d.created_at LIMIT 5000`, includeRevoked)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	devs := []e2eeAdminDevice{}
	for rows.Next() {
		var d e2eeAdminDevice
		if err := rows.Scan(&d.UserID, &d.UserName, &d.Email, &d.DeviceID, &d.Fingerprint, &d.Kind, &d.Label, &d.CreatedAt, &d.RevokedAt, &d.RevokedReason); err != nil {
			return nil, nil, err
		}
		if fp, err := hex.DecodeString(d.Fingerprint); err == nil && len(fp) == 32 {
			d.Digits, d.Short = e2ee.DigitGroups(fp), e2ee.ShortFingerprint(fp)
		}
		devs = append(devs, d)
	}
	if rows.Err() != nil {
		return nil, nil, rows.Err()
	}
	crow, err := pool.Query(ctx, `
		SELECT c.id::text, c.name, c.e2ee_mode, c.e2ee_epoch, c.e2ee_rekey_required, c.e2ee_updated_at,
		       (SELECT count(*) FROM circle_members m WHERE m.circle_id = c.id),
		       (SELECT count(*) FROM circle_key_wraps k WHERE k.circle_id = c.id AND k.key_line = 'phone' AND k.epoch = c.e2ee_epoch),
		       c.server_assist, c.server_legacy_ck,
		       (SELECT count(*) FROM live_circle_members m WHERE m.circle_id = c.id AND c.e2ee_mode = 'private' AND e2ee_member_server_ok(c.id, m.user_id)),
		       (SELECT count(*) FROM live_circle_members m WHERE m.circle_id = c.id AND c.e2ee_mode = 'private' AND NOT e2ee_member_server_ok(c.id, m.user_id))
		FROM circles c WHERE c.e2ee_mode <> 'off' OR c.e2ee_epoch > 0
		ORDER BY c.name, c.id LIMIT 2000`)
	if err != nil {
		return nil, nil, err
	}
	defer crow.Close()
	cs := []e2eeAdminCircle{}
	for crow.Next() {
		var c e2eeAdminCircle
		if err := crow.Scan(&c.ID, &c.Name, &c.Mode, &c.Epoch, &c.RekeyRequired, &c.UpdatedAt, &c.Members, &c.WrappedKeys,
			&c.ServerAssist, &c.LegacyTrusted, &c.MembersServer, &c.MembersPhoneOnly); err != nil {
			return nil, nil, err
		}
		cs = append(cs, c)
	}
	return devs, cs, crow.Err()
}

// AdminE2EEKeys lists every registered device key and each circle's E2EE epoch
// (platform admin). Public data only; nothing here can decrypt anything.
func (s *Server) AdminE2EEKeys(w http.ResponseWriter, r *http.Request) {
	devs, cs, err := loadE2EEAdmin(r.Context(), s.Pool, r.URL.Query().Get("all") != "0")
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load keys")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devs, "circles": cs})
}

// PrintE2EEFingerprints is the `server e2ee-fingerprints` subcommand: it prints
// each user's device key fingerprints straight from the database so the
// operator can compare them with what the phone shows under Settings >
// Security > Encryption keys.
func PrintE2EEFingerprints(ctx context.Context, pool *pgxpool.Pool, out io.Writer, includeRevoked bool) error {
	devs, cs, err := loadE2EEAdmin(ctx, pool, includeRevoked)
	if err != nil {
		return err
	}
	fmt.Fprintln(out, "OpenFamily device key fingerprints (public data; compare with the phone)")
	if len(devs) == 0 {
		fmt.Fprintln(out, "no device keys registered")
	}
	cur := ""
	for _, d := range devs {
		if d.UserID != cur {
			cur = d.UserID
			fmt.Fprintf(out, "\n%s <%s> user %s\n", d.UserName, d.Email, d.UserID)
		}
		state := "active"
		if d.RevokedAt != nil {
			state = "REVOKED"
			if d.RevokedReason != nil {
				state += " (" + *d.RevokedReason + ")"
			}
		}
		fmt.Fprintf(out, "  %s %s  %s  created %s  %s\n", d.Kind, d.DeviceID, state, d.CreatedAt.UTC().Format(time.RFC3339), d.Label)
		fmt.Fprintf(out, "    short   %s\n    digits  %s\n    sha256  %s\n", d.Short, d.Digits, d.Fingerprint)
	}
	if len(cs) > 0 {
		fmt.Fprintln(out, "\nCircles with encryption state")
		for _, c := range cs {
			fmt.Fprintf(out, "  %s  %q mode=%s epoch=%d rekey_required=%v members=%d wrapped_devices=%d server_assist=%v server_assisted=%d phone_only=%d\n",
				c.ID, c.Name, c.Mode, c.Epoch, c.RekeyRequired, c.Members, c.WrappedKeys, c.ServerAssist, c.MembersServer, c.MembersPhoneOnly)
		}
	}
	return nil
}

// PrintE2EELogHead recomputes the whole transparency log: it checks that every
// entry links to its predecessor, that every hash matches its contents and that
// every signature verifies under the recorded actor key, then prints the head.
func PrintE2EELogHead(ctx context.Context, pool *pgxpool.Pool, out io.Writer) error {
	rows, err := pool.Query(ctx, `SELECT seq, action, user_id::text, actor_device_id::text, actor_pub, coalesce(circle_id::text,''),
		coalesce(subject_id::text,''), epoch, ref, signature, prev_hash, entry_hash FROM e2ee_log ORDER BY seq`)
	if err != nil {
		return err
	}
	defer rows.Close()
	prev := e2ee.GenesisHash
	var n, lastSeq int64
	var head []byte
	for rows.Next() {
		var seq int64
		var action, epoch int
		var user, actor, circle, subject string
		var pub, ref, sig, ph, eh []byte
		if err := rows.Scan(&seq, &action, &user, &actor, &pub, &circle, &subject, &epoch, &ref, &sig, &ph, &eh); err != nil {
			return err
		}
		if seq != lastSeq+1 {
			return fmt.Errorf("sequence gap before entry %d", seq)
		}
		if !bytes.Equal(ph, prev) {
			return fmt.Errorf("entry %d does not extend entry %d", seq, seq-1)
		}
		if circle == zeroUUIDStr {
			circle = ""
		}
		if subject == zeroUUIDStr {
			subject = ""
		}
		msg, err := e2ee.LogActionMessage(byte(action), user, actor, circle, subject, uint32(epoch), ref)
		if err != nil {
			return fmt.Errorf("entry %d malformed: %w", seq, err)
		}
		if !ed25519.Verify(ed25519.PublicKey(pub), msg, sig) {
			return fmt.Errorf("entry %d has an invalid signature", seq)
		}
		if !bytes.Equal(e2ee.LogEntryHash(ph, uint64(seq), msg, sig), eh) {
			return fmt.Errorf("entry %d hash mismatch", seq)
		}
		prev, head, lastSeq = eh, eh, seq
		n++
	}
	if rows.Err() != nil {
		return rows.Err()
	}
	fmt.Fprintf(out, "log verified: %d entries\n", n)
	if n == 0 {
		fmt.Fprintln(out, "head: (empty)")
		return nil
	}
	fmt.Fprintf(out, "head seq %d\nhead hash %s\nhead digits %s\n", lastSeq, hex.EncodeToString(head), e2ee.DigitGroups(head))
	return nil
}

const zeroUUIDStr = "00000000-0000-0000-0000-000000000000"
