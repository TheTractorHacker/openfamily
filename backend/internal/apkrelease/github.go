// Package apkrelease fetches the Android APK from the latest user-facing
// semver GitHub Release (tag vMAJOR.MINOR.PATCH) and caches it on disk.
// CI also publishes tester APKs as apk-* tags; those are ignored here.
// The admin download endpoint syncs the v* asset into APK_DIR so the
// server never needs the Flutter toolchain or a git pull of a binary.
package apkrelease

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	defaultAPI      = "https://api.github.com"
	cachedName      = "openfamily-release.apk"
	metaName        = ".apk-release.json"
	userAgent       = "openfamily-apk-sync"
	metaTimeout     = 15 * time.Second
	fetchTimeout    = 5 * time.Minute
	releasesPerPage = 100
	maxReleasePages = 20
	maxReleaseBody  = 8 << 20
)

// ErrNotFound means GitHub has no published v* semver release with an APK
// asset. CI apk-* tags are not a fallback.
var ErrNotFound = errors.New("no APK on the latest v* GitHub Release")

// semverTagRE matches a leading-v semver tag such as v0.1.0 or v1.2.3-rc.1.
var semverTagRE = regexp.MustCompile(`^v(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$`)

// Options configure a sync against GitHub Releases.
type Options struct {
	// Repo is "owner/name".
	Repo string
	// Token is an optional GitHub PAT for private forks.
	Token string
	// DestDir is APK_DIR, where the cached APK is stored.
	DestDir string
	// API is the GitHub API origin. Empty uses https://api.github.com.
	API string
	// Client is optional; empty uses a client that strips Authorization on
	// cross-host redirects (GitHub asset downloads 302 to a CDN).
	Client *http.Client
}

type release struct {
	TagName     string    `json:"tag_name"`
	Name        string    `json:"name"`
	Body        string    `json:"body"`
	HTMLURL     string    `json:"html_url"`
	PublishedAt time.Time `json:"published_at"`
	Draft       bool      `json:"draft"`
	Prerelease  bool      `json:"prerelease"`
	Assets      []asset   `json:"assets"`
}

type semver struct {
	major, minor, patch int
	pre                 string
}

type asset struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
	URL  string `json:"url"`
	Size int64  `json:"size"`
}

type cacheMeta struct {
	AssetID int64  `json:"asset_id"`
	TagName string `json:"tag_name"`
	Name    string `json:"name"`
}

// ReleaseInfo is the public metadata the admin panel shows for the latest APK
// release. It deliberately omits the API asset URL: downloads continue through
// the authenticated server endpoint and its on-disk cache.
type ReleaseInfo struct {
	TagName     string    `json:"tag_name"`
	Name        string    `json:"name,omitempty"`
	Body        string    `json:"body,omitempty"`
	HTMLURL     string    `json:"html_url,omitempty"`
	PublishedAt time.Time `json:"published_at,omitempty"`
	AssetName   string    `json:"asset_name"`
	AssetSize   int64     `json:"asset_size"`
}

// LatestInfo returns metadata for the APK attached to the repository's latest
// published v* semver GitHub Release without downloading the asset. It does
// not use GitHub's /releases/latest endpoint, which may point at an apk-*
// CI tag.
func LatestInfo(ctx context.Context, opts Options) (ReleaseInfo, error) {
	owner, name, err := parseRepo(opts.Repo)
	if err != nil {
		return ReleaseInfo{}, err
	}
	client := opts.Client
	if client == nil {
		client = defaultClient()
	}
	api := strings.TrimRight(opts.API, "/")
	if api == "" {
		api = defaultAPI
	}

	metaCtx, cancel := context.WithTimeout(ctx, metaTimeout)
	defer cancel()
	rel, err := fetchLatest(metaCtx, client, api, owner, name, opts.Token)
	if err != nil {
		return ReleaseInfo{}, err
	}
	apk, err := pickAPKAsset(rel.Assets)
	if err != nil {
		return ReleaseInfo{}, err
	}
	return ReleaseInfo{
		TagName:     rel.TagName,
		Name:        rel.Name,
		Body:        rel.Body,
		HTMLURL:     rel.HTMLURL,
		PublishedAt: rel.PublishedAt,
		AssetName:   apk.Name,
		AssetSize:   apk.Size,
	}, nil
}

// Sync ensures DestDir contains the APK from the repo's latest published v*
// semver GitHub Release. If the cached file already matches that asset, it is
// reused. The returned path is the local APK. CI apk-* tags are ignored.
func Sync(ctx context.Context, opts Options) (string, error) {
	if opts.DestDir == "" {
		return "", errors.New("APK_DIR is not configured")
	}
	owner, name, err := parseRepo(opts.Repo)
	if err != nil {
		return "", err
	}
	client := opts.Client
	if client == nil {
		client = defaultClient()
	}
	api := strings.TrimRight(opts.API, "/")
	if api == "" {
		api = defaultAPI
	}

	metaCtx, cancel := context.WithTimeout(ctx, metaTimeout)
	defer cancel()
	rel, err := fetchLatest(metaCtx, client, api, owner, name, opts.Token)
	if err != nil {
		return "", err
	}
	asset, err := pickAPKAsset(rel.Assets)
	if err != nil {
		return "", err
	}

	if err := os.MkdirAll(opts.DestDir, 0o755); err != nil {
		return "", fmt.Errorf("create APK_DIR: %w", err)
	}
	dest := filepath.Join(opts.DestDir, cachedName)
	if cacheFresh(opts.DestDir, dest, asset.ID) {
		return dest, nil
	}

	dlCtx, cancelDL := context.WithTimeout(ctx, fetchTimeout)
	defer cancelDL()
	if err := downloadAsset(dlCtx, client, asset.URL, opts.Token, dest); err != nil {
		return "", err
	}
	meta := cacheMeta{AssetID: asset.ID, TagName: rel.TagName, Name: asset.Name}
	if metaErr := writeMeta(opts.DestDir, meta); metaErr != nil {
		// The APK is usable even if the sidecar fails; the next sync will
		// re-download.
		return dest, nil
	}
	return dest, nil
}

func parseRepo(repo string) (owner, name string, err error) {
	repo = strings.TrimSpace(repo)
	parts := strings.Split(repo, "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", errors.New("APK_GITHUB_REPO must be owner/name")
	}
	return parts[0], parts[1], nil
}

// pickAPKAsset chooses the APK that /app.apk and the admin download serve.
// A release may carry several .apk files (a combined build plus per-ABI
// builds, see docs/developers/performance-low-memory.md). The server cannot
// know which phone will download, so it prefers, in order: the combined APK
// (no ABI in its name; runs on 32-bit and 64-bit ARM), then arm64-v8a, then
// armeabi-v7a, then any other .apk. Ties keep the order GitHub lists them.
func pickAPKAsset(assets []asset) (asset, error) {
	best, bestRank := asset{}, 99
	for _, a := range assets {
		if !strings.EqualFold(filepath.Ext(a.Name), ".apk") {
			continue
		}
		if r := apkRank(a.Name); r < bestRank {
			best, bestRank = a, r
		}
	}
	if bestRank == 99 {
		return asset{}, ErrNotFound
	}
	return best, nil
}

func apkRank(name string) int {
	n := strings.ToLower(name)
	switch {
	case strings.Contains(n, "arm64-v8a"):
		return 1
	case strings.Contains(n, "armeabi-v7a"):
		return 2
	case strings.Contains(n, "x86"):
		return 3
	}
	return 0
}

func cacheFresh(dir, dest string, assetID int64) bool {
	if _, err := os.Stat(dest); err != nil {
		return false
	}
	meta, err := readMeta(dir)
	if err != nil {
		return false
	}
	return meta.AssetID == assetID
}

func fetchLatest(ctx context.Context, client *http.Client, api, owner, name, token string) (*release, error) {
	rels, err := listReleases(ctx, client, api, owner, name, token)
	if err != nil {
		return nil, err
	}
	rel, err := pickLatestSemverRelease(rels)
	if err != nil {
		return nil, err
	}
	return rel, nil
}

func listReleases(ctx context.Context, client *http.Client, api, owner, name, token string) ([]release, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/releases?per_page=%d", api, owner, name, releasesPerPage)
	var all []release
	for page := 0; page < maxReleasePages; page++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		setGitHubHeaders(req, token, "application/vnd.github+json")

		res, err := client.Do(req)
		if err != nil {
			return nil, fmt.Errorf("github releases: %w", err)
		}
		body, _ := io.ReadAll(io.LimitReader(res.Body, maxReleaseBody))
		res.Body.Close()
		if res.StatusCode == http.StatusNotFound {
			return nil, fmt.Errorf("%w: GitHub returned 404", ErrNotFound)
		}
		if res.StatusCode == http.StatusUnauthorized || res.StatusCode == http.StatusForbidden {
			return nil, fmt.Errorf("GitHub API request was rejected (%d)", res.StatusCode)
		}
		if res.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("github releases: HTTP %d", res.StatusCode)
		}
		var batch []release
		if err := json.Unmarshal(body, &batch); err != nil {
			return nil, fmt.Errorf("decode github releases: %w", err)
		}
		all = append(all, batch...)
		next := nextLink(res.Header.Get("Link"))
		if next == "" {
			break
		}
		url = next
	}
	return all, nil
}

func nextLink(header string) string {
	for _, part := range strings.Split(header, ",") {
		part = strings.TrimSpace(part)
		if !strings.Contains(part, `rel="next"`) && !strings.Contains(part, "rel=next") {
			continue
		}
		start := strings.Index(part, "<")
		end := strings.Index(part, ">")
		if start >= 0 && end > start {
			return part[start+1 : end]
		}
	}
	return ""
}

func parseSemverTag(tag string) (semver, bool) {
	m := semverTagRE.FindStringSubmatch(strings.TrimSpace(tag))
	if m == nil {
		return semver{}, false
	}
	major, err1 := strconv.Atoi(m[1])
	minor, err2 := strconv.Atoi(m[2])
	patch, err3 := strconv.Atoi(m[3])
	if err1 != nil || err2 != nil || err3 != nil {
		return semver{}, false
	}
	return semver{major: major, minor: minor, patch: patch, pre: m[4]}, true
}

func (a semver) less(b semver) bool {
	if a.major != b.major {
		return a.major < b.major
	}
	if a.minor != b.minor {
		return a.minor < b.minor
	}
	if a.patch != b.patch {
		return a.patch < b.patch
	}
	if a.pre == b.pre {
		return false
	}
	if a.pre == "" {
		return false
	}
	if b.pre == "" {
		return true
	}
	return a.pre < b.pre
}

func (v semver) prerelease() bool {
	return v.pre != ""
}

// pickLatestSemverRelease selects the highest published v* semver release that
// has an APK asset. Drafts and apk-* CI tags are ignored. A GitHub or semver
// prerelease is used only when no stable v* APK exists.
func pickLatestSemverRelease(rels []release) (*release, error) {
	var bestStable, bestPre *release
	var bestStableVer, bestPreVer semver
	for i := range rels {
		rel := &rels[i]
		if rel.Draft {
			continue
		}
		ver, ok := parseSemverTag(rel.TagName)
		if !ok {
			continue
		}
		if _, err := pickAPKAsset(rel.Assets); err != nil {
			continue
		}
		if rel.Prerelease || ver.prerelease() {
			if bestPre == nil || bestPreVer.less(ver) {
				bestPre = rel
				bestPreVer = ver
			}
			continue
		}
		if bestStable == nil || bestStableVer.less(ver) {
			bestStable = rel
			bestStableVer = ver
		}
	}
	if bestStable != nil {
		return bestStable, nil
	}
	if bestPre != nil {
		return bestPre, nil
	}
	return nil, ErrNotFound
}

func downloadAsset(ctx context.Context, client *http.Client, assetURL, token, dest string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, assetURL, nil)
	if err != nil {
		return err
	}
	setGitHubHeaders(req, token, "application/octet-stream")

	res, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("download github asset: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("download github asset: HTTP %d", res.StatusCode)
	}
	return writeAtomic(dest, res.Body)
}

func setGitHubHeaders(req *http.Request, token, accept string) {
	req.Header.Set("Accept", accept)
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
}

func defaultClient() *http.Client {
	return &http.Client{
		Timeout: fetchTimeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("too many redirects")
			}
			// Asset downloads 302 onto a CDN. Do not forward the PAT.
			if len(via) > 0 && req.URL.Host != via[0].URL.Host {
				req.Header.Del("Authorization")
			}
			return nil
		},
	}
}

func metaPath(dir string) string {
	return filepath.Join(dir, metaName)
}

func readMeta(dir string) (cacheMeta, error) {
	var meta cacheMeta
	data, err := os.ReadFile(metaPath(dir))
	if err != nil {
		return meta, err
	}
	if err := json.Unmarshal(data, &meta); err != nil {
		return meta, err
	}
	return meta, nil
}

func writeMeta(dir string, meta cacheMeta) error {
	data, err := json.Marshal(meta)
	if err != nil {
		return err
	}
	tmp := metaPath(dir) + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, metaPath(dir))
}

func writeAtomic(dest string, r io.Reader) error {
	dir := filepath.Dir(dest)
	tmp, err := os.CreateTemp(dir, ".apk-partial-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := io.Copy(tmp, r); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, dest)
}
