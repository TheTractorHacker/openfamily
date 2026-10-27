package handlers

import "testing"

func TestAlertMuteCategory(t *testing.T) {
	if got := alertMuteCategory(alertCheckIn); got != "check_in" {
		t.Fatalf("check-in category = %q", got)
	}
	for _, typ := range []string{alertSOS, alertHelp} {
		if got := alertMuteCategory(typ); got != "" {
			t.Fatalf("%s must never be mutable, got %q", typ, got)
		}
	}
}

func TestDefaultNotificationPrefsAllOn(t *testing.T) {
	if p := defaultNotificationPrefs(); p != (NotificationPrefs{true, true, true, true, true, true}) {
		t.Fatalf("defaults not all on: %+v", p)
	}
}
