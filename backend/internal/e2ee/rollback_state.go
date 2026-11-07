package e2ee

import "fmt"

// RollbackState is the serializable form of a RollbackGuard, so a long-running
// verifier (the sidecar) keeps the per-line rollback rule across restarts.
type RollbackState struct {
	First map[string]int64  `json:"first,omitempty"` // "line:gen" -> first seen (ms)
	High  map[string]uint32 `json:"high,omitempty"`  // "line" -> highest generation
	Dev   map[string]uint32 `json:"dev,omitempty"`   // device+line -> highest generation accepted
}

// State exports the guard.
func (g *RollbackGuard) State() RollbackState {
	s := RollbackState{First: map[string]int64{}, High: map[string]uint32{}, Dev: map[string]uint32{}}
	for l, m := range g.first {
		for gen, ms := range m {
			s.First[fmt.Sprintf("%d:%d", l, gen)] = ms
		}
	}
	for l, gen := range g.high {
		s.High[fmt.Sprintf("%d", l)] = gen
	}
	for k, gen := range g.dev {
		s.Dev[k] = gen
	}
	return s
}

// RestoreRollbackGuard rebuilds a guard from State(). Malformed keys are dropped.
func RestoreRollbackGuard(s RollbackState) *RollbackGuard {
	g := NewRollbackGuard()
	for k, ms := range s.First {
		var l, gen uint32
		if n, err := fmt.Sscanf(k, "%d:%d", &l, &gen); err == nil && n == 2 && Line(l).Valid() {
			if g.first[Line(l)] == nil {
				g.first[Line(l)] = map[uint32]int64{}
			}
			g.first[Line(l)][gen] = ms
		}
	}
	for k, gen := range s.High {
		var l uint32
		if n, err := fmt.Sscanf(k, "%d", &l); err == nil && n == 1 && Line(l).Valid() {
			g.high[Line(l)] = gen
		}
	}
	for k, gen := range s.Dev {
		g.dev[k] = gen
	}
	return g
}
