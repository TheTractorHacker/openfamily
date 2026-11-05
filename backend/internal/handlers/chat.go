package handlers

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/jpeg"
	"image/png"
	"io"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
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
	HasImage   bool      `json:"has_image"`
	CreatedAt  time.Time `json:"created_at"`
}

// wsChatRead tells the circle that a member has read up to Seq (drives the
// sender's "Seen by" line).
type wsChatRead struct {
	Type     string `json:"type"`
	CircleID string `json:"circle_id"`
	UserID   string `json:"user_id"`
	UserName string `json:"user_name"`
	Seq      int64  `json:"seq"`
}

type chatReaderOut struct {
	UserID  string `json:"user_id"`
	Name    string `json:"name"`
	LastSeq int64  `json:"last_seq"`
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
		SELECT cm.id, cm.seq, cm.circle_id, cm.sender_id, COALESCE(u.name, ''), cm.body, cm.image_data IS NOT NULL, cm.created_at
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
		if err := rows.Scan(&c.ID, &c.Seq, &c.CircleID, &c.SenderID, &c.SenderName, &c.Body, &c.HasImage, &c.CreatedAt); err != nil {
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
	writeJSON(w, http.StatusOK, map[string]any{
		"messages": out, "next_before": next, "readers": s.chatReaders(r.Context(), m.CircleID),
	})
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
	s.storeAndFanOutChat(w, r, m.CircleID, uid, body, nil, "")
}

// storeAndFanOutChat inserts a message (text and/or photo), marks it read for
// the sender, broadcasts the live frame and pushes to the other members.
func (s *Server) storeAndFanOutChat(w http.ResponseWriter, r *http.Request, circleID, uid, body string, img []byte, imgType string) {
	var msg chatMessageOut
	var imgArg, typeArg any
	if img != nil {
		imgArg, typeArg = img, imgType
	}
	err := s.Pool.QueryRow(r.Context(), `
		WITH ins AS (
			INSERT INTO chat_messages (circle_id, sender_id, body, image_data, image_content_type)
			VALUES ($1, $2, $3, $4, $5)
			RETURNING id, seq, circle_id, sender_id, body, image_data IS NOT NULL AS has_image, created_at
		)
		SELECT ins.id, ins.seq, ins.circle_id, ins.sender_id, COALESCE(u.name, ''), ins.body, ins.has_image, ins.created_at
		FROM ins JOIN users u ON u.id = ins.sender_id`,
		circleID, uid, body, imgArg, typeArg,
	).Scan(&msg.ID, &msg.Seq, &msg.CircleID, &msg.SenderID, &msg.SenderName, &msg.Body, &msg.HasImage, &msg.CreatedAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to send message")
		return
	}
	m := struct{ CircleID string }{circleID}
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
	var prev, last int64
	err := s.Pool.QueryRow(r.Context(), `
		WITH old AS (SELECT COALESCE((SELECT last_seq FROM chat_reads WHERE circle_id = $1 AND user_id = $2), 0) AS v),
		up AS (
			INSERT INTO chat_reads (circle_id, user_id, last_seq)
			SELECT $1, $2, LEAST(COALESCE($3::bigint, mx), mx)
			FROM (SELECT COALESCE(MAX(seq), 0) AS mx FROM chat_messages WHERE circle_id = $1) t
			ON CONFLICT (circle_id, user_id) DO UPDATE SET last_seq = GREATEST(chat_reads.last_seq, EXCLUDED.last_seq)
			RETURNING last_seq
		)
		SELECT old.v, up.last_seq FROM old, up`,
		m.CircleID, uid, req.Seq).Scan(&prev, &last)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to mark read")
		return
	}
	if last > prev {
		var name string
		_ = s.Pool.QueryRow(r.Context(), `SELECT COALESCE(name, '') FROM users WHERE id = $1`, uid).Scan(&name)
		if frame, err := json.Marshal(wsChatRead{Type: "chat_read", CircleID: m.CircleID, UserID: uid, UserName: name, Seq: last}); err == nil {
			s.hub.broadcastCircles([]string{m.CircleID}, "", frame)
		}
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
	dir := s.recipients(ctx)
	// Recipients who muted the sender (per-member notification settings) get
	// no chat push.
	muted := map[string]bool{}
	if mrows, err := s.Pool.Query(ctx, `SELECT user_id::text FROM member_notification_prefs WHERE subject_id = $1 AND muted`, msg.SenderID); err == nil {
		for mrows.Next() {
			var id string
			if mrows.Scan(&id) == nil {
				muted[id] = true
			}
		}
		mrows.Close()
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
		if muted[uid] {
			continue
		}
		title, body := chatPushCopy(dir.For(uid).Show, circleName, msg)
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

// chatPushCopy is the push copy for one recipient: just the circle name unless
// they opted in to names (or VERBOSE_PUSH), in which case it also carries the
// sender and a short preview.
func chatPushCopy(show bool, circleName string, msg chatMessageOut) (title, body string) {
	title = "New message in " + circleName
	if !show {
		return title, ""
	}
	switch {
	case msg.HasImage && msg.Body == "":
		return msg.SenderName + " sent a photo", circleName
	case msg.HasImage:
		return msg.SenderName + " sent a photo", truncateRunes(msg.Body, chatPushPreview)
	}
	return title, msg.SenderName + ": " + truncateRunes(msg.Body, chatPushPreview)
}

func truncateRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n]) + "…"
}

// chatReaders lists each current member's read marker (the caller included;
// the client ignores itself) so a sender can show "Seen by ...".
func (s *Server) chatReaders(ctx context.Context, circleID string) []chatReaderOut {
	out := []chatReaderOut{}
	rows, err := s.Pool.Query(ctx, `
		SELECT r.user_id, COALESCE(u.name, ''), r.last_seq
		FROM chat_reads r
		JOIN live_circle_members cm ON cm.circle_id = r.circle_id AND cm.user_id = r.user_id
		JOIN users u ON u.id = r.user_id
		WHERE r.circle_id = $1 AND r.last_seq > 0`, circleID)
	if err != nil {
		slog.Warn("chat readers", "err", err)
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var x chatReaderOut
		if rows.Scan(&x.UserID, &x.Name, &x.LastSeq) == nil {
			out = append(out, x)
		}
	}
	return out
}

const chatPhotoMaxBytes = avatarMaxBytes

// SendChatPhoto accepts a raw JPEG/PNG body (same validation as avatars),
// strips metadata by re-encoding, and posts it as a photo message.
func (s *Server) SendChatPhoto(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	declared, err := avatarContentType(r.Header.Get("Content-Type"))
	if err != nil {
		writeError(w, http.StatusUnsupportedMediaType, "photo must be image/jpeg or image/png")
		return
	}
	if r.ContentLength > chatPhotoMaxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "photo must not exceed 5 MiB")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, chatPhotoMaxBytes)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		var mb *http.MaxBytesError
		if errors.As(err, &mb) {
			writeError(w, http.StatusRequestEntityTooLarge, "photo must not exceed 5 MiB")
			return
		}
		writeError(w, http.StatusBadRequest, "failed to read photo")
		return
	}
	ct, err := validateAvatarUpload(raw, declared)
	if err != nil {
		code := http.StatusBadRequest
		if errors.Is(err, errAvatarTooLarge) {
			code = http.StatusRequestEntityTooLarge
		}
		writeError(w, code, strings.Replace(err.Error(), "avatar", "photo", -1))
		return
	}
	// Re-encode: drops EXIF/GPS and any trailing data.
	img, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		writeError(w, http.StatusBadRequest, "photo must be a valid PNG or JPEG image")
		return
	}
	var buf bytes.Buffer
	if ct == "image/png" {
		err = png.Encode(&buf, img)
	} else {
		err = jpeg.Encode(&buf, img, &jpeg.Options{Quality: 88})
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to process photo")
		return
	}
	if !s.allowKey(w, "chat:send:"+uid, chatSendPerMinute, chatSendWindow) {
		return
	}
	caption := strings.TrimSpace(r.URL.Query().Get("caption"))
	if !utf8.ValidString(caption) || strings.ContainsRune(caption, 0) || utf8.RuneCountInString(caption) > maxChatBodyLen {
		writeError(w, http.StatusBadRequest, "invalid caption")
		return
	}
	s.storeAndFanOutChat(w, r, m.CircleID, uid, caption, buf.Bytes(), ct)
}

// GetChatPhoto serves a photo message to members of its circle only. A
// message id from another circle answers 404.
func (s *Server) GetChatPhoto(w http.ResponseWriter, r *http.Request) {
	_, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	setPrivateProfileHeaders(w)
	id := chi.URLParam(r, "msgId")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "photo not found")
		return
	}
	var data []byte
	var ct string
	err := s.Pool.QueryRow(r.Context(), `
		SELECT image_data, image_content_type FROM chat_messages
		WHERE id = $1 AND circle_id = $2 AND image_data IS NOT NULL`, id, m.CircleID).Scan(&data, &ct)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "photo not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load photo")
		return
	}
	writePrivateAvatar(w, data, ct)
}
