package errlog

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
)

func TestRingKeepsNewestFirst(t *testing.T) {
	r := NewRing(3)
	for _, m := range []string{"a", "b", "c", "d"} {
		r.Add(Entry{Message: m})
	}
	got := r.Recent(10)
	if len(got) != 3 || got[0].Message != "d" || got[2].Message != "b" {
		t.Fatalf("got %+v", got)
	}
	if n := len(r.Recent(1)); n != 1 {
		t.Fatalf("limit not honoured: %d", n)
	}
}

func TestWrapRecordsOnlyWarnAndAboveWithoutAttrs(t *testing.T) {
	var buf bytes.Buffer
	r := NewRing(10)
	l := slog.New(Wrap(slog.NewTextHandler(&buf, nil), r))
	l.Info("fine", "k", "v")
	l.Warn("careful", "secret", "hunter2")
	l.Error("broken")
	got := r.Recent(10)
	if len(got) != 2 || got[0].Message != "broken" || got[1].Level != "WARN" {
		t.Fatalf("got %+v", got)
	}
	if strings.Contains(got[1].Message, "hunter2") {
		t.Fatal("attributes must not be retained")
	}
	if !strings.Contains(buf.String(), "fine") {
		t.Fatal("record not forwarded to the wrapped handler")
	}
}
