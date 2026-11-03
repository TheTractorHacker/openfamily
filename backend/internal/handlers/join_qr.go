package handlers

import (
	"fmt"
	"html/template"
	"strings"

	"github.com/boombuler/barcode/qr"
)

// qrSVG renders text as an inline SVG QR code on a white tile (so it scans in
// dark mode too). It returns an empty value if encoding fails, in which case
// the page simply omits the code. The input is only ever a validated origin
// plus a well-formed invite code.
func qrSVG(text string) template.HTML {
	code, err := qr.Encode(text, qr.M, qr.Auto)
	if err != nil {
		return ""
	}
	n := code.Bounds().Dx()
	const quiet = 2
	var path strings.Builder
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			r, _, _, _ := code.At(x, y).RGBA()
			if r == 0 {
				fmt.Fprintf(&path, "M%d %dh1v1h-1z", x+quiet, y+quiet)
			}
		}
	}
	size := n + 2*quiet
	return template.HTML(fmt.Sprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" role="img" aria-label="QR code for this invite page" shape-rendering="crispEdges"><rect width="%d" height="%d" fill="#fff"/><path d="%s" fill="#000"/></svg>`,
		size, size, size, size, path.String()))
}
