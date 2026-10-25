package handlers

import (
	"strings"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

func TestValidateAdminUserInput(t *testing.T) {
	valid, err := validateAdminUserInput(" frank@example.com ", "strong-password", " Frank ", models.RoleMember)
	if err != nil {
		t.Fatalf("valid input rejected: %v", err)
	}
	if valid.Email != "frank@example.com" || valid.Name != "Frank" {
		t.Fatalf("input was not normalized: %+v", valid)
	}

	cases := []struct {
		name     string
		email    string
		password string
		username string
		role     models.Role
	}{
		{"blank email", " ", "strong-password", "Frank", models.RoleMember},
		{"invalid email", "not-an-email", "strong-password", "Frank", models.RoleMember},
		{"short password", "frank@example.com", "short", "Frank", models.RoleMember},
		{"blank name", "frank@example.com", "strong-password", " ", models.RoleMember},
		{"invalid role", "frank@example.com", "strong-password", "Frank", models.Role("owner")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := validateAdminUserInput(tc.email, tc.password, tc.username, tc.role); err == nil {
				t.Fatalf("accepted invalid input")
			}
		})
	}
}

func TestStringPtrEqual(t *testing.T) {
	a := "family-a"
	b := "family-a"
	c := "family-c"
	if !stringPtrEqual(nil, nil) {
		t.Fatal("nil, nil should be equal")
	}
	if stringPtrEqual(&a, nil) || stringPtrEqual(nil, &a) {
		t.Fatal("nil vs value should not be equal")
	}
	if !stringPtrEqual(&a, &b) {
		t.Fatal("same value should be equal")
	}
	if stringPtrEqual(&a, &c) {
		t.Fatal("different values should not be equal")
	}
}

func TestValidateAdminUserInputRejectsOversizedName(t *testing.T) {
	if _, err := validateAdminUserInput("frank@example.com", "strong-password", strings.Repeat("x", 121), models.RoleMember); err == nil {
		t.Fatal("accepted oversized name")
	}
}
