package apkrelease

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Asset kinds shown on the admin Builds page.
const (
	KindAndroidAPK = "android_apk"
	KindAndroidAAB = "android_aab"
	KindWearAPK    = "wear_apk"
	KindIOSIPA     = "ios_ipa"
	KindSBOM       = "sbom"
	KindChecksums  = "checksums"
	KindOther      = "other"
)

var (
	abiNames   = []string{"arm64-v8a", "armeabi-v7a", "x86_64", "x86"}
	versionRE  = regexp.MustCompile(`(\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)`)
	sha256HexE = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)
)

// Classify says what a release asset is from its file name alone, so it works
// for both orbitly-<ver>.* and the older openfamily-<ver>.* naming.
func Classify(name string) string {
	l := strings.ToLower(name)
	ext := filepath.Ext(l)
	switch {
	case ext == ".apk":
		if strings.Contains(l, "wear") {
			return KindWearAPK
		}
		return KindAndroidAPK
	case ext == ".aab":
		return KindAndroidAAB
	case ext == ".ipa":
		return KindIOSIPA
	case strings.HasPrefix(l, "sha256sums"):
		return KindChecksums
	case strings.Contains(l, "sbom") || strings.Contains(l, "spdx") || strings.Contains(l, "cyclonedx") || strings.HasSuffix(l, ".cdx.json"):
		return KindSBOM
	}
	return KindOther
}

// ParseABI returns "arm64-v8a", "armeabi-v7a", "x86_64", "x86" or "universal"
// (no ABI in the name, or the word universal).
func ParseABI(name string) string {
	l := strings.ToLower(strings.ReplaceAll(name, "_", "-"))
	// x86_64 was normalised to x86-64; accept both spellings.
	if strings.Contains(l, "x86-64") {
		return "x86_64"
	}
	for _, a := range abiNames {
		if strings.Contains(l, a) {
			return a
		}
	}
	if strings.Contains(l, "arm64") {
		return "arm64-v8a"
	}
	return "universal"
}

func abiRank(abi string) int {
	switch abi {
	case "universal":
		return 0
	case "arm64-v8a":
		return 1
	case "armeabi-v7a":
		return 2
	case "x86_64":
		return 3
	case "x86":
		return 4
	}
	return 5
}

// ParseVersion extracts a semver such as 0.24.1 from a file name ("" if none).
func ParseVersion(name string) string {
	v := versionRE.FindString(name)
	for _, ext := range []string{".apk", ".aab", ".ipa", ".json", ".sha256", ".txt"} {
		v = strings.TrimSuffix(v, ext)
	}
	return v
}

// AssetInfo is one downloadable file of a release.
type AssetInfo struct {
	Name        string    `json:"name"`
	Kind        string    `json:"kind"`
	ABI         string    `json:"abi,omitempty"`
	Version     string    `json:"version,omitempty"`
	Size        int64     `json:"size"`
	SHA256      string    `json:"sha256,omitempty"`
	DownloadURL string    `json:"download_url,omitempty"`
	UpdatedAt   time.Time `json:"updated_at,omitempty"`
}

// ReleaseSummary is one release with its classified assets.
type ReleaseSummary struct {
	TagName     string      `json:"tag_name"`
	Name        string      `json:"name,omitempty"`
	HTMLURL     string      `json:"html_url,omitempty"`
	PublishedAt time.Time   `json:"published_at,omitempty"`
	Prerelease  bool        `json:"prerelease,omitempty"`
	Assets      []AssetInfo `json:"assets"`
}

func normalizeSHA(d string) string {
	d = strings.TrimSpace(d)
	d = strings.TrimPrefix(strings.ToLower(d), "sha256:")
	if sha256HexE.MatchString(d) {
		return d
	}
	return ""
}

// ParseChecksums reads a sha256sum-style file ("<hex>  <name>" per line).
func ParseChecksums(r io.Reader) map[string]string {
	out := map[string]string{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 2 {
			continue
		}
		if h := normalizeSHA(f[0]); h != "" {
			out[strings.TrimPrefix(f[len(f)-1], "*")] = h
		}
	}
	return out
}

func summarize(rel release, sums map[string]string) ReleaseSummary {
	rs := ReleaseSummary{TagName: rel.TagName, Name: rel.Name, HTMLURL: rel.HTMLURL, PublishedAt: rel.PublishedAt,
		Prerelease: rel.Prerelease, Assets: []AssetInfo{}}
	tagVer := strings.TrimPrefix(rel.TagName, "v")
	for _, a := range rel.Assets {
		ai := AssetInfo{Name: a.Name, Kind: Classify(a.Name), Size: a.Size, DownloadURL: a.BrowserDownloadURL, UpdatedAt: a.UpdatedAt}
		if ai.Kind == KindAndroidAPK || ai.Kind == KindWearAPK {
			ai.ABI = ParseABI(a.Name)
		}
		if ai.Kind != KindChecksums && ai.Kind != KindSBOM && ai.Kind != KindOther {
			if ai.Version = ParseVersion(a.Name); ai.Version == "" {
				ai.Version = tagVer
			}
		}
		ai.SHA256 = normalizeSHA(a.Digest)
		if ai.SHA256 == "" {
			ai.SHA256 = sums[a.Name]
		}
		rs.Assets = append(rs.Assets, ai)
	}
	sort.SliceStable(rs.Assets, func(i, j int) bool {
		if abiRank(rs.Assets[i].ABI) != abiRank(rs.Assets[j].ABI) && rs.Assets[i].Kind == rs.Assets[j].Kind {
			return abiRank(rs.Assets[i].ABI) < abiRank(rs.Assets[j].ABI)
		}
		return false
	})
	return rs
}

// fetchChecksums downloads the SHA256SUMS asset of a release (best effort).
func fetchChecksums(ctx context.Context, client *http.Client, token string, rel release) map[string]string {
	for _, a := range rel.Assets {
		if Classify(a.Name) != KindChecksums || a.URL == "" {
			continue
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.URL, nil)
		if err != nil {
			return nil
		}
		setGitHubHeaders(req, token, "application/octet-stream")
		res, err := client.Do(req)
		if err != nil {
			return nil
		}
		defer res.Body.Close()
		if res.StatusCode != http.StatusOK {
			return nil
		}
		return ParseChecksums(io.LimitReader(res.Body, 1<<20))
	}
	return nil
}

// ListReleases returns the newest n published v* semver releases (newest
// first), including ones without an APK, with classified assets and checksums.
func ListReleases(ctx context.Context, opts Options, n int) ([]ReleaseSummary, error) {
	owner, name, err := parseRepo(opts.Repo)
	if err != nil {
		return nil, err
	}
	client := opts.Client
	if client == nil {
		client = defaultClient()
	}
	api := strings.TrimRight(opts.API, "/")
	if api == "" {
		api = defaultAPI
	}
	if n < 1 {
		n = 1
	}
	mctx, cancel := context.WithTimeout(ctx, metaTimeout*2)
	defer cancel()
	rels, err := listReleasesPaged(mctx, client, api, owner, name, opts.Token, 50, 2)
	if err != nil {
		return nil, err
	}
	type ver struct {
		r release
		v semver
	}
	var keep []ver
	for _, r := range rels {
		if r.Draft {
			continue
		}
		if v, ok := parseSemverTag(r.TagName); ok {
			keep = append(keep, ver{r, v})
		}
	}
	sort.SliceStable(keep, func(i, j int) bool { return keep[j].v.less(keep[i].v) })
	if len(keep) > n {
		keep = keep[:n]
	}
	if len(keep) == 0 {
		return nil, ErrNotFound
	}
	out := make([]ReleaseSummary, 0, len(keep))
	for _, k := range keep {
		out = append(out, summarize(k.r, fetchChecksums(mctx, client, opts.Token, k.r)))
	}
	return out, nil
}

// Lister caches ListReleases so the admin page does not spend GitHub's
// unauthenticated rate limit (60/hour) on every visit. When GitHub fails
// (offline, rate limited), the previous result is served marked stale.
type Lister struct {
	TTL time.Duration
	Now func() time.Time

	mu   sync.Mutex
	at   time.Time
	n    int
	data []ReleaseSummary
}

// Result is what Lister.Get returns.
type Result struct {
	Releases  []ReleaseSummary
	FetchedAt time.Time
	// Stale is true when Err is set and Releases is the last good copy.
	Stale bool
	Err   error
}

func (l *Lister) now() time.Time {
	if l.Now != nil {
		return l.Now()
	}
	return time.Now()
}

// Get returns cached releases, refreshing when older than TTL (default 5 min)
// or when force is set. On failure with no earlier copy, Releases is empty.
func (l *Lister) Get(ctx context.Context, opts Options, n int, force bool) Result {
	l.mu.Lock()
	defer l.mu.Unlock()
	ttl := l.TTL
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	if l.data != nil && l.n >= n && !force && l.now().Sub(l.at) < ttl {
		return Result{Releases: trim(l.data, n), FetchedAt: l.at}
	}
	rels, err := ListReleases(ctx, opts, n)
	if err != nil {
		if l.data != nil {
			return Result{Releases: trim(l.data, n), FetchedAt: l.at, Stale: true, Err: friendlyErr(err)}
		}
		return Result{Err: friendlyErr(err)}
	}
	l.data, l.at, l.n = rels, l.now(), n
	return Result{Releases: rels, FetchedAt: l.at}
}

func trim(r []ReleaseSummary, n int) []ReleaseSummary {
	if len(r) > n {
		return r[:n]
	}
	return r
}

func friendlyErr(err error) error {
	msg := err.Error()
	switch {
	case strings.Contains(msg, "(403)") || strings.Contains(msg, "HTTP 403") || strings.Contains(msg, "(429)"):
		return fmt.Errorf("GitHub refused the request, probably its hourly rate limit. Try again later or set APK_GITHUB_TOKEN: %w", err)
	case strings.Contains(msg, "github releases:") && !strings.Contains(msg, "HTTP"):
		return fmt.Errorf("Could not reach GitHub (is the server offline?): %w", err)
	}
	return err
}
