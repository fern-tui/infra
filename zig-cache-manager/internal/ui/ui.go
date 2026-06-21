// Package ui renders zcm's terminal output: colored status messages and
// aligned tables. Color is disabled when NO_COLOR is set, stdout is not a
// terminal, or --no-color is passed.
package ui

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

// ANSI SGR codes.
const (
	codeReset  = "\033[0m"
	codeBold   = "\033[1m"
	codeDim    = "\033[2m"
	codeRed     = "\033[31m"
	codeGreen   = "\033[32m"
	codeYellow  = "\033[33m"
	codeBlue    = "\033[34m"
	codeMagenta = "\033[35m"
	codeCyan    = "\033[36m"
	codeGray    = "\033[90m"
)

type Align int

const (
	AlignLeft Align = iota
	AlignRight
)

type Column struct {
	Header string
	Align  Align
}

// UI holds output streams and color preference for one invocation.
type UI struct {
	Out   io.Writer
	Err   io.Writer
	Color bool
	in    *bufio.Reader
}

// New creates a UI. Color enabled when stdout is a terminal and NO_COLOR is unset.
func New(out, errOut io.Writer, in io.Reader, noColor bool) *UI {
	color := !noColor && os.Getenv("NO_COLOR") == "" && isTerminal(out)
	return &UI{Out: out, Err: errOut, Color: color, in: bufio.NewReader(in)}
}

func isTerminal(w io.Writer) bool {
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	info, err := f.Stat()
	if err != nil {
		return false
	}
	return (info.Mode() & os.ModeCharDevice) != 0
}

// visibleLen counts printable characters in s, skipping ANSI SGR sequences.
func visibleLen(s string) int {
	n := 0
	inSeq := false
	for i := 0; i < len(s); i++ {
		if s[i] == '\033' {
			inSeq = true
			continue
		}
		if inSeq {
			if s[i] == 'm' {
				inSeq = false
			}
			continue
		}
		n++
	}
	return n
}

// IsInputInteractive reports whether stdin is a terminal.
func IsInputInteractive() bool {
	return isTerminal(os.Stdin)
}

func (u *UI) paint(code, s string) string {
	if !u.Color || code == "" {
		return s
	}
	return code + s + codeReset
}

// kvLabelWidth is the KV key column width.
const kvLabelWidth = 16

func (u *UI) Header(msg string) {
	fmt.Fprintf(u.Out, "\n%s %s\n", u.paint(codeBlue, "::"), u.paint(codeGray, msg))
}

// CacheHeader prints the structured list header:
//
//	:: <label> — <path> (<count> entries, <size>)
func (u *UI) CacheHeader(label, path string, count int, size string) {
	fmt.Fprintf(u.Out, "\n%s %s %s %s %s\n",
		    u.paint(codeBlue, "::"),
		    u.paint(codeBold, label),
		    u.paint(codeGray, "—"),
		    u.paint(codeCyan, path),
		    u.paint(codeYellow, fmt.Sprintf("(%d entries, %s)", count, size)),
	)
}

func (u *UI) KV(key, val string) {
	label := key + ":"
	fmt.Fprintf(u.Out, "  %s %s\n", u.paint(codeGray, pad(label, kvLabelWidth, AlignLeft)), val)
}

func (u *UI) Hint(msg string) {
	fmt.Fprintf(u.Out, "\n  %s\n", u.paint(codeDim, msg))
}

func (u *UI) Success(msg string) {
	fmt.Fprintf(u.Out, "\n  %s %s\n", u.paint(codeGreen, "✓"), msg)
}

func (u *UI) Warn(msg string) {
	fmt.Fprintf(u.Out, "\n  %s %s\n", u.paint(codeYellow, "!"), msg)
}

func (u *UI) Error(msg string) {
	fmt.Fprintf(u.Err, "\n  %s %s\n", u.paint(codeRed, "✗"), msg)
}

// Table is an aligned table. FootRule draws a rule before the last row.
type Table struct {
	Columns  []Column
	Rows     [][]string
	FootRule bool
	RowColor func(row int) string
}

// Render writes the table to the UI's output stream.
func (u *UI) Render(t Table) {
	widths := make([]int, len(t.Columns))
	for i, col := range t.Columns {
		widths[i] = len([]rune(col.Header))
	}
	for _, row := range t.Rows {
		for i, cell := range row {
			if i >= len(widths) {
				continue
			}
			if n := visibleLen(cell); n > widths[i] {
				widths[i] = n
			}
		}
	}

	var header strings.Builder
	for i, col := range t.Columns {
		header.WriteString(cellText(col.Header, widths[i], col.Align, i == len(t.Columns)-1))
		if i < len(t.Columns)-1 {
			header.WriteString("  ")
		}
	}
	fmt.Fprintf(u.Out, "  %s\n", u.paint(codeBold, header.String()))

	totalWidth := 0
	for i, w := range widths {
		totalWidth += w
		if i < len(widths)-1 {
			totalWidth += 2
		}
	}
	fmt.Fprintf(u.Out, "  %s\n", u.paint(codeGray, strings.Repeat("─", totalWidth)))

	for i, row := range t.Rows {
		if t.FootRule && i == len(t.Rows)-1 {
			fmt.Fprintf(u.Out, "  %s\n", u.paint(codeGray, strings.Repeat("─", totalWidth)))
		}
		var line strings.Builder
		for c, col := range t.Columns {
			cell := ""
			if c < len(row) {
				cell = row[c]
			}
			line.WriteString(cellText(cell, widths[c], col.Align, c == len(t.Columns)-1))
			if c < len(t.Columns)-1 {
				line.WriteString("  ")
			}
		}
		code := ""
		if t.RowColor != nil {
			code = t.RowColor(i)
		}
		// Always terminate with a hard reset so no color leaks into the next row,
		// regardless of whether individual cells closed their own sequences.
		if u.Color {
			fmt.Fprintf(u.Out, "  %s%s\n", u.paint(code, line.String()), codeReset)
		} else {
			fmt.Fprintf(u.Out, "  %s\n", line.String())
		}
	}
}

// cellText pads a cell to width, except a left-aligned final column is left
// unpadded so rows don't end in invisible trailing whitespace.
func cellText(s string, width int, align Align, isLast bool) string {
	if isLast && align == AlignLeft {
		return s
	}
	return pad(s, width, align)
}

func pad(s string, width int, align Align) string {
	n := visibleLen(s)
	if n >= width {
		return s
	}
	gap := strings.Repeat(" ", width-n)
	if align == AlignRight {
		return gap + s
	}
	return s + gap
}

func (u *UI) Dim(s string) string { return u.paint(codeGray, s) }

func (u *UI) Cyan(s string) string { return u.paint(codeCyan, s) }

func (u *UI) Yellow(s string) string { return u.paint(codeYellow, s) }

func (u *UI) Green(s string) string { return u.paint(codeGreen, s) }

func (u *UI) Red(s string) string { return u.paint(codeRed, s) }

func (u *UI) Gray(s string) string { return u.paint(codeGray, s) }

func (u *UI) Bold(s string) string { return u.paint(codeBold, s) }

// EntryPath renders "bucket/name" with the bucket prefix colored by type.
func (u *UI) EntryPath(bucket, name string) string {
	if !u.Color {
		return bucket + "/" + name
	}

	// Bucket prefix color:
	//   o/ p/  -> cyan     (build artifacts, packages)
	//   h/     -> blue     (cache-hash manifests)
	//   z/     -> magenta  (ZIR incremental cache)
	//   tmp/   -> yellow   (leftover from crashed runs)
	//   other  -> gray
	var prefixCode string
	switch bucket {
		case "o", "p":
			prefixCode = codeCyan
		case "h":
			prefixCode = codeBlue
		case "z":
			prefixCode = codeMagenta
		case "tmp":
			prefixCode = codeYellow
		default:
			prefixCode = codeGray
	}
	prefix := u.paint(prefixCode, bucket+"/")

	// Only the extension is dimmed; paint() appends codeReset so there's no bleed.
	if dot := strings.LastIndexByte(name, '.'); dot >= 0 {
		stem := name[:dot]
		ext := name[dot:]
		return prefix + stem + u.paint(codeGray, ext)
	}
	return prefix + name
}

// AgeColor colors s by how old the entry is:
//
//	< 1d  -> green   (fresh)
//	1–7d  -> yellow  (aging)
//	> 7d  -> red     (stale)
func (u *UI) AgeColor(s string, age time.Duration) string {
	switch {
		case age < 24*time.Hour:
			return u.paint(codeGreen, s)
		case age < 7*24*time.Hour:
			return u.paint(codeYellow, s)
		default:
			return u.paint(codeRed, s)
	}
}

// Confirm prompts for y/n. Only "y" or "yes" returns true; blank/EOF = false.
func (u *UI) Confirm(prompt string) bool {
	fmt.Fprintf(u.Out, "  %s %s ", u.paint(codeYellow, "?"), prompt)
	line, err := u.in.ReadString('\n')
	if err != nil && line == "" {
		fmt.Fprintln(u.Out)
		return false
	}
	answer := strings.ToLower(strings.TrimSpace(line))
	return answer == "y" || answer == "yes"
}
