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
	p := defaultNotificationPrefs()
	if p != (NotificationPrefs{PlaceAlerts: true, CheckIn: true, LowBattery: true, CompletedDrives: true,
		SafetyIncidents: true, SevereWeather: true, WeeklySummary: true, PhoneSilent: true}) {
		t.Fatalf("defaults not all on: %+v", p)
	}
	// Names are an opt-in: off by default.
	if p.ShowNames || p.Units != "" {
		t.Fatalf("show_names/units defaults wrong: %+v", p)
	}
}
