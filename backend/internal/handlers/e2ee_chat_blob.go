package handlers

// Encrypted chat attachments (docs/design/E2EE_CHAT.md). A phone encrypts a
// photo with a fresh random per-file key and uploads the opaque result; the key
// travels only inside the sealed chat message. The server stores bytes it cannot
// read, for the same time as the chat ciphertext, and serves them to circle
// members only.

import (
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
)

const (
	e2eeBlobMaxBytes   = 6 << 20 // 5 MiB photo + sealing overhead
	e2eeBlobPerMinute  = 20
	e2eeBlobMaxPerCirc = 500
)

// E2EEPostBlob stores an encrypted attachment. POST /circles/{id}/e2ee/blobs
// (raw body, application/octet-stream). Returns {"id": "..."}.
func (s *Server) E2EEPostBlob(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeblob:user:"+uid, e2eeBlobPerMinute, time.Minute) {
		return
	}
	ctx := r.Context()
	if !s.circleIsPrivate(ctx, m.CircleID) {
		writeE2EECode(w, http.StatusConflict, "circle_not_private", "circle is not end-to-end encrypted")
		return
	}
	if r.ContentLength > e2eeBlobMaxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "attachment is too large")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, e2eeBlobMaxBytes)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "attachment is too large")
		return
	}
	if len(raw) < 1 {
		writeError(w, http.StatusBadRequest, "empty attachment")
		return
	}
	var n int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM e2ee_blobs WHERE circle_id = $1`, m.CircleID).Scan(&n); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store attachment")
		return
	}
	if n >= e2eeBlobMaxPerCirc {
		writeE2EECode(w, http.StatusConflict, "too_many_attachments", "too many stored attachments in this circle")
		return
	}
	var id string
	if err := s.Pool.QueryRow(ctx, `
		INSERT INTO e2ee_blobs (circle_id, uploader_id, size_bytes, data, expires_at)
		VALUES ($1, $2, $3, $4, $5) RETURNING id::text`,
		m.CircleID, uid, len(raw), raw, time.Now().UTC().Add(e2eeChatTTL()+24*time.Hour)).Scan(&id); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store attachment")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

// E2EEGetBlob serves an encrypted attachment to a circle member.
// GET /circles/{id}/e2ee/blobs/{blobId}
func (s *Server) E2EEGetBlob(w http.ResponseWriter, r *http.Request) {
	_, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "blobId")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "attachment not found")
		return
	}
	var data []byte
	err := s.Pool.QueryRow(r.Context(), `
		SELECT data FROM e2ee_blobs WHERE id = $1 AND circle_id = $2 AND expires_at > now()`, id, m.CircleID).Scan(&data)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "attachment not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load attachment")
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "private, no-store")
	_, _ = w.Write(data)
}
