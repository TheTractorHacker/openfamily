package geocode

import (
	"encoding/json"
	"net/url"
	"strconv"
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

// stateURL looks up which state a coordinate is in, so a house-number address
// typed without a state ("14322 Old 88 Rd") can still be resolved near the
// person's own pin.
func (census) stateURL(base *url.URL, b *Point) string {
	v := url.Values{
		"x":         {strconv.FormatFloat(b.Lon, 'f', 4, 64)},
		"y":         {strconv.FormatFloat(b.Lat, 'f', 4, 64)},
		"benchmark": {"Public_AR_Current"}, "vintage": {"Current_Current"},
		"format": {"json"},
	}
	return withPath(base, "/geocoder/geographies/coordinates", v)
}

func (census) parseState(body []byte) string {
	var r struct {
		Result struct {
			Geographies struct {
				States []struct {
					Abbr string `json:"STUSAB"`
				} `json:"States"`
			} `json:"geographies"`
		} `json:"result"`
	}
	if json.Unmarshal(body, &r) != nil || len(r.Result.Geographies.States) == 0 {
		return ""
	}
	st := strings.ToUpper(strings.TrimSpace(r.Result.Geographies.States[0].Abbr))
	if len(st) != 2 {
		return ""
	}
	return st
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
