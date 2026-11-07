package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/atrest"
	"github.com/TheTractorHacker/openfamily/backend/internal/config"
	"github.com/TheTractorHacker/openfamily/backend/internal/db"
)

// runDataKey implements `server data-key generate|rewrap`.
//
//	server data-key generate            print a new random OPENFAMILY_DATA_KEY
//	server data-key rewrap NEWKEY       re-wrap the stored data key from the
//	                                    current OPENFAMILY_DATA_KEY to NEWKEY
//
// Rotation: generate a key, store it safely OUTSIDE the server, run rewrap with
// the OLD key in the environment, then switch the environment to the new key.
// Values are not re-encrypted (the inner data key stays), so it is instant.
func runDataKey(cfg config.Config, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: server data-key generate | server data-key rewrap NEW_KEY")
		return 2
	}
	switch args[0] {
	case "generate":
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			fmt.Fprintln(os.Stderr, "no randomness:", err)
			return 1
		}
		fmt.Println(base64.StdEncoding.EncodeToString(b))
		return 0
	case "rewrap":
		if len(args) != 2 {
			fmt.Fprintln(os.Stderr, "usage: server data-key rewrap NEW_KEY")
			return 2
		}
		oldSecret, err := atrest.EnvSecret()
		if err != nil || strings.TrimSpace(oldSecret) == "" {
			fmt.Fprintln(os.Stderr, "the CURRENT key must be in OPENFAMILY_DATA_KEY (or OPENFAMILY_DATA_KEY_FILE) while you run this")
			return 1
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		pool, err := db.Connect(ctx, cfg.DatabaseURL)
		if err != nil {
			fmt.Fprintln(os.Stderr, "database connection failed:", err)
			return 1
		}
		defer pool.Close()
		if err := atrest.Rewrap(ctx, pool, oldSecret, args[1]); err != nil {
			fmt.Fprintln(os.Stderr, "rewrap failed:", err)
			return 1
		}
		fmt.Println("done. Now set OPENFAMILY_DATA_KEY to the new key, restart the server, and keep a copy of the new key outside the server.")
		return 0
	}
	fmt.Fprintln(os.Stderr, "unknown command")
	return 2
}
