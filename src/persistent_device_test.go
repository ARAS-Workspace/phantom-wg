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
// persistent_device_test.go — an ipcSet persists the state it set, and
// close waits for an ipcSet in progress.

package main

import (
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// fakeDevice stands in for *device.Device. setHold and getHold, when
// set, hold the next IpcSet after it set the state, or the next IpcGet
// after it read the state, until they are closed; entered says which
// call is held.
type fakeDevice struct {
	mu      sync.Mutex
	state   string
	setHold chan struct{}
	getHold chan struct{}
	entered chan string
}

func (f *fakeDevice) IpcSet(config string) error {
	f.mu.Lock()
	f.state = config
	hold := f.setHold
	f.setHold = nil
	f.mu.Unlock()
	if hold != nil {
		f.entered <- "set " + config
		<-hold
	}
	return nil
}

func (f *fakeDevice) IpcGet() (string, error) {
	f.mu.Lock()
	s := f.state
	hold := f.getHold
	f.getHold = nil
	f.mu.Unlock()
	if hold != nil {
		f.entered <- "get " + s
		<-hold
	}
	return s, nil
}

func (f *fakeDevice) Up() error   { return nil }
func (f *fakeDevice) Down() error { return nil }
func (f *fakeDevice) Close()      {}

func newTestDevice(t *testing.T, dev *fakeDevice) *persistentDevice {
	t.Helper()
	db, err := openStateDB(filepath.Join(t.TempDir(), "device.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.Exec(`CREATE TABLE ipc_state (
		id INTEGER PRIMARY KEY CHECK (id = 1), dump TEXT NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	return &persistentDevice{dev: dev, db: db}
}

func persisted(t *testing.T, pd *persistentDevice) string {
	t.Helper()
	var dump string
	if err := pd.db.QueryRow("SELECT dump FROM ipc_state WHERE id = 1").Scan(&dump); err != nil {
		t.Fatal(err)
	}
	return dump
}

func TestPersistedStateIsTheLastSet(t *testing.T) {
	// The first ipcSet is held after its persist read the state "a";
	// a second ipcSet then sets "b". The DB ends with "b".
	dev := &fakeDevice{entered: make(chan string, 1)}
	pd := newTestDevice(t, dev)
	hold := make(chan struct{})
	dev.getHold = hold
	errs := make(chan error, 2)
	go func() { errs <- pd.ipcSet("a") }()
	<-dev.entered
	go func() { errs <- pd.ipcSet("b") }()
	time.Sleep(100 * time.Millisecond)
	close(hold)
	for range 2 {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	if got, want := persisted(t, pd), filterIpcDump(dev.state); got != want {
		t.Fatalf("persisted %q, the device holds %q", got, want)
	}
}

func TestCloseWaitsForIpcSet(t *testing.T) {
	dev := &fakeDevice{entered: make(chan string, 1)}
	pd := newTestDevice(t, dev)
	hold := make(chan struct{})
	dev.setHold = hold
	errs := make(chan error, 1)
	go func() { errs <- pd.ipcSet("a") }()
	<-dev.entered
	closed := make(chan struct{})
	go func() { pd.close(); close(closed) }()
	select {
	case <-closed:
		t.Fatal("close returned while an ipcSet was in progress")
	case <-time.After(100 * time.Millisecond):
	}
	close(hold)
	if err := <-errs; err != nil {
		t.Fatalf("the ipcSet close waited for: %v", err)
	}
	<-closed
}
