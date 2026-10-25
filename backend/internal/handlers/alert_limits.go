package handlers

import (
	"os"
	"strconv"
	"time"
)

// AlertLimits bounds alert fan-out (BSEC-009). Zero values select the safe
// defaults below via withDefaults, so a bare Server in tests behaves sanely.
// All fields can be set from the environment with AlertLimitsFromEnv.
type AlertLimits struct {
	// SOSCooldown and CheckInCooldown: minimum gap between two alerts of the
	// same kind from one sender (ALERT_SOS_COOLDOWN, ALERT_COOLDOWN).
	SOSCooldown     time.Duration
	CheckInCooldown time.Duration
	// FamilyMaxPerHour caps check-in/help alerts per family per hour
	// (ALERT_FAMILY_MAX_PER_HOUR). SOS is never refused by it.
	FamilyMaxPerHour int
	// SMSMaxRecipients caps emergency-contact SMS per alert
	// (ALERT_SMS_MAX_RECIPIENTS). 0 disables alert SMS.
	SMSMaxRecipients int
	// SenderSMSPerDay and FamilySMSPerHour are persisted ceilings counted from
	// alert_deliveries (ALERT_SMS_SENDER_PER_DAY, ALERT_SMS_FAMILY_PER_HOUR).
	SenderSMSPerDay  int
	FamilySMSPerHour int
	// SMSOnCheckIn also texts emergency contacts for check-in and help alerts
	// (ALERT_SMS_ON_CHECKIN, default false: only SOS sends SMS).
	SMSOnCheckIn bool
	// ShareTTL is the lifetime of a public location link (ALERT_SHARE_TTL).
	ShareTTL time.Duration

	set bool // distinguishes an explicit 0 from "unset"
}

const (
	defaultSOSCooldown      = 2 * time.Minute
	defaultCheckInCooldown  = time.Minute
	defaultFamilyMaxPerHour = 30
	defaultSMSMaxRecipients = 5
	defaultSenderSMSPerDay  = 10
	defaultFamilySMSPerHour = 20
	defaultShareTTL         = 4 * time.Hour
	maxShareTTL             = 7 * 24 * time.Hour
)

func (l AlertLimits) withDefaults() AlertLimits {
	if l.SOSCooldown <= 0 {
		l.SOSCooldown = defaultSOSCooldown
	}
	if l.CheckInCooldown <= 0 {
		l.CheckInCooldown = defaultCheckInCooldown
	}
	if l.ShareTTL <= 0 {
		l.ShareTTL = defaultShareTTL
	}
	if l.ShareTTL > maxShareTTL {
		l.ShareTTL = maxShareTTL
	}
	if !l.set {
		l.FamilyMaxPerHour = defaultFamilyMaxPerHour
		l.SMSMaxRecipients = defaultSMSMaxRecipients
		l.SenderSMSPerDay = defaultSenderSMSPerDay
		l.FamilySMSPerHour = defaultFamilySMSPerHour
	}
	return l
}

// AlertLimitsFromEnv reads the ALERT_* variables, falling back to the defaults
// for anything unset or invalid.
func AlertLimitsFromEnv() AlertLimits {
	l := AlertLimits{
		SOSCooldown:      envDur("ALERT_SOS_COOLDOWN", defaultSOSCooldown),
		CheckInCooldown:  envDur("ALERT_COOLDOWN", defaultCheckInCooldown),
		FamilyMaxPerHour: envInt("ALERT_FAMILY_MAX_PER_HOUR", defaultFamilyMaxPerHour),
		SMSMaxRecipients: envInt("ALERT_SMS_MAX_RECIPIENTS", defaultSMSMaxRecipients),
		SenderSMSPerDay:  envInt("ALERT_SMS_SENDER_PER_DAY", defaultSenderSMSPerDay),
		FamilySMSPerHour: envInt("ALERT_SMS_FAMILY_PER_HOUR", defaultFamilySMSPerHour),
		ShareTTL:         envDur("ALERT_SHARE_TTL", defaultShareTTL),
		set:              true,
	}
	if v, err := strconv.ParseBool(os.Getenv("ALERT_SMS_ON_CHECKIN")); err == nil {
		l.SMSOnCheckIn = v
	}
	return l.withDefaults()
}

func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			return n
		}
	}
	return fallback
}

func envDur(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			return d
		}
	}
	return fallback
}

func (s *Server) alertLimits() AlertLimits { return s.AlertCfg.withDefaults() }
