package backup

import "github.com/TheTractorHacker/openfamily/backend/internal/backupsettings"

// Cron is a parsed 5-field schedule; see backupsettings.Cron.
type Cron = backupsettings.Cron

// ParseCron parses a 5-field cron expression.
func ParseCron(expr string) (*Cron, error) { return backupsettings.ParseCron(expr) }
