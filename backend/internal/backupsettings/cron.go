package backupsettings

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Cron is a parsed 5-field schedule: minute hour day-of-month month
// day-of-week. Supports *, lists (a,b), ranges (a-b) and steps (*/n, a-b/n).
// Like classic cron, when both day-of-month and day-of-week are restricted a
// day matches if EITHER does.
type Cron struct {
	min, hour, dom, mon, dow uint64
	domStar, dowStar         bool
}

func parseField(s string, lo, hi int) (mask uint64, star bool, err error) {
	for _, part := range strings.Split(s, ",") {
		step := 1
		if i := strings.Index(part, "/"); i >= 0 {
			step, err = strconv.Atoi(part[i+1:])
			if err != nil || step < 1 {
				return 0, false, fmt.Errorf("bad step in %q", s)
			}
			part = part[:i]
		}
		a, b := lo, hi
		switch {
		case part == "*":
			if step == 1 && !strings.Contains(s, ",") {
				star = true
			}
		case strings.Contains(part, "-"):
			p := strings.SplitN(part, "-", 2)
			a, err = strconv.Atoi(p[0])
			if err == nil {
				b, err = strconv.Atoi(p[1])
			}
			if err != nil {
				return 0, false, fmt.Errorf("bad range in %q", s)
			}
		default:
			a, err = strconv.Atoi(part)
			if err != nil {
				return 0, false, fmt.Errorf("bad value in %q", s)
			}
			if !strings.Contains(s, "/") {
				b = a
			}
		}
		if a < lo || b > hi || a > b {
			return 0, false, fmt.Errorf("%q out of range %d-%d", s, lo, hi)
		}
		for v := a; v <= b; v += step {
			mask |= 1 << uint(v)
		}
	}
	return mask, star, nil
}

// ParseCron parses a 5-field cron expression.
func ParseCron(expr string) (*Cron, error) {
	f := strings.Fields(expr)
	if len(f) != 5 {
		return nil, fmt.Errorf("%q must have 5 fields (minute hour day-of-month month day-of-week)", expr)
	}
	var c Cron
	var err error
	if c.min, _, err = parseField(f[0], 0, 59); err != nil {
		return nil, err
	}
	if c.hour, _, err = parseField(f[1], 0, 23); err != nil {
		return nil, err
	}
	if c.dom, c.domStar, err = parseField(f[2], 1, 31); err != nil {
		return nil, err
	}
	if c.mon, _, err = parseField(f[3], 1, 12); err != nil {
		return nil, err
	}
	if c.dow, c.dowStar, err = parseField(f[4], 0, 7); err != nil {
		return nil, err
	}
	if c.dow&(1<<7) != 0 { // 7 == Sunday
		c.dow |= 1
	}
	return &c, nil
}

func (c *Cron) dayMatches(t time.Time) bool {
	d := c.dom&(1<<uint(t.Day())) != 0
	w := c.dow&(1<<uint(t.Weekday())) != 0
	switch {
	case c.domStar && c.dowStar:
		return true
	case c.domStar:
		return w
	case c.dowStar:
		return d
	}
	return d || w
}

// Next returns the first matching minute strictly after t, in t's location.
// Wall-clock fields are matched in that location, so DST shifts behave like
// classic cron (a skipped hour is skipped; a repeated hour fires once for the
// first occurrence because Next only moves forward).
func (c *Cron) Next(t time.Time) time.Time {
	loc := t.Location()
	t = t.Truncate(time.Minute).Add(time.Minute)
	limit := t.AddDate(5, 0, 0)
	for t.Before(limit) {
		if c.mon&(1<<uint(t.Month())) == 0 {
			t = time.Date(t.Year(), t.Month()+1, 1, 0, 0, 0, 0, loc)
			continue
		}
		if !c.dayMatches(t) {
			t = time.Date(t.Year(), t.Month(), t.Day()+1, 0, 0, 0, 0, loc)
			continue
		}
		if c.hour&(1<<uint(t.Hour())) == 0 {
			t = time.Date(t.Year(), t.Month(), t.Day(), t.Hour()+1, 0, 0, 0, loc)
			continue
		}
		if c.min&(1<<uint(t.Minute())) == 0 {
			t = t.Add(time.Minute)
			continue
		}
		return t
	}
	return time.Time{}
}
