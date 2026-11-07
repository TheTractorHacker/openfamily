package compat

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	good := map[string]Version{
		"0.20.1": {0, 20, 1}, "v0.20.1": {0, 20, 1}, "0.20.1+45": {0, 20, 1},
		"0.21.0-rc1": {0, 21, 0}, "1.2": {1, 2, 0}, " 0.9.5 ": {0, 9, 5},
	}
	for in, want := range good {
		got, ok := Parse(in)
		if !ok || got != want {
			t.Errorf("Parse(%q) = %v,%v want %v", in, got, ok, want)
		}
	}
	for _, bad := range []string{"", "abc", "1", "1.x.2", "1.2.3.4", "-1.2.3", "Dart/3.4", "0..1"} {
		if _, ok := Parse(bad); ok {
			t.Errorf("Parse(%q) should fail", bad)
		}
	}
}

func TestReleasesSorted(t *testing.T) {
	prev := Version{}
	for _, s := range Releases {
		v := MustParse(s)
		if !prev.Less(v) {
			t.Fatalf("Releases not strictly ascending at %s", s)
		}
		prev = v
	}
}

// pinReleases fixes the release list so these tests describe the rolling rule
// itself and do not change every time a release is added to Releases.
func pinReleases(t *testing.T, list ...string) {
	t.Helper()
	old := Releases
	Releases = list
	t.Cleanup(func() { Releases = old })
}

var testReleases = []string{"0.14.0", "0.15.0", "0.16.0", "0.17.0", "0.18.0", "0.19.0", "0.20.0"}

func TestWindowRolls(t *testing.T) {
	pinReleases(t, testReleases...)
	p := Compute("", "")
	if p.Min != (Version{0, 16, 0}) || p.Latest != (Version{0, 20, 0}) || len(p.Window) != WindowSize {
		t.Fatalf("policy = %+v", p)
	}
	// A new release pushes the oldest line out.
	Releases = append(append([]string{}, testReleases...), "0.21.0")
	if got := Compute("", "").Min; got != (Version{0, 17, 0}) {
		t.Fatalf("min after new release = %v", got)
	}
}

func TestOverridePrecedence(t *testing.T) {
	if p := Compute("0.10.0", ""); p.Min != (Version{0, 10, 0}) || p.Source != "env" {
		t.Fatalf("env: %+v", p)
	}
	if p := Compute("0.10.0", "0.12.3"); p.Min != (Version{0, 12, 3}) || p.Source != "admin" {
		t.Fatalf("admin: %+v", p)
	}
	if p := Compute("junk", "also junk"); p.Source != "window" {
		t.Fatalf("junk ignored: %+v", p)
	}
	if p := Compute("", "9.0.0"); p.Latest.Less(p.Min) {
		t.Fatalf("latest below min: %+v", p)
	}
}

func TestClassify(t *testing.T) {
	pinReleases(t, testReleases...)
	p := Compute("", "") // min 0.16.0, latest 0.20.0
	cases := []struct {
		v    string
		want Status
	}{
		{"0.20.1", StatusOK}, {"0.19.0", StatusOK}, {"0.18.4", StatusRecommended},
		{"0.16.0", StatusRecommended}, {"0.15.1", StatusRequired}, {"0.1.0", StatusRequired},
		{"1.0.0", StatusOK},
	}
	for _, c := range cases {
		v, _ := Parse(c.v)
		if got := p.Classify(v, true); got != c.want {
			t.Errorf("Classify(%s) = %s want %s", c.v, got, c.want)
		}
	}
	if p.Classify(Version{}, false) != StatusUnknown {
		t.Error("no version must be unknown")
	}
}

func TestSupports(t *testing.T) {
	if Supports("private_circles", Version{0, 14, 0}, true) {
		t.Error("0.14 cannot read private circles")
	}
	if !Supports("private_circles", Version{0, 15, 0}, true) || !Supports("private_circles", Version{}, false) {
		t.Error("0.15 and unknown clients are capable")
	}
	if !Supports("no_such_feature", Version{0, 1, 0}, true) {
		t.Error("unknown feature is not gated")
	}
}

func TestDescribe(t *testing.T) {
	p := Compute("", "")
	in := p.Describe(Version{0, 10, 0}, true)
	if !in.UpgradeRequired || in.UpgradeRecommended || in.Message == "" || in.ClientVersion != "0.10.0" {
		t.Fatalf("%+v", in)
	}
	if in := p.Describe(Version{}, false); in.Status != StatusUnknown || in.ClientVersion != "" {
		t.Fatalf("%+v", in)
	}
}

// TestContractAdditiveOnly is the additive-only guard. testdata/contract/<tag>.txt
// records every response/request field ("Struct.jsontag") the server declared
// at that release. For every recorded tag still inside the support window, each
// field must still exist. Removing or renaming one needs an entry in
// testdata/contract/allowed_removals.txt with a reason, and a compat shim.
func TestContractAdditiveOnly(t *testing.T) {
	cur, err := ScanContract("../..")
	if err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, c := range cur {
		have[c] = true
	}
	allowed := map[string]bool{}
	if b, err := os.ReadFile("testdata/contract/allowed_removals.txt"); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			if f := strings.Fields(l); len(f) > 0 && !strings.HasPrefix(f[0], "#") {
				allowed[f[0]] = true
			}
		}
	}
	files, _ := filepath.Glob("testdata/contract/v*.txt")
	if len(files) == 0 {
		t.Fatal("no contract fixtures recorded")
	}
	p := Compute("", "")
	checked := 0
	for _, f := range files {
		tag := strings.TrimSuffix(filepath.Base(f), ".txt")
		v, ok := Parse(tag)
		if !ok || v.Less(p.Min) {
			continue
		}
		checked++
		b, _ := os.ReadFile(f)
		for _, l := range strings.Fields(string(b)) {
			if !have[l] && !allowed[l] {
				t.Errorf("%s: field %s existed in %s (inside the support window) but is gone; keep it or add it to allowed_removals.txt with a shim", f, l, tag)
			}
		}
	}
	if checked == 0 {
		t.Fatal("no fixture inside the support window")
	}
}
