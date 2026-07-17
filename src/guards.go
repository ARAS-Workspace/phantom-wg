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
// guards.go — panic containment for the FFI export surface.
//
// A Go panic that unwinds into the cgo boundary aborts the entire host
// process — the daemon, and with it every client's tunnel. Each export
// therefore runs its body through one of the callGuarded* helpers,
// which convert a panic into an error return and log the stack to
// stderr. This file is pure Go (no cgo) so guards_test.go can prove
// the recovery behavior with plain `go test`; the recovered panic can
// only cover code on the export's own goroutine — panics inside
// wireguard-go's internal goroutines are out of its reach.

package main

import (
	"fmt"
	"os"
	"runtime/debug"
)

// Mirrors WG_ERR_INTERNAL in wireguard_go_bridge.h. exports.go carries
// a compile-time check so the two cannot drift.
const wgErrInternal int32 = -99

func logPanic(export string, r any) {
	fmt.Fprintf(os.Stderr, "[wireguard-go-bridge] panic recovered in %s: %v\n%s",
		export, r, debug.Stack())
}

// callGuardedCode runs f, converting a panic into WG_ERR_INTERNAL.
func callGuardedCode(export string, f func() int32) (ret int32) {
	defer func() {
		if r := recover(); r != nil {
			logPanic(export, r)
			ret = wgErrInternal
		}
	}()
	return f()
}

// callGuardedHandle is callGuardedCode for int64 handle-or-error returns.
func callGuardedHandle(export string, f func() int64) (ret int64) {
	defer func() {
		if r := recover(); r != nil {
			logPanic(export, r)
			ret = int64(wgErrInternal)
		}
	}()
	return f()
}

// callGuardedStr runs f, converting a panic into ("", false); the
// export returns NULL to its caller in that case.
func callGuardedStr(export string, f func() (string, bool)) (s string, ok bool) {
	defer func() {
		if r := recover(); r != nil {
			logPanic(export, r)
			s, ok = "", false
		}
	}()
	return f()
}
