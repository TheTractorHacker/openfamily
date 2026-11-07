package handlers

import (
	"io/fs"
	"net/http"
	"path"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/web"
)

// docsFS is the documentation embedded in the binary (backend/web/docs).
var docsFS = func() fs.FS {
	sub, err := fs.Sub(web.Docs, "docs")
	if err != nil {
		panic(err)
	}
	return sub
}()

var docsTypes = map[string]string{
	".md":   "text/plain; charset=utf-8",
	".json": "application/json",
	".png":  "image/png",
	".webp": "image/webp",
	".jpg":  "image/jpeg",
	".jpeg": "image/jpeg",
}

// DocsContent serves the embedded documentation: GET /api/docs/manifest.json,
// /api/docs/user/chat.md, /api/docs/images/web/dashboard.png ...
//
// It sits behind RequireAuth (any signed-in user, not only platform admins).
// The docs are public on GitHub and hold no secrets, but serving them only to
// signed-in people keeps a bare server from advertising its version and
// feature set, and the admin web fetches images with its bearer token. It is a
// read-only lookup in an embedded filesystem: no path ever reaches the disk.
func (s *Server) DocsContent(w http.ResponseWriter, r *http.Request) {
	name := path.Clean(strings.TrimPrefix(chi.URLParam(r, "*"), "/"))
	ct, ok := docsTypes[strings.ToLower(path.Ext(name))]
	if name == "." || strings.HasPrefix(name, "..") || !ok {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	data, err := fs.ReadFile(docsFS, name)
	if err != nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	h := w.Header()
	h.Set("Content-Type", ct)
	h.Set("Cache-Control", "private, max-age=300")
	h.Set("X-Content-Type-Options", "nosniff")
	_, _ = w.Write(data)
}
