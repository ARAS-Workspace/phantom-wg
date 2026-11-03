package core

import "testing"

func TestTakeGivesTheObjectOnce(t *testing.T) {
	r := NewHandleRegistry()
	h := r.Add("device")
	if obj, ok := r.Take(h); !ok || obj != "device" {
		t.Fatalf("first Take: %v %v", obj, ok)
	}
	if obj, ok := r.Take(h); ok {
		t.Fatalf("second Take got %v", obj)
	}
	if _, ok := r.Get(h); ok {
		t.Fatal("handle still registered after Take")
	}
}
