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
// guards.go — panic containment and the error record for the FFI export
// surface.
//
// A Go panic that unwinds into the cgo boundary aborts the entire host
// process — the daemon, and with it every client's tunnel. Each export
// therefore runs its body through one of the callGuarded* helpers. A
// helper clears the calling thread's last error, runs the body and,
// when the body returns an error or panics, records the code and the
// message as the thread's last error (lasterror.go); a panic is also
// logged with its stack to stderr. This file is pure Go (no cgo) so
// guards_test.go can run it with plain `go test`; the recovered panic
// can only cover code on the export's own goroutine — panics inside
// wireguard-go's internal goroutines are out of its reach.

package main

import (
	"errors"
	"fmt"
	"os"
	"runtime/debug"
)

// Mirror WG_OK and WG_ERR_INTERNAL in wireguard_go_bridge.h. exports.go
// carries a compile-time check so they cannot drift.
const (
	wgOK          int32 = 0
	wgErrInternal int32 = -99
)

// fail records err as the calling thread's last error and returns its
// code: the one withCode gave it, else WG_ERR_INTERNAL.
func fail(err error) int32 {
	code := wgErrInternal
	if ce, ok := errors.AsType[*codeError](err); ok {
		code = ce.code
	}
	setLastError(code, err.Error())
	return code
}

// recovered logs a panic recovered in export and records it as the
// calling thread's last error.
func recovered(export string, r any) int32 {
	_, _ = fmt.Fprintf(os.Stderr, "[wireguard-go-bridge] panic recovered in %s: %v\n%s",
		export, r, debug.Stack())
	setLastError(wgErrInternal, fmt.Sprintf("panic in %s: %v", export, r))
	return wgErrInternal
}

// callGuardedCode runs f; it returns WG_OK, or the code of f's error.
func callGuardedCode(export string, f func() error) (ret int32) {
	clearLastError()
	defer func() {
		if r := recover(); r != nil {
			ret = recovered(export, r)
		}
	}()
	if err := f(); err != nil {
		return fail(err)
	}
	return wgOK
}

// callGuardedHandle runs f; it returns f's handle, or the code of f's
// error.
func callGuardedHandle(export string, f func() (int64, error)) (ret int64) {
	clearLastError()
	defer func() {
		if r := recover(); r != nil {
			ret = int64(recovered(export, r))
		}
	}()
	h, err := f()
	if err != nil {
		return int64(fail(err))
	}
	return h
}

// callGuardedStr runs f; ok is false when f returns an error or panics,
// and the export returns NULL in that case.
func callGuardedStr(export string, f func() (string, error)) (s string, ok bool) {
	clearLastError()
	defer func() {
		if r := recover(); r != nil {
			recovered(export, r)
			s, ok = "", false
		}
	}()
	s, err := f()
	if err != nil {
		fail(err)
		return "", false
	}
	return s, true
}
