// Command migrate applies all database migrations to DATABASE_URL (or the URL
// in TEST_DATABASE_URL when DATABASE_URL is empty) and exits. CI uses it to
// prepare the database the DB-backed tests (authorization matrix, circles,
// alerts, ...) run against; the server migrates itself at startup.
package main

import (
	"fmt"
	"os"

	"github.com/TheTractorHacker/openfamily/backend/internal/db"
)

func main() {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		url = os.Getenv("TEST_DATABASE_URL")
	}
	if url == "" {
		fmt.Fprintln(os.Stderr, "migrate: DATABASE_URL (or TEST_DATABASE_URL) is not set")
		os.Exit(2)
	}
	if err := db.Migrate(url); err != nil {
		fmt.Fprintln(os.Stderr, "migrate:", err)
		os.Exit(1)
	}
	fmt.Println("migrations applied")
}
