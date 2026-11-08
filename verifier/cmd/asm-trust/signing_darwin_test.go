// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"os/exec"
	"path/filepath"
	"testing"
)

func TestPrivateKeyRefusesDescriptorACLGrant(t *testing.T) {
	dir, _, _ := fixture(t)
	path := filepath.Join(dir, "targets.pem")
	if out, err := exec.Command("/bin/chmod", "+a", "everyone allow read", path).CombinedOutput(); err != nil {
		t.Fatalf("fixture ACL: %s %v", out, err)
	}
	if _, err := readPrivateKey(path); err == nil {
		t.Fatal("accepted a private signing key with an ACL read grant")
	}
}
