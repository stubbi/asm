//go:build linux || darwin

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"os"
	"testing"
)

func createOnlineKeyFixtureDirectory(t *testing.T, path string) {
	t.Helper()
	check(t, os.Mkdir(path, 0700))
}

func grantOnlineKeyFixtureReadAccess(t *testing.T, path string) {
	t.Helper()
	check(t, os.Chmod(path, 0640))
}
