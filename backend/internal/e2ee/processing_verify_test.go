package e2ee

import (
	"bytes"
	"encoding/base64"
	"testing"
)

func TestRollbackStateRoundTrip(t *testing.T) {
	g := NewRollbackGuard()
	_ = g.Observe(LineServer, 2, 1000)
	if err := g.Check(LineServer, 2, "dev-a", 1500, 2000); err != nil {
		t.Fatal(err)
	}
	_ = g.Observe(LineServer, 3, 5000)
	g2 := RestoreRollbackGuard(g.State())
	// after the grace, a gen-2 item signed after gen 3 appeared is refused, by both guards
	now := int64(5000 + defaultGraceMs + 1)
	for i, x := range []*RollbackGuard{g, g2} {
		if err := x.Check(LineServer, 2, "dev-a", 6000, now); err == nil {
			t.Fatalf("guard %d accepted a rolled-back item", i)
		}
		// the phone line is independent
		if err := x.Check(LinePhone, 1, "dev-a", 6000, now); err != nil {
			t.Fatalf("guard %d: phone line affected: %v", i, err)
		}
	}
	// garbage keys are dropped, not trusted
	g3 := RestoreRollbackGuard(RollbackState{First: map[string]int64{"x": 1, "9:1": 5}, High: map[string]uint32{"7": 9}})
	if len(g3.high) != 0 || len(g3.first) != 0 {
		t.Fatal("malformed state restored")
	}
}

func TestCheckSKIndependent(t *testing.T) {
	circle := "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
	ck, sk := bytes.Repeat([]byte{0x42}, 32), bytes.Repeat([]byte{0x5a}, 32)
	commit, _ := KeyCommitment(ck, circle, 3)
	recs := []EpochRecord{{Epoch: 3, KeyCommitment: base64.StdEncoding.EncodeToString(commit)}}
	if err := CheckSKIndependent(sk, circle, [][]byte{ck}, recs); err != nil {
		t.Fatalf("independent key refused: %v", err)
	}
	if CheckSKIndependent(ck, circle, [][]byte{ck}, nil) == nil {
		t.Fatal("SK equal to a held CK accepted")
	}
	if CheckSKIndependent(ck, circle, nil, recs) == nil {
		t.Fatal("SK with a CK epoch commitment accepted")
	}
}
