package geocode

import (
	"encoding/json"
	"math"
	"net/url"
	"strconv"
	"strings"
)

// Result is one normalized forward-geocoding hit.
type Result struct {
	Label string  `json:"label"`
	Name  string  `json:"name"`
	Lat   float64 `json:"lat"`
	Lon   float64 `json:"lon"`
	Type  string  `json:"type"` // house | street | city | poi
	// Approximate is true when the hit comes from a relaxed attempt (the house
	// number or street was dropped); Matched says what was matched: "street"
	// or "locality".
	Approximate bool   `json:"approximate,omitempty"`
	Matched     string `json:"matched,omitempty"`
	// Source is set for fallback providers ("nominatim", "census").
	Source string `json:"source,omitempty"`
}

// Address is a normalized reverse-geocoding hit.
type Address struct {
	Address string  `json:"address"`
	Lat     float64 `json:"lat"`
	Lon     float64 `json:"lon"`
}

// Point is a latitude/longitude pair.
type Point struct{ Lat, Lon float64 }

// provider turns normalized requests into upstream URLs and upstream bodies
// into normalized results.
type provider interface {
	searchURL(base *url.URL, q string, bias *Point, limit int, lang string) string
	reverseURL(base *url.URL, p Point, lang string) string
	parseSearch(body []byte) ([]Result, error)
	parseReverse(body []byte) (*Address, error)
}

func withPath(base *url.URL, p string, q url.Values) string {
	u := *base
	u.Path = strings.TrimRight(base.Path, "/") + p
	u.RawQuery = q.Encode()
	return u.String()
}

func validCoord(lat, lon float64) bool {
	return !math.IsNaN(lat) && !math.IsNaN(lon) && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
}

// joinLabel joins non-empty parts, skipping consecutive duplicates.
func joinLabel(parts ...string) string {
	var out []string
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if len(out) > 0 && strings.EqualFold(out[len(out)-1], p) {
			continue
		}
		out = append(out, p)
	}
	return strings.Join(out, ", ")
}

func streetLine(houseNumber, street string) string {
	return strings.TrimSpace(strings.TrimSpace(houseNumber) + " " + strings.TrimSpace(street))
}

// ---------- Photon ----------

type photon struct{}

// photonBiasScale strengthens the local bias (0..1). Checked live: 0.6 keeps
// nearby streets first without hurting ranking; 1.0 starts to push exact
// text matches below unrelated, merely close places.
const photonBiasScale = "0.6"

type photonCollection struct {
	Features []struct {
		Geometry struct {
			Coordinates []float64 `json:"coordinates"`
		} `json:"geometry"`
		Properties struct {
			Name        string `json:"name"`
			HouseNumber string `json:"housenumber"`
			Street      string `json:"street"`
			City        string `json:"city"`
			District    string `json:"district"`
			Locality    string `json:"locality"`
			County      string `json:"county"`
			State       string `json:"state"`
			Country     string `json:"country"`
			Type        string `json:"type"`
			OSMKey      string `json:"osm_key"`
		} `json:"properties"`
	} `json:"features"`
}

func (photon) searchURL(base *url.URL, q string, bias *Point, limit int, lang string) string {
	v := url.Values{"q": {q}, "limit": {strconv.Itoa(limit)}}
	if bias != nil {
		v.Set("lat", strconv.FormatFloat(bias.Lat, 'f', 3, 64))
		v.Set("lon", strconv.FormatFloat(bias.Lon, 'f', 3, 64))
		v.Set("location_bias_scale", photonBiasScale)
	}
	if lang != "" {
		v.Set("lang", lang)
	}
	return withPath(base, "/api", v)
}

func (photon) reverseURL(base *url.URL, p Point, lang string) string {
	v := url.Values{
		"lat":   {strconv.FormatFloat(p.Lat, 'f', 5, 64)},
		"lon":   {strconv.FormatFloat(p.Lon, 'f', 5, 64)},
		"limit": {"1"},
	}
	if lang != "" {
		v.Set("lang", lang)
	}
	return withPath(base, "/reverse", v)
}

func (photon) parseAll(body []byte) ([]Result, error) {
	var fc photonCollection
	if err := json.Unmarshal(body, &fc); err != nil {
		return nil, err
	}
	out := make([]Result, 0, len(fc.Features))
	for _, f := range fc.Features {
		if len(f.Geometry.Coordinates) < 2 {
			continue
		}
		lon, lat := f.Geometry.Coordinates[0], f.Geometry.Coordinates[1]
		if !validCoord(lat, lon) {
			continue
		}
		p := f.Properties
		city := firstNonEmpty(p.City, p.Locality, p.District, p.County)
		kind := photonKind(p.Type, p.OSMKey, p.HouseNumber, p.Street, p.Name)
		var label, name string
		switch kind {
		case "house":
			name = streetLine(p.HouseNumber, p.Street)
			if name == "" {
				name = p.Name
			}
			label = joinLabel(name, city, p.State)
		case "street":
			name = firstNonEmpty(p.Street, p.Name)
			label = joinLabel(name, city, p.State)
		case "poi":
			name = p.Name
			label = joinLabel(name, streetLine(p.HouseNumber, p.Street), city, p.State)
		default: // city and larger areas
			name = p.Name
			label = joinLabel(name, p.State, p.Country)
			if p.Type == "country" {
				label = p.Name
			}
		}
		if label == "" {
			continue
		}
		out = append(out, Result{Label: label, Name: name, Lat: lat, Lon: lon, Type: kind})
	}
	return out, nil
}

func (p photon) parseSearch(body []byte) ([]Result, error) { return p.parseAll(body) }

func (p photon) parseReverse(body []byte) (*Address, error) {
	rs, err := p.parseAll(body)
	if err != nil || len(rs) == 0 {
		return nil, err
	}
	return &Address{Address: rs[0].Label, Lat: rs[0].Lat, Lon: rs[0].Lon}, nil
}

func photonKind(typ, osmKey, house, street, name string) string {
	switch typ {
	case "city", "town", "village", "locality", "district", "county", "state", "country":
		return "city"
	case "street":
		return "street"
	case "house":
		if house != "" && (name == "" || name == street || name == house) {
			return "house"
		}
		if name != "" && osmKey != "building" && osmKey != "place" && osmKey != "highway" {
			return "poi"
		}
		return "house"
	}
	switch osmKey {
	case "highway":
		return "street"
	case "place", "boundary":
		return "city"
	}
	if house != "" && name == "" {
		return "house"
	}
	return "poi"
}

// ---------- Nominatim ----------

type nominatim struct{}

type nominatimItem struct {
	Lat         string `json:"lat"`
	Lon         string `json:"lon"`
	DisplayName string `json:"display_name"`
	Category    string `json:"category"`
	Type        string `json:"type"`
	AddressType string `json:"addresstype"`
	Name        string `json:"name"`
	Address     struct {
		HouseNumber string `json:"house_number"`
		Road        string `json:"road"`
		City        string `json:"city"`
		Town        string `json:"town"`
		Village     string `json:"village"`
		Hamlet      string `json:"hamlet"`
		Suburb      string `json:"suburb"`
		County      string `json:"county"`
		State       string `json:"state"`
		Country     string `json:"country"`
	} `json:"address"`
	Error string `json:"error"`
}

func (nominatim) searchURL(base *url.URL, q string, bias *Point, limit int, lang string) string {
	v := url.Values{
		"q": {q}, "format": {"jsonv2"}, "addressdetails": {"1"}, "limit": {strconv.Itoa(limit)},
	}
	if bias != nil {
		// A soft bias: viewbox without bounded=1 only ranks nearby hits higher.
		v.Set("viewbox", viewbox(bias))
	}
	if lang != "" {
		v.Set("accept-language", lang)
	}
	return withPath(base, "/search", v)
}

func viewbox(bias *Point) string {
	const d = 0.5
	return strconv.FormatFloat(bias.Lon-d, 'f', 3, 64) + "," +
		strconv.FormatFloat(bias.Lat+d, 'f', 3, 64) + "," +
		strconv.FormatFloat(bias.Lon+d, 'f', 3, 64) + "," +
		strconv.FormatFloat(bias.Lat-d, 'f', 3, 64)
}

// structuredURL builds a structured search (street/city/state), which the
// public Nominatim often resolves better than free text for US addresses.
func (nominatim) structuredURL(base *url.URL, street, city, state string, us bool, bias *Point, limit int, lang string) string {
	v := url.Values{
		"street": {street}, "city": {city}, "state": {state},
		"format": {"jsonv2"}, "addressdetails": {"1"}, "limit": {strconv.Itoa(limit)},
	}
	if us {
		v.Set("countrycodes", "us")
	}
	if bias != nil {
		v.Set("viewbox", viewbox(bias))
	}
	if lang != "" {
		v.Set("accept-language", lang)
	}
	return withPath(base, "/search", v)
}

func (nominatim) reverseURL(base *url.URL, p Point, lang string) string {
	v := url.Values{
		"lat":            {strconv.FormatFloat(p.Lat, 'f', 5, 64)},
		"lon":            {strconv.FormatFloat(p.Lon, 'f', 5, 64)},
		"format":         {"jsonv2"},
		"addressdetails": {"1"},
		"zoom":           {"18"},
	}
	if lang != "" {
		v.Set("accept-language", lang)
	}
	return withPath(base, "/reverse", v)
}

func (n nominatim) convert(it nominatimItem) (Result, bool) {
	lat, err1 := strconv.ParseFloat(it.Lat, 64)
	lon, err2 := strconv.ParseFloat(it.Lon, 64)
	if err1 != nil || err2 != nil || !validCoord(lat, lon) {
		return Result{}, false
	}
	a := it.Address
	city := firstNonEmpty(a.City, a.Town, a.Village, a.Hamlet, a.Suburb, a.County)
	kind := nominatimKind(it)
	var name, label string
	switch kind {
	case "house":
		name = streetLine(a.HouseNumber, a.Road)
		if name == "" {
			name = it.Name
		}
		label = joinLabel(name, city, a.State)
	case "street":
		name = firstNonEmpty(a.Road, it.Name)
		label = joinLabel(name, city, a.State)
	case "poi":
		name = it.Name
		label = joinLabel(name, streetLine(a.HouseNumber, a.Road), city, a.State)
	default:
		name = it.Name
		label = joinLabel(name, a.State, a.Country)
	}
	if label == "" {
		label = shortDisplayName(it.DisplayName)
		if name == "" {
			name = label
		}
	}
	if label == "" {
		return Result{}, false
	}
	return Result{Label: label, Name: name, Lat: lat, Lon: lon, Type: kind}, true
}

func nominatimKind(it nominatimItem) string {
	switch it.AddressType {
	case "house", "building":
		if it.Name == "" || it.Name == it.Address.HouseNumber {
			return "house"
		}
		if it.Category == "place" || it.Category == "building" {
			return "house"
		}
		return "poi"
	case "road":
		return "street"
	case "city", "town", "village", "hamlet", "suburb", "county", "state", "country", "municipality", "neighbourhood", "city_district", "postcode":
		return "city"
	}
	switch it.Category {
	case "highway":
		return "street"
	case "place", "boundary":
		if it.Address.HouseNumber != "" {
			return "house"
		}
		return "city"
	case "building":
		return "house"
	}
	if it.Address.HouseNumber != "" && it.Name == "" {
		return "house"
	}
	return "poi"
}

func shortDisplayName(s string) string {
	parts := strings.Split(s, ",")
	if len(parts) > 4 {
		parts = parts[:4]
	}
	return joinLabel(parts...)
}

func (n nominatim) parseSearch(body []byte) ([]Result, error) {
	var items []nominatimItem
	if err := json.Unmarshal(body, &items); err != nil {
		return nil, err
	}
	out := make([]Result, 0, len(items))
	for _, it := range items {
		if r, ok := n.convert(it); ok {
			out = append(out, r)
		}
	}
	return out, nil
}

func (n nominatim) parseReverse(body []byte) (*Address, error) {
	var it nominatimItem
	if err := json.Unmarshal(body, &it); err != nil {
		return nil, err
	}
	if it.Error != "" {
		return nil, nil
	}
	r, ok := n.convert(it)
	if !ok {
		return nil, nil
	}
	return &Address{Address: r.Label, Lat: r.Lat, Lon: r.Lon}, nil
}

func firstNonEmpty(v ...string) string {
	for _, s := range v {
		if strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
	}
	return ""
}
