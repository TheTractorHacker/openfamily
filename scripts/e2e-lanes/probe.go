// Command e2eprobe runs ONE SQL statement against DATABASE_URL and prints the rows as a JSON array of
// arrays. The statement can be a write: the end-to-end tests use it for deliberate plumbing (backdating a
// timestamp to test a time window, creating a scratch table). So it refuses any database that is not on
// this machine (loopback host or a unix socket); a mis-set DATABASE_URL (a sourced production .env, say)
// must never reach a real database. It is copied into backend/cmd/_e2eprobe by scripts/e2e-lanes.sh and
// scripts/dev/dev-stack.sh for the build and removed again; it is test harness only.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"

	"github.com/jackc/pgx/v5"
)

// local reports whether a pgx host is this machine: a unix socket directory, localhost or a loopback address.
func local(host string) bool {
	if host == "" || strings.HasPrefix(host, "/") || strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: e2eprobe SQL")
		os.Exit(2)
	}
	ctx := context.Background()
	cfg, err := pgx.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "e2eprobe: DATABASE_URL:", err)
		os.Exit(2)
	}
	hosts := []string{cfg.Host}
	for _, fb := range cfg.Fallbacks {
		hosts = append(hosts, fb.Host)
	}
	for _, h := range hosts {
		if !local(h) {
			fmt.Fprintf(os.Stderr, "e2eprobe: refusing database host %q: only loopback / unix-socket hosts are allowed (this tool writes)\n", h)
			os.Exit(2)
		}
	}
	conn, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer conn.Close(ctx)
	rows, err := conn.Query(ctx, os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer rows.Close()
	out := [][]any{}
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		out = append(out, vals)
	}
	if rows.Err() != nil {
		fmt.Fprintln(os.Stderr, rows.Err())
		os.Exit(1)
	}
	_ = json.NewEncoder(os.Stdout).Encode(out)
}
