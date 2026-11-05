//go:build linux || darwin

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestProtectedStateAndOutput(t *testing.T) {
	r := newRepositoryFixture(t)
	state := statePath(t)
	must(t, os.Mkdir(state, 0777))
	must(t, os.Chmod(state, 0777))
	if r.refresh(state) == nil {
		t.Fatal("accepted writable state")
	}
	must(t, os.Chmod(state, 0700))
	alias := filepath.Join(filepath.Dir(state), "state-link")
	must(t, os.Symlink(state, alias))
	if r.refresh(alias) == nil {
		t.Fatal("accepted symlink state directory")
	}
	victim := filepath.Join(filepath.Dir(state), "victim")
	must(t, os.WriteFile(victim, []byte("preserve"), 0600))
	must(t, os.Symlink(victim, filepath.Join(state, "root.json")))
	if r.refresh(state) == nil {
		t.Fatal("accepted symlink metadata")
	}
	if writeExclusive(victim, []byte("replace")) == nil {
		t.Fatal("replaced output")
	}
	data, err := os.ReadFile(victim)
	must(t, err)
	if string(data) != "preserve" {
		t.Fatal("changed existing file")
	}
}
