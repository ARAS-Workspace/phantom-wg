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
// lasterror_test.go — each thread reads the record of its own last call.

package main

import (
	"errors"
	"fmt"
	"runtime"
	"testing"
)

func TestLastErrorIsPerThread(t *testing.T) {
	// Two goroutines, each locked to its own thread: one fails, then
	// the other succeeds, and the first still reads its own failure.
	failed, succeeded, done := make(chan struct{}), make(chan struct{}), make(chan error)
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		callGuardedCode("a", func() error { return withCode(-5, errors.New("device handle 9 not found")) })
		close(failed)
		<-succeeded
		code, msg, ok := getLastError()
		if !ok || code != -5 || msg != "device handle 9 not found" {
			done <- fmt.Errorf("first thread reads %d %q %v", code, msg, ok)
			return
		}
		done <- nil
	}()
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		<-failed
		callGuardedCode("b", func() error { return nil })
		close(succeeded)
	}()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
