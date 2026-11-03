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
// cgo boundary and abort the host process, and a failure records its
// code and message as the calling thread's last error. BridgeVersion,
// FreeString and LastError carry no Go logic that can panic, stay bare
// and leave that record as it is.

package main

/*
#include "wireguard_go_bridge.h"
*/
import "C"
import (
	"errors"
	"fmt"
	"unsafe"

	"wireguard-go-bridge/core"
)

// Compile-time drift checks: wgOK and wgErrInternal (guards.go, which
// has no import "C") must equal WG_OK and WG_ERR_INTERNAL from the header. Either drift
// direction makes one of these conversions negative and fails the build.
const _ = uint(C.WG_OK - wgOK)
const _ = uint(wgOK - C.WG_OK)
const _ = uint(C.WG_ERR_INTERNAL - wgErrInternal)
const _ = uint(wgErrInternal - C.WG_ERR_INTERNAL)

// ============================================================================
// PersistentDevice — WireGuard device with automatic IPC state persistence
// ============================================================================

//export NewPersistentDevice
func NewPersistentDevice(ifname *C.char, mtu C.int, dbPath *C.char) C.int64_t {
	name, m, db := C.GoString(ifname), int(mtu), C.GoString(dbPath)
	return C.int64_t(callGuardedHandle("NewPersistentDevice", func() (int64, error) {
		pd, err := newPersistentDevice(name, m, db)
		if errors.Is(err, errTunCreate) {
			return 0, withCode(C.WG_ERR_TUN_CREATE, err)
		}
		if err != nil {
			return 0, withCode(C.WG_ERR_DEVICE_CREATE, err)
		}
		return deviceRegistry.Add(pd), nil
	}))
}

//export DeviceIpcSet
func DeviceIpcSet(handle C.int64_t, config *C.char) C.int32_t {
	h, cfg := int64(handle), C.GoString(config)
	return C.int32_t(callGuardedCode("DeviceIpcSet", func() error {
		pd, err := getPersistentDevice(h)
		if err != nil {
			return err
		}
		if err := pd.ipcSet(cfg); err != nil {
			return withCode(C.WG_ERR_IPC_SET, err)
		}
		return nil
	}))
}

//export DeviceIpcGet
func DeviceIpcGet(handle C.int64_t) *C.char {
	h := int64(handle)
	dump, ok := callGuardedStr("DeviceIpcGet", func() (string, error) {
		pd, err := getPersistentDevice(h)
		if err != nil {
			return "", err
		}
		s, err := pd.ipcGet()
		if err != nil {
			return "", withCode(C.WG_ERR_IPC_SET, err)
		}
		return s, nil
	})
	if !ok {
		return nil
	}
	return C.CString(dump)
}

//export DeviceUp
func DeviceUp(handle C.int64_t) C.int32_t {
	h := int64(handle)
	return C.int32_t(callGuardedCode("DeviceUp", func() error {
		pd, err := getPersistentDevice(h)
		if err != nil {
			return err
		}
		if err := pd.dev.Up(); err != nil {
			return withCode(C.WG_ERR_DEVICE_UP, err)
		}
		return nil
	}))
}

//export DeviceDown
func DeviceDown(handle C.int64_t) C.int32_t {
	h := int64(handle)
	return C.int32_t(callGuardedCode("DeviceDown", func() error {
		pd, err := getPersistentDevice(h)
		if err != nil {
			return err
		}
		if err := pd.dev.Down(); err != nil {
			return withCode(C.WG_ERR_DEVICE_DOWN, err)
		}
		return nil
	}))
}

// DeviceClose takes the device out of the registry before it closes it:
// of two calls for one handle, one closes the device and the other
// finds no device.
//
//export DeviceClose
func DeviceClose(handle C.int64_t) C.int32_t {
	h := int64(handle)
	return C.int32_t(callGuardedCode("DeviceClose", func() error {
		obj, ok := deviceRegistry.Take(h)
		if !ok {
			return notFound(h)
		}
		obj.(*persistentDevice).close()
		return nil
	}))
}

// ============================================================================
// Key Generation
// ============================================================================

//export GeneratePrivateKey
func GeneratePrivateKey() *C.char {
	key, ok := callGuardedStr("GeneratePrivateKey", core.GeneratePrivateKey)
	if !ok {
		return nil
	}
	return C.CString(key)
}

//export DerivePublicKey
func DerivePublicKey(privateKeyHex *C.char) *C.char {
	priv := C.GoString(privateKeyHex)
	pub, ok := callGuardedStr("DerivePublicKey", func() (string, error) {
		p, err := core.DerivePublicKey(priv)
		if err != nil {
			return "", withCode(C.WG_ERR_INVALID_ARG, err)
		}
		return p, nil
	})
	if !ok {
		return nil
	}
	return C.CString(pub)
}

//export GeneratePresharedKey
func GeneratePresharedKey() *C.char {
	key, ok := callGuardedStr("GeneratePresharedKey", core.GeneratePresharedKey)
	if !ok {
		return nil
	}
	return C.CString(key)
}

//export HexToBase64
func HexToBase64(hexStr *C.char) *C.char {
	hex := C.GoString(hexStr)
	b64, ok := callGuardedStr("HexToBase64", func() (string, error) {
		b, err := core.HexToBase64(hex)
		if err != nil {
			return "", withCode(C.WG_ERR_INVALID_ARG, err)
		}
		return b, nil
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

// LastError returns a copy of the message of the calling thread's last
// error, to be freed with FreeString, and writes its code to *code
// unless code is NULL; after a guarded call that succeeded it returns
// NULL and writes WG_OK.
//
//export LastError
func LastError(code *C.int32_t) *C.char {
	c, msg, ok := getLastError()
	if code != nil {
		*code = C.int32_t(c)
	}
	if !ok {
		return nil
	}
	return C.CString(msg)
}

// ============================================================================
// Internal
// ============================================================================

func getPersistentDevice(handle int64) (*persistentDevice, error) {
	obj, ok := deviceRegistry.Get(handle)
	if !ok {
		return nil, notFound(handle)
	}
	return obj.(*persistentDevice), nil
}

func notFound(handle int64) error {
	return withCode(C.WG_ERR_NOT_FOUND, fmt.Errorf("device handle %d not found", handle))
}
