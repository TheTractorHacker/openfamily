package handlers

import (
	"bytes"
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

func TestPrepareAvatarCapsPixelsAndStripsMetadata(t *testing.T) {
	// 2500x2000 = 5 MP: valid for chat photos (12 MP) but over the avatar cap.
	if _, _, err := prepareAvatar(encodePNG(t, 2500, 2000), "image/png"); err != errAvatarInvalidDimensions {
		t.Fatalf("5 MP avatar err = %v, want %v", err, errAvatarInvalidDimensions)
	}
	// JPEG with an injected EXIF APP1 segment must come out without it.
	j := encodeJPEG(t, 8, 8)
	exif := append([]byte{0xFF, 0xE1, 0x00, 0x10}, []byte("Exif\x00\x00SECRETGPS")...)
	withExif := append(append(append([]byte{}, j[:2]...), exif...), j[2:]...)
	if !bytes.Contains(withExif, []byte("SECRETGPS")) {
		t.Fatal("fixture broken")
	}
	out, ct, err := prepareAvatar(withExif, "image/jpeg")
	if err != nil || ct != "image/jpeg" {
		t.Fatalf("prepareAvatar = %v %q", err, ct)
	}
	if bytes.Contains(out, []byte("SECRETGPS")) || bytes.Contains(out, []byte("Exif")) {
		t.Fatal("EXIF survived re-encode")
	}
}

func TestValidateTelemetry(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	ok := func(a, al, s, h, b *float64, m, src string) {
		t.Helper()
		if err := validateTelemetry(a, al, s, h, b, m, src); err != nil {
			t.Errorf("unexpected reject: %v", err)
		}
	}
	bad := func(a, al, s, h, b *float64, m, src string) {
		t.Helper()
		if validateTelemetry(a, al, s, h, b, m, src) == nil {
			t.Errorf("accepted %v %v %v %v %v %q %q", a, al, s, h, b, m, src)
		}
	}
	ok(nil, nil, nil, nil, nil, "", "")
	ok(f(5), f(120), f(-1), f(-1), f(80), "IN_VEHICLE", "background")
	bad(f(1e308), nil, nil, nil, nil, "", "")
	bad(nil, nil, f(-500), nil, nil, "", "")
	bad(nil, nil, nil, f(720), nil, "", "")
	bad(nil, nil, nil, nil, f(101), "", "")
	bad(nil, f(1e9), nil, nil, nil, "", "")
	bad(nil, nil, nil, nil, nil, string(bytes.Repeat([]byte("a"), 33)), "")
	bad(nil, nil, nil, nil, nil, "", "x<script>")
	kept, rej := filterBatchPoints([]batchPoint{
		{Lat: 1, Lon: 1, MotionState: "walking"},
		{Lat: 1, Lon: 1, Source: string(bytes.Repeat([]byte("s"), 5000))},
	}, time.Now())
	if len(kept) != 1 || rej != 1 {
		t.Fatalf("batch kept=%d rejected=%d", len(kept), rej)
	}
}

func TestInviteCodeTail(t *testing.T) {
	if got := inviteCodeTail("ABCDEFGH1234"); got != "...1234" {
		t.Fatal(got)
	}
	if inviteCodeTail("ab") != "****" {
		t.Fatal("short")
	}
}

func TestClientVersionRowsBounded(t *testing.T) {
	e := newCircleEnv(t)
	ctx := context.Background()
	a := e.ids["A"]
	for i := 0; i < 60; i++ {
		if err := middleware.UpsertClientVersion(ctx, e.pool, a, fmt.Sprintf("1.%d.0", i), "android"); err != nil {
			t.Fatal(err)
		}
	}
	var n int
	var newest bool
	if err := e.pool.QueryRow(ctx, `SELECT count(*), bool_or(app_version='1.59.0') FROM app_client_versions WHERE user_id=$1`, a).Scan(&n, &newest); err != nil {
		t.Fatal(err)
	}
	if n != 20 || !newest {
		t.Fatalf("rows=%d newest kept=%v", n, newest)
	}
}
