package main

import (
	"testing"
	"time"
)

func TestMintEveryStaysBelowAccessTTL(t *testing.T) {
	for _, c := range []struct{ ttl, want time.Duration }{
		{15 * time.Minute, 5 * time.Minute},
		{time.Hour, 5 * time.Minute},
		{6 * time.Minute, 2 * time.Minute},
		{0, 5 * time.Minute},
	} {
		if got := mintEveryFor(c.ttl); got != c.want {
			t.Errorf("mintEveryFor(%v) = %v, want %v", c.ttl, got, c.want)
		}
		if c.ttl > 0 && mintEveryFor(c.ttl) >= c.ttl {
			t.Errorf("mintEveryFor(%v) must be below the TTL", c.ttl)
		}
	}
}
