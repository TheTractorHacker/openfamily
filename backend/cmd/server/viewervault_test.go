package main

import (
	"path/filepath"
	"testing"
)

func TestViewerVaultConfig(t *testing.T) {
	dir := t.TempDir()
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	for _, off := range []string{"off", "OFF", "false", "0", "no"} {
		if c := viewerVaultConfig(env(map[string]string{"E2EE_VIEWER_VAULT": off, "OPENFAMILY_SERVER_DEVICE_DIR": dir})); !c.Off || c.Pepper != nil {
			t.Fatalf("%q must switch the feature off: %+v", off, c)
		}
	}
	c := viewerVaultConfig(env(map[string]string{"OPENFAMILY_SERVER_DEVICE_DIR": dir}))
	if c.Off || len(c.Pepper) != 32 {
		t.Fatalf("default must be on with a pepper: %+v", c)
	}
	p := filepath.Join(dir, "own", "pepper")
	c2 := viewerVaultConfig(env(map[string]string{"E2EE_VIEWER_VAULT_PEPPER_FILE": p}))
	if len(c2.Pepper) != 32 || string(c2.Pepper) == string(c.Pepper) {
		t.Fatal("explicit pepper file not used")
	}
	bad := viewerVaultConfig(env(map[string]string{"E2EE_VIEWER_VAULT_PEPPER_FILE": "/proc/forbidden/pepper"}))
	if bad.Pepper != nil || bad.PepperErr == "" {
		t.Fatalf("unwritable pepper must disable the feature with a reason: %+v", bad)
	}
}
