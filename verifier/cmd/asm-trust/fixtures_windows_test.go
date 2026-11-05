// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"path/filepath"
	"testing"

	"github.com/stubbi/asm/verifier/internal/securefs"
)

func privateFixtureDirectory(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "private-key-fixtures")
	directory, err := securefs.OpenDirectory(path, true, true)
	check(t, err)
	check(t, directory.Close())
	return path
}
