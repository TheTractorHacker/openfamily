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
	"sort"
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
	return SyncKind(ctx, opts, ".apk")
}

// SyncIPA is Sync for the unsigned iOS .ipa attached to the same release
// (orbitly-<version>-unsigned.ipa; older openfamily-* names work too).
func SyncIPA(ctx context.Context, opts Options) (string, error) {
	return SyncKind(ctx, opts, ".ipa")
}

// SyncKind caches the asset with file extension ext (".apk" or ".ipa") from
// the latest published v* release into DestDir and returns its path.
func SyncKind(ctx context.Context, opts Options, ext string) (string, error) {
	cachedName, metaName := cacheNames(ext)
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
	asset, err := pickAsset(rel.Assets, ext)
	if err != nil {
		return "", err
	}

	if err := os.MkdirAll(opts.DestDir, 0o755); err != nil {
		return "", fmt.Errorf("create APK_DIR: %w", err)
	}
	dest := filepath.Join(opts.DestDir, cachedName)
	if cacheFresh(opts.DestDir, metaName, dest, asset.ID) {
		return dest, nil
	}

	dlCtx, cancelDL := context.WithTimeout(ctx, fetchTimeout)
	defer cancelDL()
	if err := downloadAsset(dlCtx, client, asset.URL, opts.Token, dest); err != nil {
		return "", err
	}
	meta := cacheMeta{AssetID: asset.ID, TagName: rel.TagName, Name: asset.Name}
	if metaErr := writeMeta(opts.DestDir, metaName, meta); metaErr != nil {
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

func pickAPKAsset(assets []asset) (asset, error) { return pickAsset(assets, ".apk") }

func pickAsset(assets []asset, ext string) (asset, error) {
	for _, a := range assets {
		if strings.EqualFold(filepath.Ext(a.Name), ext) {
			return a, nil
		}
	}
	return asset{}, ErrNotFound
}

// cacheNames returns the cached file name and sidecar name for an extension.
// The APK keeps its historical names so existing caches stay valid.
func cacheNames(ext string) (cached, meta string) {
	if ext == ".apk" {
		return cachedName, metaName
	}
	e := strings.TrimPrefix(ext, ".")
	return "openfamily-release." + e, "." + e + "-release.json"
}

func cacheFresh(dir, metaFile, dest string, assetID int64) bool {
	if _, err := os.Stat(dest); err != nil {
		return false
	}
	meta, err := readMeta(dir, metaFile)
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

func metaPath(dir, file string) string {
	return filepath.Join(dir, file)
}

func readMeta(dir, file string) (cacheMeta, error) {
	var meta cacheMeta
	data, err := os.ReadFile(metaPath(dir, file))
	if err != nil {
		return meta, err
	}
	if err := json.Unmarshal(data, &meta); err != nil {
		return meta, err
	}
	return meta, nil
}

func writeMeta(dir, file string, meta cacheMeta) error {
	data, err := json.Marshal(meta)
	if err != nil {
		return err
	}
	tmp := metaPath(dir, file) + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, metaPath(dir, file))
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

// AssetInfo describes one downloadable file of a release.
type AssetInfo struct {
	Kind   string `json:"kind"` // apk, aab, ipa
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256,omitempty"`
}

// ReleaseSummary is one release in the "older versions" list.
type ReleaseSummary struct {
	TagName     string      `json:"tag_name"`
	HTMLURL     string      `json:"html_url,omitempty"`
	PublishedAt time.Time   `json:"published_at,omitempty"`
	Assets      []AssetInfo `json:"assets"`
}

// Overview is what the admin Builds page shows: the latest published v*
// release (with every installable file and its checksum) and older ones.
type Overview struct {
	Latest ReleaseInfo      `json:"latest"`
	Assets []AssetInfo      `json:"assets"`
	Older  []ReleaseSummary `json:"older"`
}

func assetKind(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".apk":
		return "apk"
	case ".aab":
		return "aab"
	case ".ipa":
		return "ipa"
	}
	return ""
}

// parseChecksums reads "<hex>  <file>" lines (sha256sum / shasum output) and
// bare "<hex>" files named after the asset.
func parseChecksums(text, onlyFile string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		f := strings.Fields(line)
		if len(f) == 0 || len(f[0]) != 64 {
			continue
		}
		if len(f) >= 2 {
			out[strings.TrimPrefix(f[1], "*")] = strings.ToLower(f[0])
		} else if onlyFile != "" {
			out[onlyFile] = strings.ToLower(f[0])
		}
	}
	return out
}

func assetInfos(ctx context.Context, client *http.Client, token string, rel *release) []AssetInfo {
	sums := map[string]string{}
	for _, a := range rel.Assets {
		n := strings.ToLower(a.Name)
		if a.Size > 1<<16 || !(strings.HasSuffix(n, ".sha256") || strings.HasSuffix(n, "sums.txt")) {
			continue
		}
		only := ""
		if strings.HasSuffix(n, ".sha256") {
			only = strings.TrimSuffix(a.Name, filepath.Ext(a.Name))
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.URL, nil)
		if err != nil {
			continue
		}
		setGitHubHeaders(req, token, "application/octet-stream")
		res, err := client.Do(req)
		if err != nil {
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<16))
		res.Body.Close()
		if res.StatusCode != http.StatusOK {
			continue
		}
		for k, v := range parseChecksums(string(body), only) {
			sums[k] = v
		}
	}
	var out []AssetInfo
	for _, a := range rel.Assets {
		if k := assetKind(a.Name); k != "" {
			out = append(out, AssetInfo{Kind: k, Name: a.Name, Size: a.Size, SHA256: sums[a.Name]})
		}
	}
	return out
}

// ListOverview returns the latest v* release with all installable assets and
// up to maxOlder older v* releases (newest first).
func ListOverview(ctx context.Context, opts Options, maxOlder int) (Overview, error) {
	owner, name, err := parseRepo(opts.Repo)
	if err != nil {
		return Overview{}, err
	}
	client := opts.Client
	if client == nil {
		client = defaultClient()
	}
	api := strings.TrimRight(opts.API, "/")
	if api == "" {
		api = defaultAPI
	}
	ctx, cancel := context.WithTimeout(ctx, metaTimeout)
	defer cancel()
	rels, err := listReleases(ctx, client, api, owner, name, opts.Token)
	if err != nil {
		return Overview{}, err
	}
	latest, err := pickLatestSemverRelease(rels)
	if err != nil {
		return Overview{}, err
	}
	ov := Overview{Latest: ReleaseInfo{TagName: latest.TagName, Name: latest.Name, Body: latest.Body,
		HTMLURL: latest.HTMLURL, PublishedAt: latest.PublishedAt}}
	ov.Assets = assetInfos(ctx, client, opts.Token, latest)
	for _, a := range ov.Assets {
		if a.Kind == "apk" {
			ov.Latest.AssetName, ov.Latest.AssetSize = a.Name, a.Size
			break
		}
	}
	older := []release{}
	for _, r := range rels {
		sv, ok := parseSemverTag(r.TagName)
		if !ok || r.Draft || r.TagName == latest.TagName || sv.prerelease() {
			continue
		}
		older = append(older, r)
	}
	sort.SliceStable(older, func(i, j int) bool { return older[i].PublishedAt.After(older[j].PublishedAt) })
	for _, r := range older {
		if len(ov.Older) >= maxOlder {
			break
		}
		sum := ReleaseSummary{TagName: r.TagName, HTMLURL: r.HTMLURL, PublishedAt: r.PublishedAt, Assets: []AssetInfo{}}
		for _, a := range r.Assets {
			if k := assetKind(a.Name); k != "" {
				sum.Assets = append(sum.Assets, AssetInfo{Kind: k, Name: a.Name, Size: a.Size})
			}
		}
		ov.Older = append(ov.Older, sum)
	}
	return ov, nil
}
