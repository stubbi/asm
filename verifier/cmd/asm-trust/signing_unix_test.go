//go:build linux || darwin

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPrivateKeyRefusesLinkedFileBeforeSigning(t *testing.T) {
	dir, _, _ := fixture(t)
	path := filepath.Join(dir, "targets.pem")
	check(t, os.Link(path, filepath.Join(dir, "another-key-name")))
	if _, err := readPrivateKey(path); err == nil {
		t.Fatal("accepted a multiply linked private signing key")
	}
}
