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
// exports.go — FFI exports: PersistentDevice + Key generation + utility.
// This is the entire public API surface. No high-level logic.
//
// Every export with Go logic runs its body through a callGuarded*
// helper (guards.go): a panic here would otherwise unwind into the
// cgo boundary and abort the host process. BridgeVersion and
// FreeString carry no Go logic that can panic and stay bare.

package main

/*
#include "wireguard_go_bridge.h"
*/
import "C"
import (
	"unsafe"

	"wireguard-go-bridge/core"
)

// Compile-time drift check: wgErrInternal (guards.go, pure Go) must
// equal WG_ERR_INTERNAL from the header. Either drift direction makes
// one of these conversions negative and fails the build.
const _ = uint(C.WG_ERR_INTERNAL - wgErrInternal)
const _ = uint(wgErrInternal - C.WG_ERR_INTERNAL)

// ============================================================================
// PersistentDevice — WireGuard device with automatic IPC state persistence
// ============================================================================

//export NewPersistentDevice
func NewPersistentDevice(ifname *C.char, mtu C.int, dbPath *C.char) C.int64_t {
	name, m, db := C.GoString(ifname), int(mtu), C.GoString(dbPath)
	return C.int64_t(callGuardedHandle("NewPersistentDevice", func() int64 {
		pd, err := newPersistentDevice(name, m, db)
		if err != nil {
			return int64(C.WG_ERR_DEVICE_CREATE)
		}
		return deviceRegistry.Add(pd)
	}))
}

//export DeviceIpcSet
func DeviceIpcSet(handle C.int64_t, config *C.char) C.int32_t {
	h, cfg := int64(handle), C.GoString(config)
	return C.int32_t(callGuardedCode("DeviceIpcSet", func() int32 {
		pd, errC := getPersistentDevice(h)
		if errC != C.WG_OK {
			return int32(errC)
		}
		if err := pd.ipcSet(cfg); err != nil {
			return int32(C.WG_ERR_IPC_SET)
		}
		return int32(C.WG_OK)
	}))
}

//export DeviceIpcGet
func DeviceIpcGet(handle C.int64_t) *C.char {
	h := int64(handle)
	dump, ok := callGuardedStr("DeviceIpcGet", func() (string, bool) {
		pd, errC := getPersistentDevice(h)
		if errC != C.WG_OK {
			return "", false
		}
		s, err := pd.ipcGet()
		if err != nil {
			return "", false
		}
		return s, true
	})
	if !ok {
		return nil
	}
	return C.CString(dump)
}

//export DeviceUp
func DeviceUp(handle C.int64_t) C.int32_t {
	h := int64(handle)
	return C.int32_t(callGuardedCode("DeviceUp", func() int32 {
		pd, errC := getPersistentDevice(h)
		if errC != C.WG_OK {
			return int32(errC)
		}
		if err := pd.dev.Up(); err != nil {
			return int32(C.WG_ERR_DEVICE_UP)
		}
		return int32(C.WG_OK)
	}))
}

//export DeviceDown
func DeviceDown(handle C.int64_t) C.int32_t {
	h := int64(handle)
	return C.int32_t(callGuardedCode("DeviceDown", func() int32 {
		pd, errC := getPersistentDevice(h)
		if errC != C.WG_OK {
			return int32(errC)
		}
		if err := pd.dev.Down(); err != nil {
			return int32(C.WG_ERR_DEVICE_DOWN)
		}
		return int32(C.WG_OK)
	}))
}

//export DeviceClose
func DeviceClose(handle C.int64_t) C.int32_t {
	h := int64(handle)
	return C.int32_t(callGuardedCode("DeviceClose", func() int32 {
		obj, ok := deviceRegistry.Get(h)
		if !ok {
			return int32(C.WG_ERR_NOT_FOUND)
		}
		pd := obj.(*persistentDevice)
		pd.close()
		deviceRegistry.Remove(h)
		return int32(C.WG_OK)
	}))
}

// ============================================================================
// Key Generation
// ============================================================================

//export GeneratePrivateKey
func GeneratePrivateKey() *C.char {
	key, ok := callGuardedStr("GeneratePrivateKey", func() (string, bool) {
		k, err := core.GeneratePrivateKey()
		return k, err == nil
	})
	if !ok {
		return nil
	}
	return C.CString(key)
}

//export DerivePublicKey
func DerivePublicKey(privateKeyHex *C.char) *C.char {
	priv := C.GoString(privateKeyHex)
	pub, ok := callGuardedStr("DerivePublicKey", func() (string, bool) {
		p, err := core.DerivePublicKey(priv)
		return p, err == nil
	})
	if !ok {
		return nil
	}
	return C.CString(pub)
}

//export GeneratePresharedKey
func GeneratePresharedKey() *C.char {
	key, ok := callGuardedStr("GeneratePresharedKey", func() (string, bool) {
		k, err := core.GeneratePresharedKey()
		return k, err == nil
	})
	if !ok {
		return nil
	}
	return C.CString(key)
}

//export HexToBase64
func HexToBase64(hexStr *C.char) *C.char {
	hex := C.GoString(hexStr)
	b64, ok := callGuardedStr("HexToBase64", func() (string, bool) {
		b, err := core.HexToBase64(hex)
		return b, err == nil
	})
	if !ok {
		return nil
	}
	return C.CString(b64)
}

// ============================================================================
// Utility
// ============================================================================

//export BridgeVersion
func BridgeVersion() *C.char {
	return C.CString(BridgeVersionStr)
}

//export FreeString
func FreeString(s *C.char) {
	C.free(unsafe.Pointer(s))
}

// ============================================================================
// Internal
// ============================================================================

func getPersistentDevice(handle int64) (*persistentDevice, C.int32_t) {
	obj, ok := deviceRegistry.Get(handle)
	if !ok {
		return nil, C.WG_ERR_NOT_FOUND
	}
	return obj.(*persistentDevice), C.WG_OK
}
