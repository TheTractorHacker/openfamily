package auth

import "testing"

func TestArgonConcurrency(t *testing.T) {
	for in, want := range map[string]int{"": 2, "x": 2, "0": 2, "-3": 2, "999": 2, "4": 4, " 3 ": 3} {
		if got := argonConcurrency(in); got != want {
			t.Errorf("argonConcurrency(%q)=%d want %d", in, got, want)
		}
	}
}
