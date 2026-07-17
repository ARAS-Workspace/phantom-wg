// ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
// ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
// ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
// ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
// ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
// ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
//
// Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
// Licensed under AGPL-3.0 - see LICENSE file for details
// Third-party licenses - see THIRD_PARTY_LICENSES file for details
// WireGuard® is a registered trademark of Jason A. Donenfeld.
//
// guards_test.go — proves a panic below an export becomes an error
// return instead of unwinding into the cgo boundary (process abort).

package main

import "testing"

func TestGuardedCodePassthrough(t *testing.T) {
	if got := callGuardedCode("t", func() int32 { return 7 }); got != 7 {
		t.Fatalf("passthrough broken: %d", got)
	}
}

func TestGuardedCodePanicBecomesInternal(t *testing.T) {
	got := callGuardedCode("t", func() int32 { panic("boom") })
	if got != wgErrInternal {
		t.Fatalf("panic not converted: %d", got)
	}
}

func TestGuardedCodeNilMapPanic(t *testing.T) {
	// A realistic panic class, not just panic(): nil map write.
	got := callGuardedCode("t", func() int32 {
		var m map[string]int
		m["x"] = 1
		return 0
	})
	if got != wgErrInternal {
		t.Fatalf("nil map panic not converted: %d", got)
	}
}

func TestGuardedHandlePanicBecomesInternal(t *testing.T) {
	got := callGuardedHandle("t", func() int64 { panic("boom") })
	if got != int64(wgErrInternal) {
		t.Fatalf("panic not converted: %d", got)
	}
}

func TestGuardedHandlePassthrough(t *testing.T) {
	if got := callGuardedHandle("t", func() int64 { return 42 }); got != 42 {
		t.Fatalf("passthrough broken: %d", got)
	}
}

func TestGuardedStrPanicBecomesNil(t *testing.T) {
	s, ok := callGuardedStr("t", func() (string, bool) { panic("boom") })
	if ok || s != "" {
		t.Fatalf("panic not converted: %q %v", s, ok)
	}
}

func TestGuardedStrPassthrough(t *testing.T) {
	s, ok := callGuardedStr("t", func() (string, bool) { return "key", true })
	if !ok || s != "key" {
		t.Fatalf("passthrough broken: %q %v", s, ok)
	}
}

func TestGuardedStrTypeAssertionPanic(t *testing.T) {
	// The registry's type assertion is the other realistic panic class.
	got := callGuardedCode("t", func() int32 {
		var v any = "not a device"
		_ = v.(*persistentDevice)
		return 0
	})
	if got != wgErrInternal {
		t.Fatalf("type assertion panic not converted: %d", got)
	}
}
