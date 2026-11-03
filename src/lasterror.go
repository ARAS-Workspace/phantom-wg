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
// lasterror.go — the calling thread's last error. Every guarded export
// clears the record of the thread that calls it and, when it fails,
// writes the code it returns and the message of its error; LastError
// reads the record and leaves it in place, as errno is read.
//
// A cgo export runs on the thread of its C caller, so a record is kept
// under that thread's id (thread_id.go): ctypes releases the GIL during a
// call, and two Python threads that call at once each read the record of
// their own call.

package main

import "sync"

type lastErr struct {
	code int32
	msg  string
}

var (
	lastErrMu sync.Mutex
	lastErrs  = map[uintptr]lastErr{}
)

// clearLastError removes the calling thread's record.
func clearLastError() {
	tid := threadID()
	lastErrMu.Lock()
	delete(lastErrs, tid)
	lastErrMu.Unlock()
}

// setLastError writes the calling thread's record.
func setLastError(code int32, msg string) {
	tid := threadID()
	lastErrMu.Lock()
	lastErrs[tid] = lastErr{code: code, msg: msg}
	lastErrMu.Unlock()
}

// getLastError reads the record kept under the calling thread's id; ok
// is false when that id has none.
func getLastError() (code int32, msg string, ok bool) {
	tid := threadID()
	lastErrMu.Lock()
	e, ok := lastErrs[tid]
	lastErrMu.Unlock()
	return e.code, e.msg, ok
}
