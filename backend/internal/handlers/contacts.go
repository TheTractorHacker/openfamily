package handlers

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

const (
	maxEmergencyContacts     = 10
	maxEmergencyContactName  = 80
	maxEmergencyContactPhone = 32
	maxEmergencyRelation     = 40
	minPhoneDigits           = 7
	maxPhoneDigits           = 15
)

type contactOut struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Phone     string    `json:"phone"`
	Relation  string    `json:"relation,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

type createContactRequest struct {
	Name     string `json:"name"`
	Phone    string `json:"phone"`
	Relation string `json:"relation"`
}

// ListContacts returns the caller's emergency contacts.
func (s *Server) ListContacts(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}

	rows, err := s.Pool.Query(r.Context(), `
		SELECT id, name, phone, relation, created_at
		FROM emergency_contacts
		WHERE user_id = $1
		ORDER BY created_at`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list contacts")
		return
	}
	defer rows.Close()

	contacts := []contactOut{}
	for rows.Next() {
		var c contactOut
		if err := rows.Scan(&c.ID, &c.Name, &c.Phone, &c.Relation, &c.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan contact")
			return
		}
		contacts = append(contacts, c)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read contacts")
		return
	}
	writeJSON(w, http.StatusOK, contacts)
}

// CreateContact adds an emergency contact for the caller.
func (s *Server) CreateContact(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}

	var req createContactRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	name, phone, digits, relation, err := normalizeEmergencyContact(req.Name, req.Phone, req.Relation)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	var count int
	if err := s.Pool.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM emergency_contacts WHERE user_id = $1`, claims.UserID,
	).Scan(&count); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to count contacts")
		return
	}
	if count >= maxEmergencyContacts {
		writeError(w, http.StatusBadRequest, "you can save at most 10 emergency contacts")
		return
	}

	var c contactOut
	err = s.Pool.QueryRow(r.Context(), `
		INSERT INTO emergency_contacts (user_id, name, phone, phone_digits, relation)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, name, phone, relation, created_at`,
		claims.UserID, name, phone, digits, relation,
	).Scan(&c.ID, &c.Name, &c.Phone, &c.Relation, &c.CreatedAt)
	if isUniqueViolation(err) {
		writeError(w, http.StatusConflict, "that phone number is already an emergency contact")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save contact")
		return
	}

	familyID, _ := s.familyIDForUser(r.Context(), claims.UserID)
	s.logAudit(r.Context(), claims.UserID, familyID, "contact.create", "added emergency contact "+c.ID, clientIP(r))
	writeJSON(w, http.StatusCreated, c)
}

// DeleteContact removes one of the caller's emergency contacts.
func (s *Server) DeleteContact(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if strings.TrimSpace(id) == "" {
		writeError(w, http.StatusBadRequest, "contact id is required")
		return
	}

	tag, err := s.Pool.Exec(r.Context(),
		`DELETE FROM emergency_contacts WHERE id = $1 AND user_id = $2`, id, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete contact")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "contact not found")
		return
	}

	familyID, _ := s.familyIDForUser(r.Context(), claims.UserID)
	s.logAudit(r.Context(), claims.UserID, familyID, "contact.delete", "removed emergency contact "+id, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// normalizeEmergencyContact trims and validates a contact. digits is the
// uniqueness key: punctuation is stripped so "415-555-0132" and
// "(415) 555-0132" collide for the same user.
func normalizeEmergencyContact(name, phone, relation string) (string, string, string, string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", "", "", "", errors.New("name is required")
	}
	if utf8.RuneCountInString(name) > maxEmergencyContactName {
		return "", "", "", "", errors.New("name is too long")
	}

	phone = strings.TrimSpace(phone)
	if phone == "" {
		return "", "", "", "", errors.New("phone is required")
	}
	if utf8.RuneCountInString(phone) > maxEmergencyContactPhone {
		return "", "", "", "", errors.New("phone is too long")
	}

	digits := phoneDigits(phone)
	if len(digits) < minPhoneDigits || len(digits) > maxPhoneDigits {
		return "", "", "", "", errors.New("enter a valid phone number")
	}

	relation = strings.TrimSpace(relation)
	if utf8.RuneCountInString(relation) > maxEmergencyRelation {
		return "", "", "", "", errors.New("relation is too long")
	}

	return name, phone, digits, relation, nil
}

func phoneDigits(phone string) string {
	var b strings.Builder
	b.Grow(len(phone))
	for _, r := range phone {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}
