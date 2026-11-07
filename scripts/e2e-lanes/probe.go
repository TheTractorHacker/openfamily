// Command e2eprobe runs one read-only SQL statement against DATABASE_URL and
// prints the rows as a JSON array of arrays. It is copied into backend/cmd/_e2eprobe
// by scripts/e2e-lanes.sh for the build and removed again; it is test harness only.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: e2eprobe SQL")
		os.Exit(2)
	}
	ctx := context.Background()
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
