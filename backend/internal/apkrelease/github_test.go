package apkrelease

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestLatestInfoPicksHighestSemverWithAPK(t *testing.T) {
	published := time.Date(2026, time.August, 24, 22, 15, 0, 0, time.UTC)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/repos/acme/openfamily/releases/latest" {
			t.Errorf("must not call GitHub Latest; got %s", r.URL.Path)
			http.NotFound(w, r)
			return
		}
		if r.URL.Path != "/repos/acme/openfamily/releases" {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode([]release{
			{
				TagName: "apk-45",
				Name:    "Android APK 45",
				Assets:  []asset{{ID: 45, Name: "openfamily-release.apk", Size: 1}},
			},
			{
				TagName:     "v0.1.0",
				Name:        "OpenFamily 0.1.0",
				Body:        "First public release.",
				HTMLURL:     "https://github.com/acme/openfamily/releases/tag/v0.1.0",
				PublishedAt: published,
				Assets: []asset{{
					ID:   10,
					Name: "openfamily-0.1.0.apk",
					Size: 19_200_000,
				}},
			},
			{
				TagName: "v0.2.0",
				Name:    "OpenFamily 0.2.0",
				HTMLURL: "https://github.com/acme/openfamily/releases/tag/v0.2.0",
				Assets: []asset{{
					ID:   20,
					Name: "openfamily-0.2.0.apk",
					Size: 20_000_000,
				}},
			},
		})
	}))
	defer srv.Close()

	got, err := LatestInfo(context.Background(), Options{
		Repo:   "acme/openfamily",
		API:    srv.URL,
		Client: srv.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got.TagName != "v0.2.0" || got.Name != "OpenFamily 0.2.0" || got.AssetName != "openfamily-0.2.0.apk" {
		t.Fatalf("unexpected release info: %+v", got)
	}
	if got.AssetSize != 20_000_000 {
		t.Fatalf("unexpected asset metadata: %+v", got)
	}
}

func TestLatestInfoIgnoresGitHubLatestAPKTag(t *testing.T) {
	published := time.Date(2026, time.March, 1, 0, 0, 0, 0, time.UTC)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/acme/openfamily/releases/latest":
			// What GitHub Latest currently resolves to when CI set make_latest.
			_ = json.NewEncoder(w).Encode(release{
				TagName: "apk-45",
				Name:    "Android APK 45",
				Assets:  []asset{{ID: 45, Name: "openfamily-release.apk", Size: 54_000_000}},
			})
		case "/repos/acme/openfamily/releases":
			_ = json.NewEncoder(w).Encode([]release{
				{
					TagName: "apk-45",
					Name:    "Android APK 45",
					Assets:  []asset{{ID: 45, Name: "openfamily-release.apk", Size: 54_000_000}},
				},
				{
					TagName:     "v0.1.0",
					Name:        "OpenFamily 0.1.0",
					HTMLURL:     "https://github.com/acme/openfamily/releases/tag/v0.1.0",
					PublishedAt: published,
					Assets:      []asset{{ID: 1, Name: "openfamily-release.apk", Size: 18_000_000}},
				},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	got, err := LatestInfo(context.Background(), Options{
		Repo:   "acme/openfamily",
		API:    srv.URL,
		Client: srv.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got.TagName != "v0.1.0" {
		t.Fatalf("picked %q, want v0.1.0 (apk-* must not win even if GitHub Latest)", got.TagName)
	}
}

func TestLatestInfoMissingSemverAPK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/acme/openfamily/releases" {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode([]release{
			{
				TagName: "apk-45",
				Assets:  []asset{{ID: 45, Name: "openfamily-release.apk"}},
			},
			{
				TagName: "v0.1.0",
				Name:    "notes only",
				Assets:  []asset{{ID: 1, Name: "notes.txt"}},
			},
		})
	}))
	defer srv.Close()

	_, err := LatestInfo(context.Background(), Options{
		Repo:   "acme/openfamily",
		API:    srv.URL,
		Client: srv.Client(),
	})
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound (no fallback to apk-*)", err)
	}
}

func TestLatestInfoSkipsPrereleaseWhenStableExists(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/acme/openfamily/releases" {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode([]release{
			{
				TagName:    "v0.2.0-rc.1",
				Name:       "RC",
				Prerelease: true,
				Assets:     []asset{{ID: 2, Name: "openfamily-0.2.0-rc.1.apk"}},
			},
			{
				TagName:    "v1.0.0",
				Name:       "flagged prerelease",
				Prerelease: true,
				Assets:     []asset{{ID: 3, Name: "openfamily-1.0.0.apk"}},
			},
			{
				TagName: "v0.1.0",
				Name:    "stable",
				Assets:  []asset{{ID: 1, Name: "openfamily-0.1.0.apk"}},
			},
		})
	}))
	defer srv.Close()

	got, err := LatestInfo(context.Background(), Options{
		Repo:   "acme/openfamily",
		API:    srv.URL,
		Client: srv.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got.TagName != "v0.1.0" {
		t.Fatalf("picked %q, want stable v0.1.0 over prereleases", got.TagName)
	}
}

func TestLatestInfoPaginatesReleases(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/acme/openfamily/releases" {
			http.NotFound(w, r)
			return
		}
		switch r.URL.Query().Get("page") {
		case "", "1":
			w.Header().Set("Link", `<http://`+r.Host+`/repos/acme/openfamily/releases?page=2>; rel="next"`)
			_ = json.NewEncoder(w).Encode([]release{
				{TagName: "apk-45", Assets: []asset{{ID: 45, Name: "openfamily-release.apk"}}},
			})
		case "2":
			_ = json.NewEncoder(w).Encode([]release{
				{TagName: "v0.1.0", Name: "from page 2", Assets: []asset{{ID: 1, Name: "openfamily-0.1.0.apk", Size: 3}}},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	got, err := LatestInfo(context.Background(), Options{
		Repo:   "acme/openfamily",
		API:    srv.URL,
		Client: srv.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got.TagName != "v0.1.0" || got.Name != "from page 2" {
		t.Fatalf("pagination missed v* on later page: %+v", got)
	}
}

func TestSyncDownloadsAndCaches(t *testing.T) {
	dir := t.TempDir()
	var assetHits atomic.Int32

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
			t.Errorf("missing bearer token: %q", got)
		}
		switch {
		case r.URL.Path == "/repos/acme/openfamily/releases/latest":
			t.Errorf("must not call GitHub Latest")
			http.NotFound(w, r)
		case r.URL.Path == "/repos/acme/openfamily/releases":
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode([]release{{
				TagName: "v0.1.0",
				Assets: []asset{{
					ID:   42,
					Name: "openfamily-release.apk",
					URL:  "http://" + r.Host + "/assets/42",
					Size: 4,
				}},
			}})
		case r.URL.Path == "/assets/42":
			assetHits.Add(1)
			w.Header().Set("Content-Type", "application/vnd.android.package-archive")
			_, _ = io.WriteString(w, "apk!")
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	opts := Options{
		Repo:    "acme/openfamily",
		Token:   "test-token",
		DestDir: dir,
		API:     srv.URL,
		Client:  srv.Client(),
	}

	path, err := Sync(context.Background(), opts)
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "apk!" {
		t.Fatalf("cached APK = %q", got)
	}

	path2, err := Sync(context.Background(), opts)
	if err != nil {
		t.Fatal(err)
	}
	if path2 != path {
		t.Fatalf("second sync path %s != %s", path2, path)
	}
	if assetHits.Load() != 1 {
		t.Fatalf("expected one asset download, got %d", assetHits.Load())
	}
}

func TestSyncRedownloadsWhenAssetChanges(t *testing.T) {
	dir := t.TempDir()
	var currentID atomic.Int64
	currentID.Store(1)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := currentID.Load()
		switch {
		case strings.HasSuffix(r.URL.Path, "/releases/latest"):
			t.Errorf("must not call GitHub Latest")
			http.NotFound(w, r)
		case strings.HasSuffix(r.URL.Path, "/releases"):
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode([]release{{
				TagName: "v0.1.0",
				Assets: []asset{{
					ID:   id,
					Name: "openfamily-release.apk",
					URL:  "http://" + r.Host + "/assets/" + strconv.FormatInt(id, 10),
				}},
			}})
		case strings.HasPrefix(r.URL.Path, "/assets/"):
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = io.WriteString(w, "apk-"+strconv.FormatInt(id, 10))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	opts := Options{Repo: "acme/app", Token: "t", DestDir: dir, API: srv.URL, Client: srv.Client()}
	if _, err := Sync(context.Background(), opts); err != nil {
		t.Fatal(err)
	}
	currentID.Store(2)
	path, err := Sync(context.Background(), opts)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(path)
	if string(got) != "apk-2" {
		t.Fatalf("expected refreshed APK, got %q", got)
	}
}

func TestSyncReportsMissingRelease(t *testing.T) {
	dir := t.TempDir()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "not found", http.StatusNotFound)
	}))
	defer srv.Close()

	_, err := Sync(context.Background(), Options{Repo: "acme/app", DestDir: dir, API: srv.URL, Client: srv.Client()})
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("error should wrap ErrNotFound: %v", err)
	}
	if !strings.Contains(err.Error(), "GitHub returned 404") {
		t.Fatalf("error should report the missing release: %v", err)
	}
}

func TestPickLatestSemverRelease(t *testing.T) {
	apk := []asset{{Name: "app.apk", ID: 1}}
	tests := []struct {
		name string
		in   []release
		want string
		err  error
	}{
		{
			name: "highest stable v*",
			in: []release{
				{TagName: "v0.1.0", Assets: apk},
				{TagName: "apk-9", Assets: apk},
				{TagName: "v0.2.0", Assets: apk},
			},
			want: "v0.2.0",
		},
		{
			name: "draft ignored",
			in: []release{
				{TagName: "v0.3.0", Draft: true, Assets: apk},
				{TagName: "v0.1.0", Assets: apk},
			},
			want: "v0.1.0",
		},
		{
			name: "prerelease only when no stable",
			in: []release{
				{TagName: "v0.2.0-rc.1", Prerelease: true, Assets: apk},
			},
			want: "v0.2.0-rc.1",
		},
		{
			name: "no v* apk",
			in: []release{
				{TagName: "apk-1", Assets: apk},
				{TagName: "v0.1.0", Assets: []asset{{Name: "notes.txt"}}},
			},
			err: ErrNotFound,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := pickLatestSemverRelease(tt.in)
			if tt.err != nil {
				if !errors.Is(err, tt.err) {
					t.Fatalf("err = %v, want %v", err, tt.err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.TagName != tt.want {
				t.Fatalf("tag = %q, want %q", got.TagName, tt.want)
			}
		})
	}
}

func TestParseSemverTag(t *testing.T) {
	if _, ok := parseSemverTag("apk-45"); ok {
		t.Fatal("apk-* must not parse as semver")
	}
	got, ok := parseSemverTag("v0.1.0")
	if !ok || got.major != 0 || got.minor != 1 || got.patch != 0 || got.pre != "" {
		t.Fatalf("v0.1.0 = %+v ok=%v", got, ok)
	}
	pre, ok := parseSemverTag("v1.2.3-rc.1")
	if !ok || pre.major != 1 || pre.minor != 2 || pre.patch != 3 || pre.pre != "rc.1" {
		t.Fatalf("v1.2.3-rc.1 = %+v ok=%v", pre, ok)
	}
	older, okOlder := parseSemverTag("v0.1.0")
	newer, okNewer := parseSemverTag("v0.2.0")
	if !okOlder || !okNewer || !older.less(newer) {
		t.Fatal("v0.1.0 should be less than v0.2.0")
	}
}

func TestPickAPKAsset(t *testing.T) {
	got, err := pickAPKAsset([]asset{
		{Name: "notes.txt", ID: 1},
		{Name: "openfamily-release.apk", ID: 2},
	})
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != 2 {
		t.Fatalf("picked %+v", got)
	}
	if _, err := pickAPKAsset([]asset{{Name: "notes.txt"}}); err == nil {
		t.Fatal("expected ErrNotFound")
	}
}

func TestParseRepo(t *testing.T) {
	owner, name, err := parseRepo("  TheTractorHacker/openfamily ")
	if err != nil || owner != "TheTractorHacker" || name != "openfamily" {
		t.Fatalf("parseRepo = %s/%s (%v)", owner, name, err)
	}
	if _, _, err := parseRepo("nopath"); err == nil {
		t.Fatal("expected error")
	}
}

func TestCacheFresh(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, cachedName)
	if cacheFresh(dir, dest, 1) {
		t.Fatal("missing file should not be fresh")
	}
	if err := os.WriteFile(dest, []byte("apk"), 0o644); err != nil {
		t.Fatal(err)
	}
	if cacheFresh(dir, dest, 1) {
		t.Fatal("missing meta should not be fresh")
	}
	if err := writeMeta(dir, cacheMeta{AssetID: 1}); err != nil {
		t.Fatal(err)
	}
	if !cacheFresh(dir, dest, 1) {
		t.Fatal("matching asset should be fresh")
	}
	if cacheFresh(dir, dest, 2) {
		t.Fatal("different asset should not be fresh")
	}
}

func TestNextLink(t *testing.T) {
	got := nextLink(`<https://api.github.com/repos/a/b/releases?page=2>; rel="next", <https://api.github.com/repos/a/b/releases?page=3>; rel="last"`)
	if got != "https://api.github.com/repos/a/b/releases?page=2" {
		t.Fatalf("next = %q", got)
	}
	if nextLink("") != "" {
		t.Fatal("empty header should have no next")
	}
}
