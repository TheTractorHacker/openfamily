// Package compat implements the server's app-compatibility policy
// (docs/api-compat.md): which released app versions the API must keep
// working for, how a client's self-reported version is classified, and which
// features need which minimum app version.
//
// The package is pure (no database, no HTTP) so it is cheap to test and can be
// used from middleware, handlers and the admin API alike.
package compat

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// WindowSize is how many of the latest released minor lines the server keeps
// compatible. When a new minor ships, the oldest one drops out of the window.
const WindowSize = 5

// RecommendLag is how many minor lines behind the latest release an app may be
// before it is told an update is recommended (it still works).
const RecommendLag = 2

// Releases lists the minor lines that have shipped, oldest first, as "x.y.0".
// Add the new line here in the same commit that tags a release; the window
// (and therefore MinSupported) follows automatically. TestReleasesSorted keeps
// the list ordered.
var Releases = []string{
	"0.2.0", "0.3.0", "0.4.0", "0.5.0", "0.6.0", "0.7.0", "0.8.0", "0.9.0",
	"0.10.0", "0.11.0", "0.12.0", "0.13.0", "0.14.0", "0.15.0", "0.16.0",
	"0.17.0", "0.18.0", "0.19.0", "0.20.0", "0.21.0", "0.22.0", "0.23.0", "0.24.0", "0.25.0", "0.26.0",
}

// Features maps a server feature to the first app version that understands it.
// An older app can use the server but not the feature; the API tells it so
// (min_app_version on a circle) instead of showing an empty state.
var Features = map[string]string{
	"private_circles":     "0.15.0", // end-to-end encrypted circles (read side)
	"private_channel":     "0.16.0", // sealed location channel
	"trusted_server_mode": "0.18.0", // server as an approved E2EE member
	"processing_lanes":    "0.22.0", // per-member privacy lanes: key-log actions 10/11, server key line
	"chat_e2ee":           "0.23.0", // chat sealed phone to phone in Private circles
	"wire_v2":             "0.25.0", // API wire efficiency: bootstrap, ETag, delta lists, compact views, history simplify
}

// Version is a parsed x.y.z app version. Pre-release and build suffixes are
// ignored: 0.20.1-rc1+45 compares as 0.20.1.
type Version struct{ Major, Minor, Patch int }

// Parse reads "0.20.1", "v0.20.1", "0.20.1+45" or "0.20.1-rc1". It returns
// false for anything that is not at least "major.minor".
func Parse(s string) (Version, bool) {
	s = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(s), "v"))
	if i := strings.IndexAny(s, "+-"); i >= 0 {
		s = s[:i]
	}
	parts := strings.Split(s, ".")
	if len(parts) < 2 || len(parts) > 3 {
		return Version{}, false
	}
	var n [3]int
	for i, p := range parts {
		if p == "" || len(p) > 4 {
			return Version{}, false
		}
		v, err := strconv.Atoi(p)
		if err != nil || v < 0 {
			return Version{}, false
		}
		n[i] = v
	}
	return Version{n[0], n[1], n[2]}, true
}

// MustParse is Parse for constants; it panics on a bad literal.
func MustParse(s string) Version {
	v, ok := Parse(s)
	if !ok {
		panic("compat: bad version " + s)
	}
	return v
}

func (v Version) String() string { return fmt.Sprintf("%d.%d.%d", v.Major, v.Minor, v.Patch) }

// Compare returns -1, 0 or 1.
func (v Version) Compare(o Version) int {
	switch {
	case v.Major != o.Major:
		return sign(v.Major - o.Major)
	case v.Minor != o.Minor:
		return sign(v.Minor - o.Minor)
	default:
		return sign(v.Patch - o.Patch)
	}
}

// Less reports v < o.
func (v Version) Less(o Version) bool { return v.Compare(o) < 0 }

func sign(n int) int {
	if n < 0 {
		return -1
	}
	if n > 0 {
		return 1
	}
	return 0
}

// Status is how the server classifies a client.
type Status string

const (
	// StatusUnknown: the client did not report a version (apps older than the
	// header, scripts). Never blocked and never have their responses altered.
	StatusUnknown Status = "unknown"
	// StatusOK: inside the window and recent.
	StatusOK Status = "ok"
	// StatusRecommended: works, but RecommendLag or more minor lines behind.
	StatusRecommended Status = "recommended"
	// StatusRequired: older than the window's minimum.
	StatusRequired Status = "required"
)

// Policy is the effective compatibility policy.
type Policy struct {
	Min    Version  // oldest supported app version
	Latest Version  // newest known release
	Window []string // minor lines inside the window, oldest first
	// Source says where Min came from: "window", "env" or "admin".
	Source string
}

// Compute builds the policy. env is MIN_SUPPORTED_APP_VERSION and override is
// the admin setting; either may be empty or unparsable (ignored). The admin
// override wins over env, which wins over the derived rolling window. An
// override can only be lower than or equal to nothing in particular: the
// operator may widen or narrow the window freely.
func Compute(env, override string) Policy {
	rel := parsedReleases()
	p := Policy{Source: "window"}
	if len(rel) > 0 {
		p.Latest = rel[len(rel)-1]
		start := len(rel) - WindowSize
		if start < 0 {
			start = 0
		}
		p.Min = rel[start]
		for _, v := range rel[start:] {
			p.Window = append(p.Window, fmt.Sprintf("%d.%d", v.Major, v.Minor))
		}
	}
	if v, ok := Parse(env); ok {
		p.Min, p.Source = v, "env"
	}
	if v, ok := Parse(override); ok {
		p.Min, p.Source = v, "admin"
	}
	if p.Latest.Less(p.Min) { // a Min above every release makes no sense
		p.Latest = p.Min
	}
	return p
}

func parsedReleases() []Version {
	out := make([]Version, 0, len(Releases))
	for _, s := range Releases {
		out = append(out, MustParse(s))
	}
	return out
}

// Classify returns the status for a client that reported v (ok=false means it
// reported nothing parsable).
func (p Policy) Classify(v Version, ok bool) Status {
	if !ok {
		return StatusUnknown
	}
	if v.Less(p.Min) {
		return StatusRequired
	}
	if p.Latest.Major == v.Major && p.Latest.Minor-v.Minor >= RecommendLag || p.Latest.Major > v.Major {
		return StatusRecommended
	}
	return StatusOK
}

// Supports reports whether a client at v can use the named feature. A client
// with an unknown version is assumed capable: we never degrade what we cannot
// identify.
func Supports(feature string, v Version, known bool) bool {
	if !known {
		return true
	}
	min, ok := Features[feature]
	if !ok {
		return true
	}
	return !v.Less(MustParse(min))
}

// Info is the machine-readable compatibility document returned by GET /compat,
// embedded in GET /config and mirrored in the X-OpenFamily-* response headers.
type Info struct {
	Status              Status `json:"status"`
	UpgradeRequired     bool   `json:"upgrade_required"`
	UpgradeRecommended  bool   `json:"upgrade_recommended"`
	MinSupportedVersion string `json:"min_supported_version"`
	LatestVersion       string `json:"latest_version"`
	ClientVersion       string `json:"client_version,omitempty"`
	Message             string `json:"message,omitempty"`
	// Window lists the supported minor lines ("0.18" ... "0.22"), oldest first.
	Window []string `json:"window,omitempty"`
}

// Describe builds the Info for a client.
func (p Policy) Describe(v Version, ok bool) Info {
	st := p.Classify(v, ok)
	in := Info{
		Status:              st,
		UpgradeRequired:     st == StatusRequired,
		UpgradeRecommended:  st == StatusRecommended,
		MinSupportedVersion: p.Min.String(),
		LatestVersion:       p.Latest.String(),
		Window:              p.Window,
	}
	if ok {
		in.ClientVersion = v.String()
	}
	switch st {
	case StatusRequired:
		in.Message = "This version of Orbitly is no longer supported by the server. Update the app to keep seeing locations."
	case StatusRecommended:
		in.Message = "A newer version of Orbitly is available."
	}
	return in
}

// Experience says, in plain words, what a person running a client with this
// status sees. enforce is the operator's "refuse uploads from unsupported apps"
// switch. The admin "App versions" page shows this text next to each person.
func Experience(st Status, enforce bool) string {
	switch st {
	case StatusRequired:
		t := "Sees an \"Update required\" banner. Most things still load, but circles that need a newer app show \"update the app to open this private circle\" and the server no longer promises that everything works."
		if enforce {
			t += " Location uploads from this app are refused (HTTP 426) until it is updated, so this person stops appearing on the map."
		} else {
			t += " Location uploads are still accepted (enforcement is off)."
		}
		return t
	case StatusRecommended:
		return "Still works fully. Sees a small dismissible \"A newer version is available\" note."
	case StatusOK:
		return "Works fully. Nothing to do."
	default:
		return "The app did not report a version (an old app or a script). It is never blocked and never shown a banner."
	}
}

// MissingFeatures lists the server features a client at v cannot use yet,
// sorted by name, as plain-word labels.
func MissingFeatures(v Version) []string {
	labels := map[string]string{
		"private_circles":     "private (end-to-end encrypted) circles",
		"private_channel":     "the sealed location channel",
		"trusted_server_mode": "server-assisted private circles",
		"processing_lanes":    "per-member privacy lanes",
	}
	var out []string
	for name, min := range Features {
		if v.Less(MustParse(min)) {
			l := labels[name]
			if l == "" {
				l = name
			}
			out = append(out, l+" (needs "+min+")")
		}
	}
	sort.Strings(out)
	return out
}

// UpdateMessage is the text an admin can copy and send to a person who needs to
// update. latest is the newest release the server knows.
func (p Policy) UpdateMessage(name string) string {
	greet := "Hi"
	if name != "" {
		greet = "Hi " + name
	}
	return greet + ", our family server now needs Orbitly " + p.Min.String() +
		" or newer, and the newest version is " + p.Latest.String() +
		". Please update the app (open Obtainium or the app store and update Orbitly; your sign-in and data stay). Until you do, you may see an \"Update required\" banner" +
		" and your location may stop showing for the rest of us. Thanks!"
}
