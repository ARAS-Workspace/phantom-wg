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
// thread_id.go — the identity of the calling OS thread, under which
// lasterror.go keeps the thread's record: pthread_self, on Linux and
// on macOS.

package main

/*
#include <pthread.h>
#include <stdint.h>

static uintptr_t bridge_thread_id(void) { return (uintptr_t)pthread_self(); }
*/
import "C"

// threadID returns the calling OS thread's pthread_t.
func threadID() uintptr {
	return uintptr(C.bridge_thread_id())
}
