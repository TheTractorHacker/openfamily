package handlers

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

func TestNormalizeProfileName(t *testing.T) {
	got, err := normalizeProfileName("  Frank  ")
	if err != nil {
		t.Fatalf("normalizeProfileName returned error: %v", err)
	}
	if got != "Frank" {
		t.Fatalf("got %q, want %q", got, "Frank")
	}

	for _, input := range []string{"", "   ", strings.Repeat("x", 121)} {
		if _, err := normalizeProfileName(input); err == nil {
			t.Errorf("normalizeProfileName(%q) accepted invalid input", input)
		}
	}
}

func TestValidateAvatarUpload(t *testing.T) {
	pngAvatar := encodePNG(t, 2, 3)
	jpegAvatar := encodeJPEG(t, 2, 3)
	tooWidePNG := encodePNG(t, avatarMaxDimension+1, 1)
	truncatedPNG := pngAvatar[:33] // Signature plus the complete IHDR chunk.
	truncatedJPEG := jpegThroughSOS(t, jpegAvatar)

	// These inputs have enough header data for DecodeConfig, but no image data
	// to decode. They prove validation performs the required full-decode pass
	// after the dimension checks.
	assertDecodeConfigSucceeds(t, truncatedPNG)
	assertDecodeConfigSucceeds(t, truncatedJPEG)

	tests := []struct {
		name        string
		avatar      []byte
		contentType string
		wantType    string
		wantErr     error
	}{
		{
			name:        "valid png",
			avatar:      pngAvatar,
			contentType: "image/png",
			wantType:    "image/png",
		},
		{
			name:        "valid jpeg",
			avatar:      jpegAvatar,
			contentType: "image/jpeg",
			wantType:    "image/jpeg",
		},
		{
			name:        "declared type does not match bytes",
			avatar:      pngAvatar,
			contentType: "image/jpeg",
			wantErr:     errAvatarContentTypeMismatch,
		},
		{
			name:        "not an image",
			avatar:      []byte("not an image"),
			contentType: "image/png",
			wantErr:     errAvatarContentTypeMismatch,
		},
		{
			name:        "truncated png after a valid header",
			avatar:      truncatedPNG,
			contentType: "image/png",
			wantErr:     errAvatarInvalidImage,
		},
		{
			name:        "truncated jpeg after a valid header",
			avatar:      truncatedJPEG,
			contentType: "image/jpeg",
			wantErr:     errAvatarInvalidImage,
		},
		{
			name:        "empty image",
			avatar:      nil,
			contentType: "image/png",
			wantErr:     errAvatarInvalidImage,
		},
		{
			name:        "dimension limit",
			avatar:      tooWidePNG,
			contentType: "image/png",
			wantErr:     errAvatarInvalidDimensions,
		},
		{
			name:        "byte limit",
			avatar:      bytes.Repeat([]byte{0}, avatarMaxBytes+1),
			contentType: "image/png",
			wantErr:     errAvatarTooLarge,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotType, err := validateAvatarUpload(tt.avatar, tt.contentType)
			if err != tt.wantErr {
				t.Fatalf("validateAvatarUpload() error = %v, want %v", err, tt.wantErr)
			}
			if gotType != tt.wantType {
				t.Fatalf("validateAvatarUpload() content type = %q, want %q", gotType, tt.wantType)
			}
		})
	}
}

func TestAvatarContentType(t *testing.T) {
	tests := []struct {
		header  string
		want    string
		wantErr bool
	}{
		{header: "image/png", want: "image/png"},
		{header: "IMAGE/JPEG", want: "image/jpeg"},
		{header: "image/png; charset=binary", want: "image/png"},
		{header: "multipart/form-data; boundary=example", wantErr: true},
		{header: "image/gif", wantErr: true},
		{header: "", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.header, func(t *testing.T) {
			got, err := avatarContentType(tt.header)
			if (err != nil) != tt.wantErr {
				t.Fatalf("avatarContentType(%q) error = %v, wantErr = %v", tt.header, err, tt.wantErr)
			}
			if got != tt.want {
				t.Fatalf("avatarContentType(%q) = %q, want %q", tt.header, got, tt.want)
			}
		})
	}
}

func TestSetPrivateProfileHeaders(t *testing.T) {
	w := httptest.NewRecorder()
	setPrivateProfileHeaders(w)

	for header, want := range map[string]string{
		"Cache-Control":                "private, no-store",
		"Pragma":                       "no-cache",
		"X-Content-Type-Options":       "nosniff",
		"Referrer-Policy":              "no-referrer",
		"Cross-Origin-Resource-Policy": "same-origin",
	} {
		if got := w.Header().Get(header); got != want {
			t.Errorf("%s = %q, want %q", header, got, want)
		}
	}
}

func TestWritePrivateAvatar(t *testing.T) {
	t.Run("writes supported image data", func(t *testing.T) {
		w := httptest.NewRecorder()
		writePrivateAvatar(w, []byte{1, 2, 3}, "image/png")

		if w.Code != 200 {
			t.Fatalf("status = %d, want %d", w.Code, 200)
		}
		if got := w.Header().Get("Content-Type"); got != "image/png" {
			t.Errorf("Content-Type = %q, want image/png", got)
		}
		if got := w.Header().Get("Content-Length"); got != "3" {
			t.Errorf("Content-Length = %q, want 3", got)
		}
		if got := w.Body.Bytes(); !bytes.Equal(got, []byte{1, 2, 3}) {
			t.Errorf("body = %v, want [1 2 3]", got)
		}
	})

	t.Run("rejects unexpected stored content type", func(t *testing.T) {
		w := httptest.NewRecorder()
		writePrivateAvatar(w, []byte{1}, "text/html")

		if w.Code != 500 {
			t.Fatalf("status = %d, want %d", w.Code, 500)
		}
	})
}

func encodePNG(t *testing.T, width, height int) []byte {
	t.Helper()
	var output bytes.Buffer
	if err := png.Encode(&output, solidImage{width: width, height: height}); err != nil {
		t.Fatalf("encode PNG: %v", err)
	}
	return output.Bytes()
}

func encodeJPEG(t *testing.T, width, height int) []byte {
	t.Helper()
	var output bytes.Buffer
	if err := jpeg.Encode(&output, solidImage{width: width, height: height}, nil); err != nil {
		t.Fatalf("encode JPEG: %v", err)
	}
	return output.Bytes()
}

// jpegThroughSOS returns a valid JPEG prefix through the complete Start Of
// Scan segment. image.DecodeConfig can read the dimensions from that prefix,
// while image.Decode correctly rejects it because the scan data is absent.
func jpegThroughSOS(t *testing.T, jpegBytes []byte) []byte {
	t.Helper()
	for i := 0; i+4 <= len(jpegBytes); i++ {
		if jpegBytes[i] != 0xff || jpegBytes[i+1] != 0xda {
			continue
		}
		segmentLength := int(jpegBytes[i+2])<<8 | int(jpegBytes[i+3])
		end := i + 2 + segmentLength
		if segmentLength < 2 || end > len(jpegBytes) {
			t.Fatalf("invalid JPEG SOS segment")
		}
		return jpegBytes[:end]
	}
	t.Fatal("JPEG encoder did not produce a Start Of Scan segment")
	return nil
}

func assertDecodeConfigSucceeds(t *testing.T, imageBytes []byte) {
	t.Helper()
	if _, _, err := image.DecodeConfig(bytes.NewReader(imageBytes)); err != nil {
		t.Fatalf("expected DecodeConfig to accept image prefix: %v", err)
	}
}

// solidImage lets dimension-limit tests encode a large logical image without
// allocating a full RGBA backing store.
type solidImage struct {
	width  int
	height int
}

func (source solidImage) ColorModel() color.Model { return color.RGBAModel }

func (source solidImage) Bounds() image.Rectangle {
	return image.Rect(0, 0, source.width, source.height)
}

func (solidImage) At(_, _ int) color.Color { return color.RGBA{R: 1, A: 255} }

func TestUpdateMeUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Patch("/me", srv.UpdateMe)
	req := httptest.NewRequest(http.MethodPatch, "/me", strings.NewReader(`{"phone":"+15551234567"}`))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestChangeMyPasswordUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Patch("/me/password", srv.ChangeMyPassword)
	req := httptest.NewRequest(http.MethodPatch, "/me/password", strings.NewReader(`{"current_password":"old-password","new_password":"new-password"}`))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestDeleteAccountBlocked(t *testing.T) {
	cases := []struct {
		role                    models.Role
		adminCount, memberCount int
		blocked                 bool
	}{
		{models.RoleAdmin, 1, 3, true},
		{models.RoleAdmin, 1, 1, false},
		{models.RoleAdmin, 2, 3, false},
		{models.RoleMember, 1, 3, false},
	}
	for _, tc := range cases {
		got := deleteAccountBlocked(tc.role, tc.adminCount, tc.memberCount)
		if got != tc.blocked {
			t.Errorf("role=%s admins=%d members=%d blocked=%v want %v",
				tc.role, tc.adminCount, tc.memberCount, got, tc.blocked)
		}
	}
}

func TestDeleteMeUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Delete("/me", srv.DeleteMe)
	req := httptest.NewRequest(http.MethodDelete, "/me", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestValidatePasswordChange(t *testing.T) {
	tests := []struct {
		name    string
		current string
		next    string
		wantErr bool
	}{
		{name: "ok", current: "old-password", next: "new-password", wantErr: false},
		{name: "missing current", current: "", next: "new-password", wantErr: true},
		{name: "missing new", current: "old-password", next: "", wantErr: true},
		{name: "too short", current: "old-password", next: "short", wantErr: true},
		{name: "unchanged", current: "same-password", next: "same-password", wantErr: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := validatePasswordChange(tc.current, tc.next)
			if tc.wantErr && err == nil {
				t.Fatalf("validatePasswordChange(%q, %q) = nil, want error", tc.current, tc.next)
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("validatePasswordChange(%q, %q) = %v, want nil", tc.current, tc.next, err)
			}
		})
	}
}

func TestValidatePasswordChangeRejectsOversizedPasswords(t *testing.T) {
	long := strings.Repeat("a", 257)
	if err := validatePasswordChange("current-pass", long); err == nil {
		t.Fatal("oversized new password accepted")
	}
	if err := validatePasswordChange(long, "new-password"); err == nil {
		t.Fatal("oversized current password accepted")
	}
	if err := validatePasswordChange("current-pass", "new-password"); err != nil {
		t.Fatalf("normal change rejected: %v", err)
	}
}
