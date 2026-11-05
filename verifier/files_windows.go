// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"os"

	"github.com/stubbi/asm/verifier/internal/securefs"
)

type stateDirectory struct{ *securefs.Directory }

func openState(path string) (*stateDirectory, error) {
	directory, err := securefs.OpenDirectory(path, true, true)
	if err != nil {
		return nil, err
	}
	return &stateDirectory{directory}, nil
}
func openFile(path string, flags int, _ uint32) (*os.File, error) {
	return securefs.OpenFile(path, flags)
}
func atomicWrite(path string, data []byte) error           { return securefs.AtomicWrite(path, data) }
func acquireStateLock(file *os.File) (func() error, error) { return securefs.LockFile(file) }
func syncOpenedFile(file *os.File) error                   { return securefs.SyncFile(file) }
func (d *stateDirectory) Sync() error {
	return securefs.SyncDirectory(d.Directory, append([]string{"clock", "rotation-root.json"}, roles...))
}
