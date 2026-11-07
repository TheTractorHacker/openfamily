// Command compat-contract prints the API field list ("Struct.jsontag") of a
// backend source tree, for recording the contract of a release:
//
//	git archive v0.20.1 backend | tar -x -C /tmp/v0.20.1
//	go run ./cmd/compat-contract /tmp/v0.20.1/backend > internal/compat/testdata/contract/v0.20.1.txt
package main

import (
	"fmt"
	"os"

	"github.com/TheTractorHacker/openfamily/backend/internal/compat"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: compat-contract <backend dir>")
		os.Exit(2)
	}
	tags, err := compat.ScanContract(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	for _, t := range tags {
		fmt.Println(t)
	}
}
