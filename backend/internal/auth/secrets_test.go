package auth

import (
	"strings"
	"testing"
	"time"

	"github.com/pquerna/otp/totp"
)

func tm(secret string) *TokenManager {
	return NewTokenManager(secret, time.Minute, time.Hour)
}

func TestDeriveKeyIsPurposeBoundAndDeterministic(t *testing.T) {
	a := tm("test-secret-at-least-32-bytes-long!")
	if string(a.DeriveKey("x")) != string(a.DeriveKey("x")) {
		t.Fatal("not deterministic")
	}
	if string(a.DeriveKey("x")) == string(a.DeriveKey("y")) {
		t.Fatal("purposes collide")
	}
	if string(a.DeriveKey("x")) == string(tm("another-secret-at-least-32-bytes!!").DeriveKey("x")) {
		t.Fatal("different secrets collide")
	}
	if len(a.DeriveKey("x")) != 32 {
		t.Fatal("key length")
	}
}

func TestSealOpenSecret(t *testing.T) {
	k := tm("test-secret-at-least-32-bytes-long!").DeriveKey("totp")
	other := tm("another-secret-at-least-32-bytes!!").DeriveKey("totp")
	sealed, err := SealSecret(k, "JBSWY3DPEHPK3PXP")
	if err != nil || strings.Contains(sealed, "JBSWY3DP") || !strings.HasPrefix(sealed, "enc:v1:") {
		t.Fatalf("seal: %q %v", sealed, err)
	}
	again, _ := SealSecret(k, "JBSWY3DPEHPK3PXP")
	if again == sealed {
		t.Fatal("nonce reused")
	}
	for _, c := range []struct {
		name, in, key string
		want          string
		wantErr       bool
	}{
		{"roundtrip", sealed, string(k), "JBSWY3DPEHPK3PXP", false},
		{"legacy plaintext passes through", "JBSWY3DPEHPK3PXP", string(k), "JBSWY3DPEHPK3PXP", false},
		{"wrong key", sealed, string(other), "", true},
		{"tampered", sealed[:len(sealed)-3] + "AAA", string(k), "", true},
		{"truncated", "enc:v1:AAAA", string(k), "", true},
		{"bad base64", "enc:v1:!!!", string(k), "", true},
	} {
		got, err := OpenSecret([]byte(c.key), c.in)
		if (err != nil) != c.wantErr || got != c.want {
			t.Errorf("%s: got %q err=%v", c.name, got, err)
		}
	}
}

func TestMatchTOTPStep(t *testing.T) {
	secret := "JBSWY3DPEHPK3PXP"
	now := time.Unix(1_700_000_010, 0)
	cur := now.Unix() / 30
	codeAt := func(step int64) string {
		c, err := totp.GenerateCode(secret, time.Unix(step*30, 0))
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	cases := []struct {
		name string
		code string
		want int64
		ok   bool
	}{
		{"current", codeAt(cur), cur, true},
		{"previous (skew)", codeAt(cur - 1), cur - 1, true},
		{"next (skew)", codeAt(cur + 1), cur + 1, true},
		{"too old", codeAt(cur - 3), 0, false},
		{"too new", codeAt(cur + 3), 0, false},
		{"garbage", "abcdef", 0, false},
		{"short", "123", 0, false},
		{"empty", "", 0, false},
		{"padded", " " + codeAt(cur) + " ", cur, true},
	}
	for _, c := range cases {
		step, ok := MatchTOTPStep(secret, c.code, now)
		if ok != c.ok || (ok && step != c.want) {
			t.Errorf("%s: step=%d ok=%v want %d/%v", c.name, step, ok, c.want, c.ok)
		}
	}
}

func TestCodes(t *testing.T) {
	c, err := RandomCode(10)
	if err != nil || len(c) != 10 {
		t.Fatalf("%q %v", c, err)
	}
	for _, r := range c {
		if !strings.ContainsRune(codeAlphabet, r) {
			t.Fatalf("char %q outside alphabet", r)
		}
	}
	if got := FormatCode("ABCDEFGHJK"); got != "ABCDE-FGHJK" {
		t.Fatal(got)
	}
	for in, want := range map[string]string{
		"abcde-fghjk": "ABCDEFGHJK",
		" ab cd ":     "ABCD",
		"o1il":        "0111",
	} {
		if got := NormalizeCode(in); got != want {
			t.Errorf("normalize %q = %q want %q", in, got, want)
		}
	}
	k := []byte("0123456789abcdef0123456789abcdef")
	if MACCode(k, "AAAA") == MACCode(k, "AAAB") || MACCode(k, "AAAA") != MACCode(k, "AAAA") {
		t.Fatal("mac")
	}
}
