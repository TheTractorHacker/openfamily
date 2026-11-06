package handlers

import (
	"encoding/json"
	"net/http"
	"regexp"
)

var (
	iosTeamIDRe   = regexp.MustCompile(`^[A-Z0-9]{10}$`)
	iosBundleIDRe = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9.-]{0,150}[A-Za-z0-9])?$`)
)

// AppleAppSiteAssociation serves GET /.well-known/apple-app-site-association,
// the file iOS fetches (through Apple's CDN, no redirects, no auth) to decide
// whether https://<this server>/join/<code> opens the OpenFamily app instead
// of Safari. It is driven by IOS_TEAM_ID and IOS_BUNDLE_ID. With no (or a
// malformed) team id it answers 404, so servers without an iOS app publish
// nothing. The app additionally has to carry the matching
// applinks:<this host> Associated Domains entitlement (docs/design/IOS_RELEASE.md).
func (s *Server) AppleAppSiteAssociation(w http.ResponseWriter, r *http.Request) {
	team, bundle := s.IOSTeamID, s.IOSBundleID
	if bundle == "" {
		bundle = "app.openfamily"
	}
	if !iosTeamIDRe.MatchString(team) || !iosBundleIDRe.MatchString(bundle) {
		http.NotFound(w, r)
		return
	}
	appID := team + "." + bundle
	doc := map[string]any{
		"applinks": map[string]any{
			"details": []any{map[string]any{
				"appIDs": []string{appID},
				"components": []any{
					map[string]any{"/": "/join/*", "comment": "family invite links"},
				},
			}},
		},
	}
	body, err := json.Marshal(doc)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = w.Write(body)
}
