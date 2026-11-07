package backupsettings

import (
	"fmt"
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

// wrap builds the transition-address forms of an IPv4 address.
func wrap(v4 string) map[string]string {
	b := net.ParseIP(v4).To4()
	h := func(x, y byte) string { return fmt.Sprintf("%02x%02x", x, y) }
	return map[string]string{
		"nat64":        fmt.Sprintf("64:ff9b::%s:%s", h(b[0], b[1]), h(b[2], b[3])),
		"6to4":         fmt.Sprintf("2002:%s:%s::1", h(b[0], b[1]), h(b[2], b[3])),
		"v4-compat":    fmt.Sprintf("::%s:%s", h(b[0], b[1]), h(b[2], b[3])),
		"teredo-srv":   fmt.Sprintf("2001:0:%s:%s::1", h(b[0], b[1]), h(b[2], b[3])),
		"teredo-cli":   fmt.Sprintf("2001:0:808:808:0:0:%s:%s", h(b[0]^0xff, b[1]^0xff), h(b[2]^0xff, b[3]^0xff)),
		"v4-mapped":    "::ffff:" + v4,
		"nat64-dotted": "64:ff9b::" + v4,
	}
}

func TestTransitionAddressesCannotSmuggleBadTargets(t *testing.T) {
	// 64:ff9b:1::/48 layout: bytes 6,7 then 9,10.
	nat64Local := func(v4 string) string {
		b := net.ParseIP(v4).To4()
		ip := make(net.IP, 16)
		copy(ip, []byte{0x00, 0x64, 0xff, 0x9b, 0x00, 0x01, b[0], b[1], 0, b[2], b[3], 0, 0, 0, 0, 0})
		return ip.String()
	}
	for _, bad := range []string{"169.254.169.254", "100.100.100.200", "0.0.0.0", "224.0.0.1"} {
		forms := wrap(bad)
		forms["nat64-local"] = nat64Local(bad)
		for name, addr := range forms {
			ip := net.ParseIP(addr)
			if ip == nil {
				t.Fatalf("bad test address %s (%s)", addr, name)
			}
			for _, allow := range []bool{false, true} {
				if CheckIP(ip, allow) == nil {
					t.Errorf("%s form %s (%s) accepted, allowPrivate=%v", bad, name, addr, allow)
				}
			}
		}
	}
	for _, priv := range []string{"127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.5.5", "100.64.1.1"} {
		forms := wrap(priv)
		forms["nat64-local"] = nat64Local(priv)
		for name, addr := range forms {
			ip := net.ParseIP(addr)
			if CheckIP(ip, false) == nil {
				t.Errorf("%s form %s (%s) accepted without allowPrivate", priv, name, addr)
			}
		}
	}
	// With allowPrivate a wrapped LAN address is fine, a wrapped public one too.
	if CheckIP(net.ParseIP("64:ff9b::192.168.1.20"), true) != nil {
		t.Error("wrapped LAN address refused with allowPrivate")
	}
	// Transition ranges are refused outright without allowPrivate, even around public addresses.
	for _, a := range []string{"64:ff9b::8.8.8.8", "2002:808:808::1", "::8.8.8.8", "2001:0:808:808::1"} {
		if CheckIP(net.ParseIP(a), false) == nil {
			t.Errorf("transition address %s accepted without allowPrivate", a)
		}
	}
	// Unspecified / loopback / mapped forms.
	for _, a := range []string{"::", "0.0.0.0", "::ffff:0.0.0.0", "::ffff:169.254.169.254", "::ffff:127.0.0.1", "::1"} {
		if CheckIP(net.ParseIP(a), false) == nil {
			t.Errorf("%s accepted", a)
		}
	}
	for _, a := range []string{"::", "0.0.0.0", "::ffff:0.0.0.0", "::ffff:169.254.169.254"} {
		if CheckIP(net.ParseIP(a), true) == nil {
			t.Errorf("%s accepted with allowPrivate", a)
		}
	}
	// Ordinary public IPv6 stays fine.
	if CheckIP(net.ParseIP("2606:4700::1111"), false) != nil {
		t.Error("public IPv6 refused")
	}
	// Literal hosts go through the same policy at save time.
	if ValidateEndpoint("https://[64:ff9b::a9fe:a9fe]", false, true) == nil {
		t.Error("NAT64-wrapped metadata endpoint accepted at save time")
	}
}

func TestIPv6AllowlistTable(t *testing.T) {
	type row struct {
		addr        string
		public, lan bool // accepted without / with allowPrivate
	}
	for _, r := range []row{
		{"2606:4700::1111", true, true}, // global unicast
		{"2a00:1450::1", true, true},    // global unicast
		{"3fff::1", true, true},         // 2000::/3
		{"2001:db8::1", false, false},   // documentation
		{"fd12:3456::1", false, true},   // ULA
		{"fc00::1", false, true},        // ULA
		{"::1", false, true},            // loopback
		{"fe80::1", false, false},       // link-local
		{"febf::1", false, false},       // link-local top of fe80::/10
		{"fec0::1", false, false},       // site-local (deprecated), not understood
		{"ff02::1", false, false},       // multicast
		{"ff0e::1", false, false},       // multicast
		{"::", false, false},            // unspecified
		{"4000::1", false, false},       // outside 2000::/3, not understood
		{"100::1", false, false},        // discard prefix
		{"64:ff9b:1::1", false, false},  // local-use NAT64 always refused
		{"64:ff9b:1:a9fe:a9::", false, false},
		{"fd00:ec2::254", false, false},   // AWS IPv6 metadata (inside ULA)
		{"64:ff9b::8.8.8.8", false, true}, // NAT64 /96: transition, embedded public
		{"2002:808:808::1", false, true},  // 6to4 around a public address
		{"2001:0:808:808::1", false, true},
		{"::8.8.8.8", false, true}, // IPv4-compatible
	} {
		ip := net.ParseIP(r.addr)
		if ip == nil {
			t.Fatalf("bad test address %s", r.addr)
		}
		if got := CheckIP(ip, false) == nil; got != r.public {
			t.Errorf("%s: accepted=%v without allowPrivate, want %v", r.addr, got, r.public)
		}
		if got := CheckIP(ip, true) == nil; got != r.lan {
			t.Errorf("%s: accepted=%v with allowPrivate, want %v", r.addr, got, r.lan)
		}
	}
}

func TestMappedIPv4IsRefusedIdenticallyEverywhere(t *testing.T) {
	for _, tc := range []struct {
		v4           string
		allowPrivate bool
		wantErr      bool
	}{
		{"169.254.169.254", true, true}, {"169.254.169.254", false, true},
		{"127.0.0.1", false, true}, {"127.0.0.1", true, false},
		{"10.0.0.5", false, true}, {"10.0.0.5", true, false},
		{"0.0.0.0", true, true},
		{"8.8.8.8", false, false},
	} {
		forms := []string{"::ffff:" + tc.v4, "0:0:0:0:0:ffff:" + tc.v4}
		for _, f := range forms {
			ip := net.ParseIP(f)
			native := CheckIP(net.ParseIP(tc.v4), tc.allowPrivate) != nil
			if native != tc.wantErr {
				t.Fatalf("%s: native decision %v, want %v", tc.v4, native, tc.wantErr)
			}
			// 16-byte parse, 4-byte, and resolver-style paths all agree.
			paths := map[string]error{
				"parse16":  CheckIP(ip, tc.allowPrivate),
				"to16":     CheckIP(net.IP(append([]byte(nil), ip.To16()...)), tc.allowPrivate),
				"to4":      CheckIP(ip.To4(), tc.allowPrivate),
				"host":     CheckHost(f, tc.allowPrivate),
				"endpoint": ValidateEndpoint("https://["+f+"]:9000", false, tc.allowPrivate),
				"dial":     GuardedDialControl(tc.allowPrivate)("tcp6", "["+f+"]:443", nil),
				"dial-v4":  GuardedDialControl(tc.allowPrivate)("tcp4", tc.v4+":443", nil),
			}
			for name, err := range paths {
				if (err != nil) != tc.wantErr {
					t.Errorf("%s via %s (allowPrivate=%v): err=%v, want error=%v", f, name, tc.allowPrivate, err, tc.wantErr)
				}
			}
		}
	}
}
