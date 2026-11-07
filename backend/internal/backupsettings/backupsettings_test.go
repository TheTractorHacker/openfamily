package backupsettings

import (
	"net"
	"strings"
	"testing"
)

func TestCheckIPPolicy(t *testing.T) {
	always := []string{"169.254.169.254", "169.254.1.1", "fe80::1", "0.0.0.0", "224.0.0.1", "100.100.100.200", "fd00:ec2::254"}
	for _, ip := range always {
		for _, allow := range []bool{false, true} {
			if CheckIP(net.ParseIP(ip), allow) == nil {
				t.Errorf("%s accepted (allowPrivate=%v)", ip, allow)
			}
		}
	}
	for _, ip := range []string{"127.0.0.1", "::1", "10.1.2.3", "192.168.0.5", "172.16.0.1", "100.64.0.1", "fd12::1"} {
		if CheckIP(net.ParseIP(ip), false) == nil {
			t.Errorf("%s accepted without allowPrivate", ip)
		}
		if CheckIP(net.ParseIP(ip), true) != nil {
			t.Errorf("%s refused with allowPrivate", ip)
		}
	}
	for _, ip := range []string{"8.8.8.8", "2606:4700::1111"} {
		if CheckIP(net.ParseIP(ip), false) != nil {
			t.Errorf("public %s refused", ip)
		}
	}
	// IPv4-mapped IPv6 must not bypass.
	if CheckIP(net.ParseIP("::ffff:169.254.169.254"), true) == nil {
		t.Error("mapped metadata address accepted")
	}
	if CheckHost("Metadata.Google.Internal.", true) == nil {
		t.Error("metadata name accepted")
	}
}

func TestSealOpen(t *testing.T) {
	k, err := DeriveKey("0123456789abcdef0123")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DeriveKey("short"); err == nil {
		t.Fatal("short secret accepted")
	}
	blob, _ := Seal(k, Credentials{AccessKeyID: "AKIA1234", SecretKey: "s3cr3tvalue"})
	if strings.Contains(string(blob), "s3cr3tvalue") {
		t.Fatal("plaintext in blob")
	}
	c, err := Open(k, blob)
	if err != nil || c.SecretKey != "s3cr3tvalue" {
		t.Fatal(err)
	}
	// Payload and credentials are not interchangeable (distinct AAD).
	if _, err := OpenPayload(k, blob); err == nil {
		t.Fatal("credentials blob opened as a payload")
	}
	blob[len(blob)-1] ^= 1
	if _, err := Open(k, blob); err == nil {
		t.Fatal("tampered blob accepted")
	}
	k2, _ := DeriveKey("0123456789abcdef0124")
	if k1b, _ := Seal(k2, Credentials{}); k1b == nil {
		t.Fatal()
	}
}

func TestValidateRecipientsDoesNotEchoPrivateKey(t *testing.T) {
	err := ValidateRecipients([]string{"AGE-SECRET-KEY-1ABCDEF"})
	if err == nil || strings.Contains(err.Error(), "1ABCDEF") || !strings.Contains(err.Error(), "PRIVATE") {
		t.Fatalf("%v", err)
	}
}
