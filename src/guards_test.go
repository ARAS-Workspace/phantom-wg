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
// guards_test.go — a panic below an export becomes an error return
// instead of unwinding into the cgo boundary (process abort), and a
// failure is recorded as the calling thread's last error.

package main

import (
	"errors"
	"runtime"
	"testing"
)

func TestGuardedCodePassthrough(t *testing.T) {
	if got := callGuardedCode("t", func() error { return nil }); got != wgOK {
		t.Fatalf("passthrough broken: %d", got)
	}
}

func TestGuardedCodePanicBecomesInternal(t *testing.T) {
	got := callGuardedCode("t", func() error { panic("boom") })
	if got != wgErrInternal {
		t.Fatalf("panic not converted: %d", got)
	}
}

func TestGuardedCodeNilMapPanic(t *testing.T) {
	// A realistic panic class, not just panic(): nil map write.
	got := callGuardedCode("t", func() error {
		var m map[string]int
		m["x"] = 1
		return nil
	})
	if got != wgErrInternal {
		t.Fatalf("nil map panic not converted: %d", got)
	}
}

func TestGuardedHandlePanicBecomesInternal(t *testing.T) {
	got := callGuardedHandle("t", func() (int64, error) { panic("boom") })
	if got != int64(wgErrInternal) {
		t.Fatalf("panic not converted: %d", got)
	}
}

func TestGuardedHandlePassthrough(t *testing.T) {
	if got := callGuardedHandle("t", func() (int64, error) { return 42, nil }); got != 42 {
		t.Fatalf("passthrough broken: %d", got)
	}
}

func TestGuardedStrPanicBecomesNil(t *testing.T) {
	s, ok := callGuardedStr("t", func() (string, error) { panic("boom") })
	if ok || s != "" {
		t.Fatalf("panic not converted: %q %v", s, ok)
	}
}

func TestGuardedStrPassthrough(t *testing.T) {
	s, ok := callGuardedStr("t", func() (string, error) { return "key", nil })
	if !ok || s != "key" {
		t.Fatalf("passthrough broken: %q %v", s, ok)
	}
}

func TestGuardedStrTypeAssertionPanic(t *testing.T) {
	// The registry's type assertion is the other realistic panic class.
	got := callGuardedCode("t", func() error {
		var v any = "not a device"
		_ = v.(*persistentDevice)
		return nil
	})
	if got != wgErrInternal {
		t.Fatalf("type assertion panic not converted: %d", got)
	}
}

// The record is the calling thread's, so each test below keeps its
// goroutine on one thread.

func TestCodeErrorIsReturnedAndRecorded(t *testing.T) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	got := callGuardedCode("t", func() error {
		return withCode(-5, errors.New("device handle 9 not found"))
	})
	code, msg, ok := getLastError()
	if got != -5 || !ok || code != -5 || msg != "device handle 9 not found" {
		t.Fatalf("returned %d, recorded %d %q %v", got, code, msg, ok)
	}
}

func TestErrorWithoutCodeIsInternal(t *testing.T) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	h := callGuardedHandle("t", func() (int64, error) { return 0, errors.New("random read: eof") })
	code, msg, ok := getLastError()
	if h != int64(wgErrInternal) || !ok || code != wgErrInternal || msg != "random read: eof" {
		t.Fatalf("returned %d, recorded %d %q %v", h, code, msg, ok)
	}
}

func TestPanicIsRecorded(t *testing.T) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	callGuardedStr("DerivePublicKey", func() (string, error) { panic("boom") })
	code, msg, ok := getLastError()
	if !ok || code != wgErrInternal || msg != "panic in DerivePublicKey: boom" {
		t.Fatalf("recorded %d %q %v", code, msg, ok)
	}
}

func TestSuccessClearsTheRecord(t *testing.T) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	callGuardedCode("t", func() error { return withCode(-4, errors.New("bad config")) })
	callGuardedStr("t", func() (string, error) { return "key", nil })
	if code, msg, ok := getLastError(); ok {
		t.Fatalf("record after a success: %d %q", code, msg)
	}
}
