package compat

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
)

// ScanContract lists every "Struct.jsontag" declared by a named struct type in
// the API packages under root (a backend directory: it reads
// internal/handlers and internal/models, skipping tests). The list recorded
// for each released tag lives in internal/compat/testdata/contract; a test
// fails when a field an in-window app version could read disappears
// (docs/api-compat.md, "Additive changes only").
func ScanContract(root string) ([]string, error) {
	set := map[string]bool{}
	for _, pkg := range []string{"internal/handlers", "internal/models"} {
		dir := filepath.Join(root, pkg)
		fset := token.NewFileSet()
		pkgs, err := parser.ParseDir(fset, dir, func(fi fs.FileInfo) bool {
			return !strings.HasSuffix(fi.Name(), "_test.go")
		}, 0)
		if err != nil {
			return nil, err
		}
		for _, p := range pkgs {
			for _, f := range p.Files {
				for _, d := range f.Decls {
					gd, ok := d.(*ast.GenDecl)
					if !ok {
						continue
					}
					for _, sp := range gd.Specs {
						ts, ok := sp.(*ast.TypeSpec)
						if !ok {
							continue
						}
						st, ok := ts.Type.(*ast.StructType)
						if !ok {
							continue
						}
						for _, fld := range st.Fields.List {
							if fld.Tag == nil {
								continue
							}
							raw := strings.Trim(fld.Tag.Value, "`")
							name := strings.Split(reflect.StructTag(raw).Get("json"), ",")[0]
							if name == "" || name == "-" {
								continue
							}
							set[ts.Name.Name+"."+name] = true
						}
					}
				}
			}
		}
	}
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out, nil
}
