package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadNewDataKeyNeverFromArgv(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if _, err := readNewDataKey(env(nil), strings.NewReader(""), false); err == nil || !strings.Contains(err.Error(), "never as an argument") {
		t.Fatalf("no source must fail: %v", err)
	}
	if k, _ := readNewDataKey(env(map[string]string{"OPENFAMILY_NEW_DATA_KEY": " abc "}), nil, false); k != "abc" {
		t.Fatalf("env: %q", k)
	}
	f := filepath.Join(t.TempDir(), "k")
	_ = os.WriteFile(f, []byte("fromfile\n"), 0o600)
	if k, _ := readNewDataKey(env(map[string]string{"OPENFAMILY_NEW_DATA_KEY_FILE": f}), nil, false); k != "fromfile" {
		t.Fatalf("file: %q", k)
	}
	if k, err := readNewDataKey(env(nil), strings.NewReader("fromstdin\nrest"), true); err != nil || k != "fromstdin" {
		t.Fatalf("stdin: %q %v", k, err)
	}
	if _, err := readNewDataKey(env(nil), strings.NewReader("\n"), true); err == nil {
		t.Fatal("empty stdin accepted")
	}
}
