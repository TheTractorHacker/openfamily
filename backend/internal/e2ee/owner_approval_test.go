package e2ee

import (
	"encoding/hex"
	"testing"
)

// The same vector is checked by the Dart client (e2ee_owner_approval_test.dart).
func TestOwnerApprovalRefVector(t *testing.T) {
	const c, u = "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
	off, err := OwnerApprovalRef(c, u, false)
	if err != nil {
		t.Fatal(err)
	}
	on, _ := OwnerApprovalRef(c, u, true)
	if hex.EncodeToString(off) != "eac3341d0c0f79c9b0f4b470cd77eb7f386450f4d446af5c45aad3caee654ea3" ||
		hex.EncodeToString(on) != "ea645725ab2e3c584928d151d346ccef83c662078f3ef68dde7fc19a62035b22" {
		t.Fatalf("vector changed: off=%x on=%x", off, on)
	}
	if _, err := OwnerApprovalRef("x", u, true); err == nil {
		t.Fatal("bad circle id accepted")
	}
	if _, err := LogActionMessage(ActOwnerApproval, u, u, c, "", 0, on); err != nil {
		t.Fatal(err)
	}
}
