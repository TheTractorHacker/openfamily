package handlers

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/TheTractorHacker/openfamily/backend/internal/push"
)

// Family chat: per-circle text messages. Every handler authorizes the caller as
// a member of the circle through requireCircleMember (non-members get 404, the
// same as a circle that does not exist). Live delivery rides the existing
// WebSocket hub; offline members get a push whose text carries no location data.

const (
	maxChatBodyLen    = 2000
	chatPageDefault   = 50
	chatPageMax       = 100
	chatSendPerMinute = 20
	chatSendWindow    = time.Minute
	chatPushPreview   = 120
)

type chatMessageOut struct {
	ID         string    `json:"id"`
	Seq        int64     `json:"seq"`
	CircleID   string    `json:"circle_id"`
	SenderID   string    `json:"sender_id"`
	SenderName string    `json:"sender_name"`
	Body       string    `json:"body"`
	CreatedAt  time.Time `json:"created_at"`
}

// wsChat is the live frame sent to every socket subscribed to the circle.
type wsChat struct {
	Type     string         `json:"type"`
	CircleID string         `json:"circle_id"`
	Message  chatMessageOut `json:"message"`
}

// ListChatMessages returns a page of messages, newest first. `before` is the
// seq of the oldest message already held (omit for the newest page); the
// response's next_before is the cursor for the following page, or null at the
// start of history.
func (s *Server) ListChatMessages(w http.ResponseWriter, r *http.Request) {
	_, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	limit := chatPageDefault
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			writeError(w, http.StatusBadRequest, "invalid limit")
			return
		}
		limit = min(n, chatPageMax)
	}
	before := int64(0)
	if v := r.URL.Query().Get("before"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 1 {
			writeError(w, http.StatusBadRequest, "invalid before")
			return
		}
		before = n
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT cm.id, cm.seq, cm.circle_id, cm.sender_id, COALESCE(u.name, ''), cm.body, cm.created_at
		FROM chat_messages cm JOIN users u ON u.id = cm.sender_id
		WHERE cm.circle_id = $1 AND ($2::bigint = 0 OR cm.seq < $2)
		ORDER BY cm.seq DESC
		LIMIT $3`, m.CircleID, before, limit+1)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load messages")
		return
	}
	defer rows.Close()
	out := []chatMessageOut{}
	for rows.Next() {
		var c chatMessageOut
		if err := rows.Scan(&c.ID, &c.Seq, &c.CircleID, &c.SenderID, &c.SenderName, &c.Body, &c.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load messages")
			return
		}
		out = append(out, c)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to load messages")
		return
	}
	var next *int64
	if len(out) > limit {
		out = out[:limit]
		v := out[len(out)-1].Seq
		next = &v
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": out, "next_before": next})
}

// SendChatMessage stores a message from the caller and fans it out.
func (s *Server) SendChatMessage(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	var req struct {
		Body string `json:"body"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	body := strings.TrimSpace(req.Body)
	if body == "" {
		writeError(w, http.StatusBadRequest, "message is empty")
		return
	}
	if !utf8.ValidString(body) || strings.ContainsRune(body, 0) {
		writeError(w, http.StatusBadRequest, "invalid message")
		return
	}
	if utf8.RuneCountInString(body) > maxChatBodyLen {
		writeError(w, http.StatusRequestEntityTooLarge, "message is too long (max 2000 characters)")
		return
	}
	if !s.allowKey(w, "chat:send:"+uid, chatSendPerMinute, chatSendWindow) {
		return
	}
	var msg chatMessageOut
	err := s.Pool.QueryRow(r.Context(), `
		WITH ins AS (
			INSERT INTO chat_messages (circle_id, sender_id, body) VALUES ($1, $2, $3)
			RETURNING id, seq, circle_id, sender_id, body, created_at
		)
		SELECT ins.id, ins.seq, ins.circle_id, ins.sender_id, COALESCE(u.name, ''), ins.body, ins.created_at
		FROM ins JOIN users u ON u.id = ins.sender_id`,
		m.CircleID, uid, body,
	).Scan(&msg.ID, &msg.Seq, &msg.CircleID, &msg.SenderID, &msg.SenderName, &msg.Body, &msg.CreatedAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to send message")
		return
	}
	// The sender has implicitly read everything up to their own message.
	_, _ = s.Pool.Exec(r.Context(), `
		INSERT INTO chat_reads (circle_id, user_id, last_seq) VALUES ($1, $2, $3)
		ON CONFLICT (circle_id, user_id) DO UPDATE SET last_seq = GREATEST(chat_reads.last_seq, EXCLUDED.last_seq)`,
		m.CircleID, uid, msg.Seq)

	if frame, err := json.Marshal(wsChat{Type: "chat", CircleID: msg.CircleID, Message: msg}); err == nil {
		s.hub.broadcastCircles([]string{msg.CircleID}, "", frame)
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		s.pushChatMessage(ctx, msg)
	}()
	writeJSON(w, http.StatusCreated, msg)
}

// MarkChatRead records that the caller has read the circle up to seq (or to the
// newest message when seq is omitted). It never moves backwards.
func (s *Server) MarkChatRead(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	var req struct {
		Seq *int64 `json:"seq"`
	}
	if r.ContentLength != 0 {
		r.Body = http.MaxBytesReader(w, r.Body, 1<<10)
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
	}
	// Clamp to the newest message in this circle so a client cannot bank
	// future messages as read.
	_, err := s.Pool.Exec(r.Context(), `
		INSERT INTO chat_reads (circle_id, user_id, last_seq)
		SELECT $1, $2, LEAST(COALESCE($3::bigint, mx), mx)
		FROM (SELECT COALESCE(MAX(seq), 0) AS mx FROM chat_messages WHERE circle_id = $1) t
		ON CONFLICT (circle_id, user_id) DO UPDATE SET last_seq = GREATEST(chat_reads.last_seq, EXCLUDED.last_seq)`,
		m.CircleID, uid, req.Seq)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to mark read")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ChatUnread returns the caller's unread count (other people's messages newer
// than their read marker) for each circle they belong to.
func (s *Server) ChatUnread(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT cm.circle_id,
		       (SELECT COUNT(*) FROM chat_messages x
		        WHERE x.circle_id = cm.circle_id AND x.sender_id <> $1
		          AND x.seq > COALESCE(r.last_seq, 0))
		FROM live_circle_members cm
		LEFT JOIN chat_reads r ON r.circle_id = cm.circle_id AND r.user_id = cm.user_id
		WHERE cm.user_id = $1`, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load unread")
		return
	}
	defer rows.Close()
	counts := map[string]int{}
	total := 0
	for rows.Next() {
		var id string
		var n int
		if err := rows.Scan(&id, &n); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load unread")
			return
		}
		counts[id] = n
		total += n
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to load unread")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"circles": counts, "total": total})
}

// pushChatMessage notifies every other member's devices. The text is chat
// content, never location data; unless VERBOSE_PUSH is on it is also left out,
// so a lock screen shows only "New message in <circle>".
func (s *Server) pushChatMessage(ctx context.Context, msg chatMessageOut) {
	if s.Push == nil {
		return
	}
	var circleName string
	if err := s.Pool.QueryRow(ctx, `SELECT name FROM circles WHERE id = $1`, msg.CircleID).Scan(&circleName); err != nil {
		slog.Warn("chat push: load circle", "err", err)
		return
	}
	title, body := "New message in "+circleName, ""
	if s.VerbosePush {
		body = msg.SenderName + ": " + truncateRunes(msg.Body, chatPushPreview)
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT d.user_id, d.platform, d.push_token, d.unifiedpush_endpoint, d.id, d.push_transport
		FROM devices d
		JOIN live_circle_members cm ON cm.user_id = d.user_id AND cm.circle_id = $1
		WHERE d.user_id <> $2
		  AND ((d.platform = 'ios' AND d.push_token IS NOT NULL AND d.push_token <> '')
		       OR (d.platform = 'android' AND d.unifiedpush_endpoint IS NOT NULL AND d.unifiedpush_endpoint <> '')
		       OR (d.platform = 'android' AND d.push_transport = 'direct'))`,
		msg.CircleID, msg.SenderID)
	if err != nil {
		slog.Warn("chat push: list devices", "err", err)
		return
	}
	var ns []push.Notification
	for rows.Next() {
		var uid, platform, devID, transport string
		var token, endpoint *string
		if err := rows.Scan(&uid, &platform, &token, &endpoint, &devID, &transport); err != nil {
			continue
		}
		n := push.Notification{
			Title: title, Body: body, Platform: platform,
			PushToken: derefOrEmpty(token), UnifiedPushEndpoint: derefOrEmpty(endpoint),
		}
		if platform == "android" && transport == "direct" && s.Direct != nil {
			n = directNotification(n, devID, uid, "", "chat:"+msg.ID)
		}
		ns = append(ns, n)
	}
	rows.Close()
	for _, n := range ns {
		if err := s.dispatchBest(ctx, n); err != nil {
			slog.Warn("chat push: dispatch failed", "err", err)
		}
	}
}

func truncateRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n]) + "…"
}
