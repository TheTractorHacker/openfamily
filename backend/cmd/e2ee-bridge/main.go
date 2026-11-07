// Command e2ee-bridge is the standalone sidecar: a circle member device that
// exports Private circles to Dawarich, or acts as the OpenFamily server's own
// device. The logic lives in internal/e2eebridge, shared with the API's
// built-in server device. See README.md.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2eebridge"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	os.Exit(e2eebridge.Main(ctx, os.Args[1:], os.Getenv, os.Stdin, os.Stdout, os.Stderr))
}
