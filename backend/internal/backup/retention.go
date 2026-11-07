package backup

import (
	"fmt"
	"sort"
	"time"
)

// Entry is one complete backup (a manifest exists) known to a store.
type Entry struct {
	Name string // base name without extension, openfamily-<ts>
	Time time.Time
}

// SelectPrune returns the entries to delete under the keep-daily/weekly/
// monthly policy. Guarantees: the newest entry is never selected; the result
// is deterministic; if all three counts are zero nothing is selected.
func SelectPrune(entries []Entry, r Retention, loc *time.Location) []Entry {
	if len(entries) == 0 || (r.Daily == 0 && r.Weekly == 0 && r.Monthly == 0) {
		return nil
	}
	if loc == nil {
		loc = time.UTC
	}
	es := append([]Entry(nil), entries...)
	sort.Slice(es, func(i, j int) bool { return es[i].Time.After(es[j].Time) })
	keep := map[string]bool{es[0].Name: true}
	tier := func(n int, key func(time.Time) string) {
		seen := map[string]bool{}
		for _, e := range es {
			k := key(e.Time.In(loc))
			if seen[k] {
				continue
			}
			if len(seen) >= n {
				return
			}
			seen[k] = true
			keep[e.Name] = true
		}
	}
	if r.Daily > 0 {
		tier(r.Daily, func(t time.Time) string { return t.Format("2006-01-02") })
	}
	if r.Weekly > 0 {
		tier(r.Weekly, func(t time.Time) string { y, w := t.ISOWeek(); return fmt.Sprintf("%d-W%02d", y, w) })
	}
	if r.Monthly > 0 {
		tier(r.Monthly, func(t time.Time) string { return t.Format("2006-01") })
	}
	var del []Entry
	for _, e := range es {
		if !keep[e.Name] {
			del = append(del, e)
		}
	}
	return del
}
