package cli

import (
	"encoding/json"
	"io"
)

// printJSON encodes v as indented JSON. Returns 1 on error.
func printJSON(w io.Writer, v any) int {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return 1
	}
	return 0
}
