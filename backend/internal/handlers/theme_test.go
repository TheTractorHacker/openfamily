package handlers

import "testing"

func TestAccentHexRe(t *testing.T) {
	for _, ok := range []string{"#8FD400", "#abcdef"} {
		if !accentHexRe.MatchString(ok) {
			t.Errorf("%s should be valid", ok)
		}
	}
	for _, bad := range []string{"", "8FD400", "#FFF", "#GGGGGG", "#8FD4000", "red"} {
		if accentHexRe.MatchString(bad) {
			t.Errorf("%s should be invalid", bad)
		}
	}
}
