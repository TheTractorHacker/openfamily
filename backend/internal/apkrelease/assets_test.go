package apkrelease

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestClassifyBothNamingSchemes(t *testing.T) {
	cases := map[string]string{
		"orbitly-0.24.1.apk":           KindAndroidAPK,
		"openfamily-0.23.0.apk":        KindAndroidAPK,
		"Orbitly-0.24.0.APK":           KindAndroidAPK,
		"orbitly-0.24.1-arm64-v8a.apk": KindAndroidAPK,
		"orbitly-wear-0.24.1.apk":      KindWearAPK,
		"orbitly-0.24.1.aab":           KindAndroidAAB,
		"orbitly-0.24.1-unsigned.ipa":  KindIOSIPA,
		"openfamily-0.23.0.ipa":        KindIOSIPA,
		"SHA256SUMS.txt":               KindChecksums,
		"orbitly-0.24.1.spdx.json":     KindSBOM,
		"orbitly-sbom.cdx.json":        KindSBOM,
		"notes.txt":                    KindOther,
	}
	for name, want := range cases {
		if got := Classify(name); got != want {
			t.Errorf("Classify(%q) = %s, want %s", name, got, want)
		}
	}
}

func TestParseABIAndVersion(t *testing.T) {
	for name, want := range map[string]string{
		"orbitly-0.24.1.apk":              "universal",
		"orbitly-0.24.1-universal.apk":    "universal",
		"orbitly-0.24.1-arm64-v8a.apk":    "arm64-v8a",
		"app-armeabi-v7a-release.apk":     "armeabi-v7a",
		"orbitly-0.24.1-x86_64.apk":       "x86_64",
		"orbitly-0.24.1-x86.apk":          "x86",
		"orbitly-0.24.1-arm64.apk":        "arm64-v8a",
	} {
		if got := ParseABI(name); got != want {
			t.Errorf("ParseABI(%q) = %s, want %s", name, got, want)
		}
	}
	if v := ParseVersion("orbitly-wear-0.24.1.apk"); v != "0.24.1" {
		t.Errorf("version = %q", v)
	}
	if v := ParseVersion("orbitly-0.25.0-rc.1.apk"); v != "0.25.0-rc.1" {
		t.Errorf("version = %q", v)
	}
	if v := ParseVersion("app.apk"); v != "" {
		t.Errorf("version = %q", v)
	}
}

func TestPickAPKPrefersUniversalThenArm64AndSkipsWear(t *testing.T) {
	arm := asset{ID: 1, Name: "orbitly-0.24.1-arm64-v8a.apk"}
	v7 := asset{ID: 2, Name: "orbitly-0.24.1-armeabi-v7a.apk"}
	uni := asset{ID: 3, Name: "orbitly-0.24.1.apk"}
	x86 := asset{ID: 4, Name: "orbitly-0.24.1-x86_64.apk"}
	wear := asset{ID: 5, Name: "orbitly-wear-0.24.1.apk"}

	got, err := pickAPKAsset([]asset{wear, v7, arm, uni, x86})
	if err != nil || got.ID != 3 {
		t.Fatalf("with universal: %+v %v", got, err)
	}
	got, err = pickAPKAsset([]asset{wear, v7, x86, arm})
	if err != nil || got.ID != 1 {
		t.Fatalf("without universal: %+v %v", got, err)
	}
	got, err = pickAPKAsset([]asset{wear, x86, v7})
	if err != nil || got.ID != 2 {
		t.Fatalf("armv7 before x86: %+v %v", got, err)
	}
	if _, err := pickAPKAsset([]asset{wear, {Name: "x.ipa"}}); err != ErrNotFound {
		t.Fatalf("a wear-only release has no phone APK, got %v", err)
	}
}

func TestPickIPAAsset(t *testing.T) {
	for _, n := range []string{"orbitly-0.24.1-unsigned.ipa", "openfamily-0.23.0.IPA"} {
		got, err := pickIPAAsset([]asset{{Name: "a.apk"}, {ID: 9, Name: n}})
		if err != nil || got.ID != 9 {
			t.Fatalf("%s: %+v %v", n, got, err)
		}
	}
	if _, err := pickIPAAsset([]asset{{Name: "a.apk"}}); err != ErrNotFound {
		t.Fatal("expected ErrNotFound")
	}
}

func TestParseChecksums(t *testing.T) {
	h1 := strings.Repeat("a", 64)
	h2 := strings.Repeat("B", 64)
	got := ParseChecksums(strings.NewReader(h1 + "  orbitly-0.24.1.apk\n" + h2 + " *orbitly.ipa\nbad line\nxyz  nohash\n"))
	if got["orbitly-0.24.1.apk"] != h1 || got["orbitly.ipa"] != strings.ToLower(h2) || len(got) != 2 {
		t.Fatalf("got %v", got)
	}
}

type fakeGH struct {
	fail     atomic.Int32 // HTTP status to return for the list; 0 = ok
	listHits atomic.Int32
}

func (f *fakeGH) handler(t *testing.T) http.Handler {
	sum := strings.Repeat("c", 64) + "  orbitly-0.24.1.apk\n" + strings.Repeat("d", 64) + "  orbitly-0.24.1-unsigned.ipa\n"
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/acme/orbitly/releases":
			f.listHits.Add(1)
			if c := f.fail.Load(); c != 0 {
				http.Error(w, "nope", int(c))
				return
			}
			base := "http://" + r.Host
			_ = json.NewEncoder(w).Encode([]release{
				{TagName: "apk-ci-123", Assets: []asset{{Name: "x.apk"}}},
				{TagName: "v0.23.0", PublishedAt: time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), Assets: []asset{
					{ID: 1, Name: "openfamily-0.23.0.apk", Size: 10}}},
				{TagName: "v0.24.1", Name: "Orbitly 0.24.1", PublishedAt: time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC), Assets: []asset{
					{ID: 10, Name: "orbitly-0.24.1-arm64-v8a.apk", Size: 20, Digest: "sha256:" + strings.Repeat("e", 64), BrowserDownloadURL: base + "/dl/arm"},
					{ID: 11, Name: "orbitly-0.24.1.apk", Size: 30, BrowserDownloadURL: base + "/dl/uni"},
					{ID: 12, Name: "orbitly-0.24.1-unsigned.ipa", Size: 40},
					{ID: 13, Name: "orbitly-wear-0.24.1.apk", Size: 5},
					{ID: 14, Name: "SHA256SUMS.txt", URL: base + "/assets/sums"},
					{ID: 15, Name: "orbitly-0.24.1.spdx.json", Size: 7},
				}},
				{TagName: "v0.22.0", Draft: true, Assets: []asset{{Name: "orbitly-0.22.0.apk"}}},
			})
		case "/assets/sums":
			_, _ = io.WriteString(w, sum)
		default:
			http.NotFound(w, r)
		}
	})
}

func TestListReleasesClassifiesAndOrders(t *testing.T) {
	gh := &fakeGH{}
	srv := httptest.NewServer(gh.handler(t))
	defer srv.Close()
	rels, err := ListReleases(context.Background(), Options{Repo: "acme/orbitly", API: srv.URL, Client: srv.Client()}, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(rels) != 2 || rels[0].TagName != "v0.24.1" || rels[1].TagName != "v0.23.0" {
		t.Fatalf("releases (CI tag and draft must be ignored): %+v", rels)
	}
	byName := map[string]AssetInfo{}
	for _, a := range rels[0].Assets {
		byName[a.Name] = a
	}
	if a := byName["orbitly-0.24.1.apk"]; a.Kind != KindAndroidAPK || a.ABI != "universal" || a.SHA256 != strings.Repeat("c", 64) || a.Version != "0.24.1" {
		t.Errorf("universal: %+v", a)
	}
	if a := byName["orbitly-0.24.1-arm64-v8a.apk"]; a.ABI != "arm64-v8a" || a.SHA256 != strings.Repeat("e", 64) {
		t.Errorf("arm64 (digest wins over sums file): %+v", a)
	}
	if a := byName["orbitly-0.24.1-unsigned.ipa"]; a.Kind != KindIOSIPA || a.SHA256 != strings.Repeat("d", 64) {
		t.Errorf("ipa: %+v", a)
	}
	if a := byName["orbitly-wear-0.24.1.apk"]; a.Kind != KindWearAPK {
		t.Errorf("wear: %+v", a)
	}
	if byName["orbitly-0.24.1.spdx.json"].Kind != KindSBOM || byName["SHA256SUMS.txt"].Kind != KindChecksums {
		t.Errorf("sbom/sums: %+v", byName)
	}
	// An older release with only an APK is listed; absence of an IPA is the page's job to show.
	if len(rels[1].Assets) != 1 || rels[1].Assets[0].Version != "0.23.0" {
		t.Errorf("older: %+v", rels[1])
	}
	one, err := ListReleases(context.Background(), Options{Repo: "acme/orbitly", API: srv.URL, Client: srv.Client()}, 1)
	if err != nil || len(one) != 1 {
		t.Fatalf("n=1: %v %v", one, err)
	}
}

func TestListerCachesAndServesStaleOnGitHubFailure(t *testing.T) {
	gh := &fakeGH{}
	srv := httptest.NewServer(gh.handler(t))
	defer srv.Close()
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	l := &Lister{TTL: time.Minute, Now: func() time.Time { return now }}
	opts := Options{Repo: "acme/orbitly", API: srv.URL, Client: srv.Client()}

	res := l.Get(context.Background(), opts, 5, false)
	if res.Err != nil || len(res.Releases) != 2 || res.Stale {
		t.Fatalf("first: %+v", res)
	}
	l.Get(context.Background(), opts, 5, false)
	if gh.listHits.Load() != 1 {
		t.Fatalf("second call inside TTL must hit the cache, hits=%d", gh.listHits.Load())
	}

	// Rate limited (403) after the TTL: stale copy plus a plain-language error.
	now = now.Add(time.Hour)
	gh.fail.Store(403)
	res = l.Get(context.Background(), opts, 5, false)
	if !res.Stale || res.Err == nil || len(res.Releases) != 2 {
		t.Fatalf("rate limited: %+v", res)
	}
	if !strings.Contains(res.Err.Error(), "rate limit") {
		t.Errorf("error should explain the rate limit: %v", res.Err)
	}
	if !res.FetchedAt.Equal(time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)) {
		t.Errorf("stale copy keeps its original time: %v", res.FetchedAt)
	}

	// Offline: close the server.
	srv.Close()
	res = l.Get(context.Background(), opts, 5, true)
	if !res.Stale || res.Err == nil || len(res.Releases) != 2 {
		t.Fatalf("offline: %+v", res)
	}
}

func TestListerFailureWithoutCache(t *testing.T) {
	gh := &fakeGH{}
	gh.fail.Store(500)
	srv := httptest.NewServer(gh.handler(t))
	defer srv.Close()
	l := &Lister{}
	res := l.Get(context.Background(), Options{Repo: "acme/orbitly", API: srv.URL, Client: srv.Client()}, 5, false)
	if res.Err == nil || len(res.Releases) != 0 || res.Stale {
		t.Fatalf("%+v", res)
	}
	if res := l.Get(context.Background(), Options{Repo: "bad"}, 5, false); res.Err == nil {
		t.Fatal("bad repo must error")
	}
}

func TestSyncIPADownloadsAndKeepsApkCacheSeparate(t *testing.T) {
	dir := t.TempDir()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/acme/orbitly/releases":
			_ = json.NewEncoder(w).Encode([]release{
				{TagName: "v0.24.1", Assets: []asset{{ID: 1, Name: "orbitly-0.24.1.apk", URL: "http://" + r.Host + "/a/1"}}},
				{TagName: "v0.24.0", Assets: []asset{{ID: 2, Name: "orbitly-0.24.0-unsigned.ipa", URL: "http://" + r.Host + "/a/2"}}},
			})
		case "/a/1":
			_, _ = io.WriteString(w, "apk")
		case "/a/2":
			_, _ = io.WriteString(w, "ipa")
		}
	}))
	defer srv.Close()
	opts := Options{Repo: "acme/orbitly", DestDir: dir, API: srv.URL, Client: srv.Client()}
	ipa, err := SyncIPA(context.Background(), opts)
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(ipa); string(b) != "ipa" {
		t.Fatalf("ipa = %q", b)
	}
	apk, err := Sync(context.Background(), opts)
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(apk); string(b) != "apk" || apk == ipa {
		t.Fatalf("apk = %q", b)
	}
	if CachedName(dir, KindIOSIPA) != "orbitly-0.24.0-unsigned.ipa" || CachedName(dir, KindAndroidAPK) != "orbitly-0.24.1.apk" {
		t.Fatalf("names %q %q", CachedName(dir, KindIOSIPA), CachedName(dir, KindAndroidAPK))
	}
}

func TestSyncIPAMissing(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode([]release{{TagName: "v0.24.1", Assets: []asset{{ID: 1, Name: "orbitly-0.24.1.apk"}}}})
	}))
	defer srv.Close()
	_, err := SyncIPA(context.Background(), Options{Repo: "acme/orbitly", DestDir: t.TempDir(), API: srv.URL, Client: srv.Client()})
	if err == nil || !strings.Contains(err.Error(), "no APK") && err != ErrNotFound {
		t.Fatalf("err = %v", err)
	}
}
