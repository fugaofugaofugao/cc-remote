package session

import "testing"

func TestPortFromID(t *testing.T) {
	port, err := PortFromID("0000abcd")
	if err != nil {
		t.Fatal(err)
	}
	if port != 39000 {
		t.Fatalf("expected base port, got %d", port)
	}

	port, err = PortFromID("ffffabcd")
	if err != nil {
		t.Fatal(err)
	}
	if port < 39000 || port > 40000 {
		t.Fatalf("port outside expected range: %d", port)
	}
}

func TestPortFromIDRejectsShortID(t *testing.T) {
	if _, err := PortFromID("abc"); err == nil {
		t.Fatal("expected error for short session id")
	}
}
