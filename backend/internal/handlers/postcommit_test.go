package handlers

import (
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestBoundedRunnerLimitsConcurrencyAndSheds(t *testing.T) {
	r := newBoundedRunner(2, 4)
	release := make(chan struct{})
	var active, peak atomic.Int32
	var wg sync.WaitGroup
	accepted := 0
	for i := 0; i < 10; i++ {
		wg.Add(1)
		ok := r.Submit(func() {
			defer wg.Done()
			n := active.Add(1)
			for {
				p := peak.Load()
				if n <= p || peak.CompareAndSwap(p, n) {
					break
				}
			}
			<-release
			active.Add(-1)
		})
		if ok {
			accepted++
		} else {
			wg.Done()
		}
	}
	if accepted != 4 {
		t.Fatalf("accepted %d, want 4 (queue bound)", accepted)
	}
	time.Sleep(50 * time.Millisecond)
	if got := active.Load(); got != 2 {
		t.Fatalf("active %d, want 2", got)
	}
	close(release)
	wg.Wait()
	if peak.Load() > 2 {
		t.Fatalf("peak %d exceeds bound", peak.Load())
	}
	if r.dropped.Load() != 6 {
		t.Fatalf("dropped %d, want 6", r.dropped.Load())
	}
	// Slots are released: new work is accepted again.
	done := make(chan struct{})
	deadline := time.Now().Add(time.Second)
	for !r.Submit(func() { close(done) }) {
		if time.Now().After(deadline) {
			t.Fatal("slots not released")
		}
		time.Sleep(5 * time.Millisecond)
	}
	<-done
}

func TestReconcileSQLUsesMemberPositionsWithBound(t *testing.T) {
	if !strings.Contains(reconcileLatestPointsSQL, "FROM member_positions") ||
		!strings.Contains(reconcileLatestPointsSQL, "ts > now()") ||
		strings.Contains(reconcileLatestPointsSQL, "locations") {
		t.Fatalf("reconcile query must read bounded member_positions: %s", reconcileLatestPointsSQL)
	}
}
