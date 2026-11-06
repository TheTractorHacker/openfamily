package push

import (
	"context"
	"regexp"
	"strings"
	"testing"
)

// SEC-016 / #21: push providers can read message text, so no latitude or
// longitude may travel in a notification.

func TestRedactCoordinates(t *testing.T) {
	cases := map[string]string{
		"Arrived at 40.712800, -74.006000":      "Arrived at [location]",
		"pos 40.7128;-74.0060 now":              "pos [location] now",
		"-33.868820 / 151.209296":               "[location]",
		"Mom arrived at School":                 "Mom arrived at School",
		"Battery 12.5% at 3.141 pm":             "Battery 12.5% at 3.141 pm",
		"Speed 63.250 km/h, distance 12.125 km": "Speed 63.250 km/h, distance 12.125 km",
		"Version 1.2.3":                         "Version 1.2.3",
	}
	for in, want := range cases {
		if got := RedactCoordinates(in); got != want {
			t.Errorf("RedactCoordinates(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSanitizedLeavesSilentCommandsAlone(t *testing.T) {
	n := Notification{Silent: true, Body: `{"cmd":"locate","x":"1.2345,6.7890"}`}
	if n.sanitized().Body != n.Body {
		t.Fatal("silent command body must not be rewritten")
	}
	n = Notification{Title: "t 1.2345, 6.7890", Body: "b 1.2345, 6.7890"}
	got := n.sanitized()
	if strings.Contains(got.Title, "1.2345") || strings.Contains(got.Body, "1.2345") {
		t.Fatalf("coordinates survived: %+v", got)
	}
}

// End to end through the direct channel: whatever text a caller supplies, the
// queued event carries no coordinate pair, and only the dedupe id (not a
// position) distinguishes repeats.
func TestDispatchDirectPayloadHasNoCoordinates(t *testing.T) {
	f := newOutboxFixture(t)
	d := &DispatcherImpl{}
	d.SetDirect(f.b)
	pair := regexp.MustCompile(`-?\d{1,3}\.\d{3,}\s*[,;/]\s*-?\d{1,3}\.\d{3,}`)

	ctx := context.Background()
	n := f.note("coord-1")
	n.Title = "Alex left 40.712800, -74.006000"
	n.Body = "last seen 40.712800, -74.006000"
	for i := 0; i < 2; i++ { // second enqueue: deduplicated
		if err := d.Dispatch(ctx, n); err != nil {
			t.Fatal(err)
		}
	}
	evs, err := f.b.Pending(ctx, f.device, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 1 {
		t.Fatalf("pending=%d, want 1 (dedupe on DedupeID)", len(evs))
	}
	if pair.Match(evs[0].Payload) {
		t.Fatalf("queued payload carries coordinates: %s", evs[0].Payload)
	}
}
