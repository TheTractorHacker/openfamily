package atrest

import (
	"strings"
	"testing"
)

const goodSecret = "0123456789abcdef0123456789abcdef-secret"

func TestSealOpenRoundTripAndBinding(t *testing.T) {
	k := NewKeyring(NewDEK())
	s, err := k.Seal("t.c", "hunter2")
	if err != nil || !strings.HasPrefix(s, Prefix) || strings.Contains(s, "hunter2") {
		t.Fatalf("seal: %q %v", s, err)
	}
	if got, err := k.Open("t.c", s); err != nil || got != "hunter2" {
		t.Fatalf("open: %q %v", got, err)
	}
	// A sealed value moved to another column must not open.
	if _, err := k.Open("other.c", s); err == nil {
		t.Fatal("opened under a different label")
	}
	// Not sealed twice, empty stays empty, plaintext passes through.
	if s2, _ := k.Seal("t.c", s); s2 != s {
		t.Fatal("double seal")
	}
	if e, _ := k.Seal("t.c", ""); e != "" {
		t.Fatal("empty sealed")
	}
	if p, err := k.Open("t.c", "legacy"); err != nil || p != "legacy" {
		t.Fatal("plaintext must pass through")
	}
	// A different key cannot open it.
	if _, err := NewKeyring(NewDEK()).Open("t.c", s); err == nil {
		t.Fatal("opened under another key")
	}
}

func TestDisabledKeyring(t *testing.T) {
	var k *Keyring
	if s, _ := k.Seal("t.c", "x"); s != "x" {
		t.Fatal("disabled keyring must not seal")
	}
	if _, err := k.Open("t.c", Prefix+"AAAA"); err != ErrNoKey {
		t.Fatalf("sealed value without a key must fail, got %v", err)
	}
}

func TestWrapUnwrapAndKEK(t *testing.T) {
	kek, err := DeriveKEK(goodSecret)
	if err != nil {
		t.Fatal(err)
	}
	dek := NewDEK()
	w := Wrap(kek, dek)
	if got, err := Unwrap(kek, w); err != nil || string(got) != string(dek) {
		t.Fatalf("unwrap: %v", err)
	}
	other, _ := DeriveKEK(goodSecret + "x")
	if _, err := Unwrap(other, w); err == nil {
		t.Fatal("wrong key unwrapped")
	}
	if _, err := DeriveKEK("short"); err == nil {
		t.Fatal("short secret accepted")
	}
}
