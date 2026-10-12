// Validate against Docker's published v2 parser without requiring a Docker login.
package main

import (
	"fmt"
	"os"

	"github.com/docker/sbx-kits-contrib/spec"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: validator KIT_DIRECTORY...")
		os.Exit(2)
	}
	failed := false
	for _, path := range os.Args[1:] {
		artifact, err := spec.LoadFromDirectory(path)
		if err == nil {
			err = spec.ValidateArtifact(artifact)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "FAIL %s: %v\n", path, err)
			failed = true
		} else {
			fmt.Printf("PASS %s\n", path)
		}
	}
	if failed {
		os.Exit(1)
	}
}
