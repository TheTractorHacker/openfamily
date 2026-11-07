package main

import (
	"bufio"
	"context"
	"errors"
	"io"
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

// readNewDataKey takes the NEW key from the environment (OPENFAMILY_NEW_DATA_KEY or
// OPENFAMILY_NEW_DATA_KEY_FILE) or, with --stdin, from one line of standard input. It is never
// accepted as a command-line argument: argv shows up in process listings and shell history.
func readNewDataKey(getenv func(string) string, stdin io.Reader, useStdin bool) (string, error) {
	switch {
	case useStdin:
		line, err := bufio.NewReader(io.LimitReader(stdin, 4096)).ReadString('\n')
		if err != nil && err != io.EOF {
			return "", err
		}
		k := strings.TrimSpace(line)
		if k == "" {
			return "", errors.New("no key on standard input")
		}
		return k, nil
	case strings.TrimSpace(getenv("OPENFAMILY_NEW_DATA_KEY_FILE")) != "":
		b, err := os.ReadFile(strings.TrimSpace(getenv("OPENFAMILY_NEW_DATA_KEY_FILE")))
		if err != nil {
			return "", fmt.Errorf("OPENFAMILY_NEW_DATA_KEY_FILE: %w", err)
		}
		return strings.TrimSpace(string(b)), nil
	case strings.TrimSpace(getenv("OPENFAMILY_NEW_DATA_KEY")) != "":
		return strings.TrimSpace(getenv("OPENFAMILY_NEW_DATA_KEY")), nil
	}
	return "", errors.New("give the new key with OPENFAMILY_NEW_DATA_KEY, OPENFAMILY_NEW_DATA_KEY_FILE or --stdin (never as an argument)")
}

// runDataKey implements `server data-key generate|rewrap`.
//
//	server data-key generate         print a new random key
//	server data-key rewrap [--stdin] re-wrap the stored data key from the current
//	                                 OPENFAMILY_DATA_KEY to the new key (see readNewDataKey)
//
// No secret is ever read from argv. Rotation: generate a key, store it safely OUTSIDE the
// server, run rewrap with the OLD key in OPENFAMILY_DATA_KEY and the new one in
// OPENFAMILY_NEW_DATA_KEY, then switch the environment to the new key. Values are not
// re-encrypted (the inner data key stays), so it is instant.
func runDataKey(cfg config.Config, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: server data-key generate | server data-key rewrap [--stdin]")
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
		useStdin := false
		for _, a := range args[1:] {
			if a != "--stdin" {
				fmt.Fprintln(os.Stderr, "usage: server data-key rewrap [--stdin]  (the new key is never an argument)")
				return 2
			}
			useStdin = true
		}
		newSecret, err := readNewDataKey(os.Getenv, os.Stdin, useStdin)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
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
		if err := atrest.Rewrap(ctx, pool, oldSecret, newSecret); err != nil {
			fmt.Fprintln(os.Stderr, "rewrap failed:", err)
			return 1
		}
		fmt.Println("done. Now set OPENFAMILY_DATA_KEY to the new key, restart the server, and keep a copy of the new key outside the server.")
		return 0
	}
	fmt.Fprintln(os.Stderr, "unknown command")
	return 2
}
