package geocode

import (
	"reflect"
	"testing"
)

func TestNormalize(t *testing.T) {
	cases := []struct{ in, want string }{
		{"14322 Old 88rd, Chester Ar", "14322 Old 88 Road, Chester, Arkansas"}, // owner's string
		{"14322 Old 88rd, Chester AR", "14322 Old 88 Road, Chester, Arkansas"},
		{"14322 Old 88rd, Chester ar", "14322 Old 88 Road, Chester, Arkansas"},
		{"14322 Old 88 Rd, Chester, AR", "14322 Old 88 Road, Chester, Arkansas"},
		{"  123   Main   St.  ,  Springfield ,  il ", "123 Main Street, Springfield, Illinois"},
		{"123 N Main St, Springfield, IL 62701", "123 North Main Street, Springfield, Illinois 62701"},
		{"123 Main St, Springfield, IL, 62701", "123 Main Street, Springfield, Illinois 62701"},
		{"500 Hwy 88, Chester, AR", "500 Highway 88, Chester, Arkansas"},
		{"Hwy 88, Chester AR", "Highway 88, Chester, Arkansas"},
		{"Rte 7 Chester AR", "Route 7 Chester, Arkansas"},
		{"22 Oak Ave", "22 Oak Avenue"},
		{"9 Sunset Blvd, LA", "9 Sunset Boulevard, Louisiana"},
		{"9 Sunset Blvd, la", "9 Sunset Boulevard, Louisiana"},
		// ambiguous codes need a comma or upper case
		{"coffee shop in", "coffee shop in"},
		{"cafe or", "cafe or"},
		{"Cafe Rouge IN", "Cafe Rouge, Indiana"},
		// safety: do not expand where the word is a name
		{"St Louis, MO", "St Louis, Missouri"},
		{"Dr Smith Clinic", "Dr Smith Clinic"},
		{"Chester", "Chester"},
		{"AR", "AR"},
		// ordinals stay, glued suffixes split
		{"43rd St, Chester AR", "43rd Street, Chester, Arkansas"},
		{"21st Ave", "21st Avenue"},
		{"12th St", "12th Street"},
		{"88rd", "88 Road"},
		{"7 Elm Dr", "7 Elm Drive"},
		{"45 Pine Ln, Austin, Texas", "45 Pine Lane, Austin, Texas"},
		{"221B Baker Street, London", "221B Baker Street, London"},
		{"", ""},
	}
	for _, c := range cases {
		if got := Normalize(c.in); got != c.want {
			t.Errorf("Normalize(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestCandidatesOwner(t *testing.T) {
	got := Candidates("14322 Old 88rd, Chester Ar")
	want := []Candidate{
		{"14322 Old 88 Road, Chester, Arkansas", ""},
		{"Old 88 Road, Chester, Arkansas", "street"},
		{"Chester, Arkansas", "locality"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%+v", got)
	}
}

func TestCandidatesShapes(t *testing.T) {
	// Clean input: original == normalised, so three attempts are possible.
	got := Candidates("123 Main Street, Springfield, Illinois")
	if len(got) != 3 || got[0].Relax != "" || got[1].Relax != "street" || got[2].Relax != "locality" {
		t.Fatalf("%+v", got)
	}
	// No house number: full, then locality.
	got = Candidates("Old 88 Road, Chester, Arkansas")
	if len(got) != 2 || got[1] != (Candidate{"Chester, Arkansas", "locality"}) {
		t.Fatalf("%+v", got)
	}
	// A lone city is a single attempt; a bare state is never a locality fallback.
	if got = Candidates("Chester, AR"); len(got) != 2 || got[0].Query != "Chester, AR" || got[1].Query != "Chester, Arkansas" {
		// original differs from normalised: both kept (2 <= cap)
		t.Fatalf("%+v", got)
	}
	got = Candidates("12 Elm St, AR")
	for _, c := range got {
		if c.Relax == "locality" {
			t.Fatalf("bare state used as locality: %+v", got)
		}
	}
	if len(Candidates("Chester")) != 1 {
		t.Fatal("single token")
	}
	for _, q := range []string{"14322 Old 88rd, Chester Ar", "1 a b, c, d, e, f", "9 x st, y, ca"} {
		if n := len(Candidates(q)); n > MaxAttempts {
			t.Fatalf("%q: %d attempts", q, n)
		}
	}
}

func TestHasHouseNumber(t *testing.T) {
	for q, want := range map[string]bool{
		"14322 Old 88rd, Chester Ar": true, "Old 88 Road, Chester": false,
		"221B Baker St": true, "500": false, "Chester, AR": false, "88 rd": true,
	} {
		if hasHouseNumber(q) != want {
			t.Errorf("%q", q)
		}
	}
}
