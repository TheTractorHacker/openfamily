package geocode

import (
	"encoding/json"
	"net/url"
	"strings"
)

// censusBase is the US Census Bureau geocoder (free, no key). It resolves
// US street addresses to house-number level by interpolating address ranges.
const censusBase = "https://geocoding.geo.census.gov"

type census struct{}

type censusResponse struct {
	Result struct {
		AddressMatches []struct {
			MatchedAddress string `json:"matchedAddress"`
			Coordinates    struct {
				X float64 `json:"x"`
				Y float64 `json:"y"`
			} `json:"coordinates"`
		} `json:"addressMatches"`
	} `json:"result"`
}

func (census) searchURL(base *url.URL, address string) string {
	v := url.Values{
		"address": {address}, "benchmark": {"Public_AR_Current"}, "format": {"json"},
	}
	return withPath(base, "/geocoder/locations/onelineaddress", v)
}

func (census) parse(body []byte) ([]Result, error) {
	var r censusResponse
	if err := json.Unmarshal(body, &r); err != nil {
		return nil, err
	}
	var out []Result
	for _, m := range r.Result.AddressMatches {
		lat, lon := m.Coordinates.Y, m.Coordinates.X
		if !validCoord(lat, lon) || strings.TrimSpace(m.MatchedAddress) == "" {
			continue
		}
		parts := strings.Split(m.MatchedAddress, ",")
		for i := range parts {
			parts[i] = strings.TrimSpace(parts[i])
		}
		street := titleCase(parts[0])
		label := street
		if len(parts) >= 3 { // street, city, state[, zip]
			label = joinLabel(street, titleCase(parts[1]), parts[2])
		}
		out = append(out, Result{Label: label, Name: street, Lat: lat, Lon: lon, Type: "house", Source: "census"})
	}
	return out, nil
}

func titleCase(s string) string {
	words := strings.Fields(s)
	for i, w := range words {
		switch strings.ToUpper(w) {
		case "NE", "NW", "SE", "SW":
			words[i] = strings.ToUpper(w)
			continue
		}
		words[i] = strings.ToUpper(w[:1]) + strings.ToLower(w[1:])
	}
	return strings.Join(words, " ")
}
