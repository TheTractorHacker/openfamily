package handlers

import (
	"bufio"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/config"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/go-chi/chi/v5"
)

const (
	// maxExportRange caps one export so a single request cannot stream the
	// whole table.
	maxExportRange = 31 * 24 * time.Hour
	// exportPointCap bounds the rows written for one export.
	exportPointCap = 250000
)

// exportPoint is one raw location fix in an export.
type exportPoint struct {
	TS          time.Time
	Lat         float64
	Lon         float64
	Accuracy    float64 // meters; 0 = unknown
	SpeedMPS    *float64
	BatteryPct  *float64
	MotionState string
}

// exportIter calls yield for every point in order and stops at the first error.
type exportIter func(yield func(exportPoint) error) error

// AdminExportMemberHistory streams a member's raw location fixes as GPX or
// CSV. GET /api/admin/members/{id}/history/export?format=gpx|csv&from&to
// RequireAuth + RequirePlatformAdmin are enforced by the route group, exactly
// as for AdminGetMemberHistory.
func (s *Server) AdminExportMemberHistory(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	format := strings.ToLower(r.URL.Query().Get("format"))
	if format != "gpx" && format != "csv" {
		writeError(w, http.StatusBadRequest, "format must be gpx or csv")
		return
	}
	from, to, errMsg, ok := parseExportRange(r, time.Now())
	if !ok {
		writeError(w, http.StatusBadRequest, errMsg)
		return
	}
	memberID := chi.URLParam(r, "id")
	if memberID == "" {
		writeError(w, http.StatusBadRequest, "member id is required")
		return
	}
	familyID, found, err := s.userFamilyID(r.Context(), memberID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load member")
		return
	}
	if !found {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}
	if s.adminLocationDenied(r.Context(), claims.UserID, familyID, "denied location export of member "+memberID, clientIP(r)) {
		writeError(w, http.StatusForbidden, "admin location access is disabled on this server")
		return
	}
	if s.memberKeepsDataOnPhone(r.Context(), memberID) {
		writeE2EECode(w, http.StatusForbidden, "keeps_data_on_phone", "this member keeps their data on their phone")
		return
	}
	var name string
	_ = s.Pool.QueryRow(r.Context(), `SELECT name FROM users WHERE id = $1`, memberID).Scan(&name)

	rows, err := s.Pool.Query(r.Context(), `
		SELECT l.ts, ST_Y(l.geom), ST_X(l.geom), COALESCE(l.accuracy_meters, 0),
		       l.speed_mps, l.battery_pct, COALESCE(l.motion_state, '')
		FROM locations l
		JOIN devices d ON d.id = l.device_id
		WHERE d.user_id = $1 AND l.ts >= $2 AND l.ts < $3
		ORDER BY l.ts
		LIMIT $4`, memberID, from, to, exportPointCap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load history")
		return
	}
	defer rows.Close()

	iter := func(yield func(exportPoint) error) error {
		for rows.Next() {
			var p exportPoint
			if err := rows.Scan(&p.TS, &p.Lat, &p.Lon, &p.Accuracy, &p.SpeedMPS, &p.BatteryPct, &p.MotionState); err != nil {
				return err
			}
			if err := yield(p); err != nil {
				return err
			}
		}
		return rows.Err()
	}

	s.auditAdminView(r.Context(), claims.UserID, familyID, "exported location history of member "+memberID, clientIP(r))

	stamp := from.UTC().Format("20060102") + "-" + to.UTC().Format("20060102")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Disposition", `attachment; filename="openfamily-history-`+stamp+`.`+format+`"`)
	bw := bufio.NewWriterSize(w, 32*1024)
	if format == "gpx" {
		w.Header().Set("Content-Type", "application/gpx+xml; charset=utf-8")
		_ = writeHistoryGPX(bw, name, from, to, iter)
	} else {
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		_ = writeHistoryCSV(bw, iter)
	}
	_ = bw.Flush()
}

// parseExportRange is parseHistoryRange with the larger export window.
func parseExportRange(r *http.Request, now time.Time) (time.Time, time.Time, string, bool) {
	fromStr := r.URL.Query().Get("from")
	toStr := r.URL.Query().Get("to")
	if fromStr == "" || toStr == "" {
		return time.Time{}, time.Time{}, "from and to are required", false
	}
	from, err := parseRFC3339(fromStr)
	if err != nil {
		return time.Time{}, time.Time{}, "from must be RFC3339", false
	}
	to, err := parseRFC3339(toStr)
	if err != nil {
		return time.Time{}, time.Time{}, "to must be RFC3339", false
	}
	if !to.After(from) {
		return time.Time{}, time.Time{}, "to must be after from", false
	}
	if to.Sub(from) > maxExportRange {
		return time.Time{}, time.Time{}, "range must be at most 31 days", false
	}
	if now.Sub(from) > config.LocationRetention() {
		return time.Time{}, time.Time{}, fmt.Sprintf("from is older than the %d-day retention window", config.LocationRetentionDays()), false
	}
	return from, to, "", true
}

// csvText makes a free-text cell safe to open in a spreadsheet: cells that
// would be read as a formula are prefixed with an apostrophe, and the cell is
// quoted when it holds a delimiter, quote or line break. Numeric columns never
// pass through here, so negative coordinates stay numbers.
func csvText(s string) string {
	if s != "" {
		switch s[0] {
		case '=', '+', '-', '@', '\t', '\r':
			s = "'" + s
		}
	}
	if strings.ContainsAny(s, ",\"\r\n") {
		s = `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
	}
	return s
}

func optFloat(p *float64) string {
	if p == nil {
		return ""
	}
	return strconv.FormatFloat(*p, 'f', -1, 64)
}

func writeHistoryCSV(w io.Writer, each exportIter) error {
	if _, err := io.WriteString(w, "timestamp,latitude,longitude,accuracy_m,speed_mps,battery_pct,motion_state\r\n"); err != nil {
		return err
	}
	return each(func(p exportPoint) error {
		acc := ""
		if p.Accuracy > 0 {
			acc = strconv.FormatFloat(p.Accuracy, 'f', -1, 64)
		}
		_, err := io.WriteString(w, strings.Join([]string{
			p.TS.UTC().Format(time.RFC3339),
			strconv.FormatFloat(p.Lat, 'f', 6, 64),
			strconv.FormatFloat(p.Lon, 'f', 6, 64),
			acc,
			optFloat(p.SpeedMPS),
			optFloat(p.BatteryPct),
			csvText(p.MotionState),
		}, ",")+"\r\n")
		return err
	})
}

func xmlText(s string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

func writeHistoryGPX(w io.Writer, name string, from, to time.Time, each exportIter) error {
	title := strings.TrimSpace(name)
	if title == "" {
		title = "Member"
	}
	title += " " + from.UTC().Format("2006-01-02") + " to " + to.UTC().Format("2006-01-02")
	if _, err := io.WriteString(w, `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="OpenFamily" xmlns="http://www.topografix.com/GPX/1/1">
<trk><name>`+xmlText(title)+`</name><trkseg>
`); err != nil {
		return err
	}
	err := each(func(p exportPoint) error {
		_, err := io.WriteString(w, `<trkpt lat="`+strconv.FormatFloat(p.Lat, 'f', 6, 64)+
			`" lon="`+strconv.FormatFloat(p.Lon, 'f', 6, 64)+`"><time>`+
			p.TS.UTC().Format(time.RFC3339)+"</time></trkpt>\n")
		return err
	})
	if err != nil {
		return err
	}
	_, err = io.WriteString(w, "</trkseg></trk>\n</gpx>\n")
	return err
}
