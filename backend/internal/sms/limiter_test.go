package sms

import (
	"testing"
	"time"
)

func TestLimiterAllow(t *testing.T) {
	l := NewLimiter()
	if !l.Allow("u1", 1, time.Minute) {
		t.Fatal("first hit should allow")
	}
	if l.Allow("u1", 1, time.Minute) {
		t.Fatal("second hit in window should deny")
	}
	if !l.Allow("u2", 1, time.Minute) {
		t.Fatal("other key should allow")
	}
}

func TestLimiterWindowExpiry(t *testing.T) {
	l := NewLimiter()
	if !l.Allow("u1", 1, 20*time.Millisecond) {
		t.Fatal("first hit should allow")
	}
	time.Sleep(30 * time.Millisecond)
	if !l.Allow("u1", 1, 20*time.Millisecond) {
		t.Fatal("hit after window should allow")
	}
}

func TestLimiterEvictsExpiredKeys(t *testing.T) {
	l := NewLimiter()
	now := time.Now()
	l.now = func() time.Time { return now }
	for i := 0; i < 5000; i++ {
		l.Allow("k"+string(rune('a'+i%26))+time.Duration(i).String(), 1, time.Minute)
	}
	if l.Len() != 5000 {
		t.Fatalf("len=%d", l.Len())
	}
	now = now.Add(2 * time.Minute) // all windows and a sweep interval elapsed
	l.Allow("fresh", 1, time.Minute)
	if l.Len() != 1 {
		t.Fatalf("expired keys not evicted: len=%d", l.Len())
	}
}

func TestLimiterKeyCountIsCapped(t *testing.T) {
	l := NewLimiter()
	for i := 0; i < maxLimiterKeys+5000; i++ {
		l.Allow(time.Duration(i).String(), 1, time.Hour)
	}
	if l.Len() > maxLimiterKeys {
		t.Fatalf("key count %d exceeds cap %d", l.Len(), maxLimiterKeys)
	}
}

func TestLimiterExceededRecordReset(t *testing.T) {
	l := NewLimiter()
	if l.Exceeded("k", 2, time.Minute) {
		t.Fatal("empty key exceeded")
	}
	l.Record("k", time.Minute)
	if l.Exceeded("k", 2, time.Minute) {
		t.Fatal("exceeded after 1 of 2")
	}
	l.Record("k", time.Minute)
	if !l.Exceeded("k", 2, time.Minute) {
		t.Fatal("not exceeded after 2 of 2")
	}
	if l.Len() != 1 {
		t.Fatal("Exceeded must not create keys")
	}
	l.Reset("k")
	if l.Exceeded("k", 2, time.Minute) {
		t.Fatal("exceeded after reset")
	}
}
