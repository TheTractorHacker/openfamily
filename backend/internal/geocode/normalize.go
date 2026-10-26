package geocode

import (
	"regexp"
	"strconv"
	"strings"
)

// Pure query normalisation and the relaxation ladder candidates. Nothing here
// does I/O or logging.

var usStates = map[string]string{
	"AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
	"CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "DC": "District of Columbia",
	"FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois",
	"IN": "Indiana", "IA": "Iowa", "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana",
	"ME": "Maine", "MD": "Maryland", "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota",
	"MS": "Mississippi", "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
	"NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
	"NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon",
	"PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
	"TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia",
	"WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
}

// Codes that are also common English words: expanded only after a comma or
// when typed fully upper-case ("Cafe in" is not Indiana).
var ambiguousStates = map[string]bool{
	"IN": true, "OR": true, "ME": true, "HI": true, "OK": true, "OH": true,
	"ID": true, "DE": true, "LA": true, "PA": true, "MA": true, "AL": true, "CO": true,
}

var stateNames = func() map[string]bool {
	m := map[string]bool{}
	for _, n := range usStates {
		m[strings.ToLower(n)] = true
	}
	return m
}()

// Suffix words that may be glued to a number ("88rd").
var glueSuffixes = map[string]bool{
	"rd": true, "st": true, "ave": true, "hwy": true, "dr": true, "ln": true, "blvd": true,
	"ct": true, "cir": true, "pkwy": true, "rte": true, "rt": true, "road": true,
	"street": true, "avenue": true, "highway": true, "drive": true, "lane": true,
}

var suffixWords = map[string]string{
	"rd": "Road", "ave": "Avenue", "av": "Avenue", "hwy": "Highway", "ln": "Lane",
	"blvd": "Boulevard", "ct": "Court", "cir": "Circle", "pkwy": "Parkway",
	"rte": "Route", "rt": "Route", "st": "Street", "dr": "Drive",
}

var directions = map[string]string{"n": "North", "s": "South", "e": "East", "w": "West"}

var (
	gluedRe  = regexp.MustCompile(`^(\d+)([A-Za-z]{2,})$`)
	numberRe = regexp.MustCompile(`^\d+[A-Za-z]?$|^\d+-\d+$`)
	zipRe    = regexp.MustCompile(`^\d{5}(-\d{4})?$`)
)

// validOrdinal reports whether digits+suf is a real ordinal (3rd, 21st, 12th).
func validOrdinal(digits, suf string) bool {
	n, err := strconv.Atoi(digits)
	if err != nil {
		return false
	}
	want := "th"
	if n%100 < 11 || n%100 > 13 {
		switch n % 10 {
		case 1:
			want = "st"
		case 2:
			want = "nd"
		case 3:
			want = "rd"
		}
	}
	return strings.EqualFold(suf, want)
}

func splitGlued(tok string) []string {
	m := gluedRe.FindStringSubmatch(tok)
	if m == nil || !glueSuffixes[strings.ToLower(m[2])] || validOrdinal(m[1], m[2]) {
		return []string{tok}
	}
	return []string{m[1], m[2]}
}

func isDirection(tok string) bool {
	_, ok := directions[strings.ToLower(tok)]
	return ok && len(tok) == 1
}

// expandStreet expands street-type abbreviations in one street part, only
// where that is unambiguous ("St Louis" and "Dr Smith" stay as they are).
func expandStreet(toks []string) []string {
	out := make([]string, len(toks))
	copy(out, toks)
	for i, t := range toks {
		low := strings.ToLower(t)
		nextIsNum := i+1 < len(toks) && regexp.MustCompile(`^\d`).MatchString(toks[i+1])
		last := i == len(toks)-1
		beforeDir := i+1 < len(toks) && isDirection(toks[i+1]) && i+2 == len(toks)
		switch {
		case low == "hwy" || low == "rte" || low == "rt":
			if i > 0 || nextIsNum {
				out[i] = suffixWords[low]
			}
		case low == "st" || low == "dr":
			if i > 0 && (last || beforeDir) {
				out[i] = suffixWords[low]
			}
		case suffixWords[low] != "" && i > 0:
			out[i] = suffixWords[low]
		case isDirection(t):
			// "123 N Main", or a trailing direction after a street type.
			if i == 1 && numberRe.MatchString(toks[0]) && len(toks) > 2 {
				out[i] = directions[low]
			} else if last && i >= 2 && suffixWords[strings.ToLower(toks[i-1])] != "" {
				out[i] = directions[low]
			}
		}
	}
	return out
}

type parsed struct {
	parts   []string // comma separated, normalised
	usState string   // two-letter code when a US state was recognised
}

func parse(q string) parsed {
	var parts [][]string
	for _, raw := range strings.Split(q, ",") {
		var toks []string
		for _, f := range strings.Fields(raw) {
			f = strings.TrimRight(f, ".;")
			if f == "" {
				continue
			}
			toks = append(toks, splitGlued(f)...)
		}
		if len(toks) > 0 {
			parts = append(parts, toks)
		}
	}
	var p parsed
	if len(parts) == 0 {
		return p
	}
	parts[0] = expandStreet(parts[0])

	// Trailing state, optionally followed by a ZIP ("Chester AR 72934" or
	// "Chester, AR, 72934").
	li := len(parts) - 1
	zip := ""
	if li > 0 && len(parts[li]) == 1 && zipRe.MatchString(parts[li][0]) {
		zip = parts[li][0]
		parts = parts[:li]
		li--
	} else if n := len(parts[li]); n > 1 && zipRe.MatchString(parts[li][n-1]) {
		zip = parts[li][n-1]
		parts[li] = parts[li][:n-1]
	}
	last := parts[li]
	si := len(last) - 1
	cand := last[si]
	code := strings.ToUpper(cand)
	if name, ok := usStates[code]; ok && len(cand) == 2 && (li > 0 || si > 0) {
		afterComma := si == 0 && li > 0
		if !ambiguousStates[code] || afterComma || cand == code {
			p.usState = code
			np := append([][]string{}, parts[:li]...)
			if si > 0 {
				np = append(np, last[:si])
			}
			parts = append(np, []string{name})
			li = len(parts) - 1
		}
	} else if li > 0 {
		for c, n := range usStates {
			if strings.EqualFold(n, strings.Join(last, " ")) {
				p.usState = c
			}
		}
	}
	if zip != "" {
		parts[li] = append(append([]string{}, parts[li]...), zip)
	}
	for _, t := range parts {
		p.parts = append(p.parts, strings.Join(t, " "))
	}
	return p
}

// Normalize returns the cleaned-up query: whitespace collapsed, digits split
// from glued street words ("88rd" -> "88 rd"), street-type abbreviations
// expanded where safe, and a trailing US state code expanded
// ("Chester Ar" -> "Chester, Arkansas").
func Normalize(q string) string {
	return strings.Join(parse(q).parts, ", ")
}

// Candidate is one upstream attempt of the relaxation ladder.
type Candidate struct {
	Query string
	// Relax is "" for the full query, "street" when the house number was
	// dropped, "locality" when the street was dropped too.
	Relax string
}

// MaxAttempts caps upstream calls per search request.
const MaxAttempts = 3

// Candidates returns the ladder for q, deduplicated and capped at
// MaxAttempts: original (when normalisation changed it), normalised, without
// house number, without street. When the cap would be exceeded the raw
// original is the one dropped: the normalised form is strictly better.
func Candidates(q string) []Candidate {
	orig := strings.Join(strings.Fields(q), " ")
	p := parse(q)
	norm := strings.Join(p.parts, ", ")
	var out []Candidate
	seen := map[string]bool{}
	add := func(s, relax string) {
		s = strings.TrimSpace(s)
		k := strings.ToLower(s)
		if s == "" || seen[k] {
			return
		}
		seen[k] = true
		out = append(out, Candidate{Query: s, Relax: relax})
	}
	add(orig, "")
	add(norm, "")
	if len(p.parts) > 0 {
		toks := strings.Fields(p.parts[0])
		rest := p.parts[1:]
		if len(toks) >= 2 && numberRe.MatchString(toks[0]) {
			add(strings.Join(append([]string{strings.Join(toks[1:], " ")}, rest...), ", "), "street")
		}
		// Dropping the street needs a locality that is more than a bare state.
		if len(rest) >= 2 || (len(rest) == 1 && !stateNames[strings.ToLower(rest[0])]) {
			add(strings.Join(rest, ", "), "locality")
		}
	}
	if len(out) > MaxAttempts {
		out = out[1:]
	}
	if len(out) > MaxAttempts {
		out = out[:MaxAttempts]
	}
	return out
}

// hasHouseNumber reports whether q starts its street part with a number.
func hasHouseNumber(q string) bool {
	p := parse(q)
	if len(p.parts) == 0 {
		return false
	}
	toks := strings.Fields(p.parts[0])
	return len(toks) >= 2 && numberRe.MatchString(toks[0])
}
