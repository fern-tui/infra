// Command zcm cleans up disk space used by the Zig compiler's build cache.
package main

import (
	"os"

	"zig-cache-manager/internal/cli"
)

func main() {
	os.Exit(cli.Run(cli.Env{
		Args:   os.Args[1:],
		Stdout: os.Stdout,
		Stderr: os.Stderr,
		Stdin:  os.Stdin,
	}))
}
