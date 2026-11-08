// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stubbi/asm/verifier/internal/securefs"
)

func createOnlineKeyFixtureDirectory(t *testing.T, path string) {
	t.Helper()
	directory, err := securefs.OpenDirectory(path, true, true)
	check(t, err)
	check(t, directory.Close())
}

func grantOnlineKeyFixtureReadAccess(t *testing.T, path string) {
	t.Helper()
	windowsSigningKeyDACL(t, path, false)
}

func TestWindowsCheckOnlineKeysRejectsUnprotectedDirectoryACL(t *testing.T) {
	dir, root, online := onlineFixture(t)
	check(t, run([]string{"check-online-keys", root, online}))
	unprotected := filepath.Join(dir, "inherited-online")
	check(t, os.Mkdir(unprotected, 0700))
	for _, role := range []string{"targets", "snapshot", "timestamp"} {
		data, err := os.ReadFile(filepath.Join(online, role+".pem"))
		check(t, err)
		check(t, os.WriteFile(filepath.Join(unprotected, role+".pem"), data, 0600))
	}
	if err := run([]string{"check-online-keys", root, unprotected}); err == nil {
		t.Fatal("accepted an online signing directory without a protected ACL")
	}
}
