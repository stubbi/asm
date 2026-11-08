// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata"
)

// All keys originate from the deterministic, explicitly synthetic fixture.
func onlineFixture(t *testing.T) (string, string, string) {
	t.Helper()
	dir, root, _ := fixture(t)
	online := filepath.Join(dir, "online")
	createOnlineKeyFixtureDirectory(t, online)
	for _, role := range []string{"targets", "snapshot", "timestamp"} {
		data, err := os.ReadFile(filepath.Join(dir, role+".pem"))
		check(t, err)
		check(t, os.WriteFile(filepath.Join(online, role+".pem"), data, 0600))
	}
	return dir, root, online
}

func TestCheckOnlineKeysAcceptsOnlySelectedCurrentRegistryRoles(t *testing.T) {
	_, root, online := onlineFixture(t)
	check(t, run([]string{"check-online-keys", root, online}))
}

func TestCheckOnlineKeysRejectsNonphysicalOrMissingDirectory(t *testing.T) {
	for _, name := range []string{"symlink", "file", "missing"} {
		t.Run(name, func(t *testing.T) {
			dir, root, online := onlineFixture(t)
			check(t, run([]string{"check-online-keys", root, online}))
			path := filepath.Join(dir, "selected-online")
			switch name {
			case "symlink":
				check(t, os.Symlink(online, path))
			case "file":
				check(t, os.WriteFile(path, []byte("not a directory"), 0600))
			}
			if err := run([]string{"check-online-keys", root, path}); err == nil {
				t.Fatal("accepted an invalid online signing directory")
			}
			if name == "missing" {
				if _, err := os.Lstat(path); !os.IsNotExist(err) {
					t.Fatal("created a missing online signing directory")
				}
			}
		})
	}
}

func TestCheckOnlineKeysRejectsWrongRolesAndRootMaterial(t *testing.T) {
	for _, name := range []string{"snapshot.pem", "root1.pem", "root-extra", "public-mode", "symlink", "missing"} {
		t.Run(name, func(t *testing.T) {
			dir, root, online := onlineFixture(t)
			check(t, run([]string{"check-online-keys", root, online}))
			path := filepath.Join(online, "targets.pem")
			switch name {
			case "snapshot.pem", "root1.pem":
				body, err := os.ReadFile(filepath.Join(dir, name))
				check(t, err)
				check(t, os.WriteFile(path, body, 0600))
			case "root-extra":
				check(t, os.WriteFile(filepath.Join(online, "root.pem"), []byte("SYNTHETIC ROOT KEY MUST NOT ENTER ONLINE DIRECTORY"), 0600))
			case "public-mode":
				grantOnlineKeyFixtureReadAccess(t, path)
			case "symlink":
				check(t, os.Remove(path))
				check(t, os.Symlink(filepath.Join(dir, "targets.pem"), path))
			case "missing":
				check(t, os.Remove(path))
			}
			if err := run([]string{"check-online-keys", root, online}); err == nil {
				t.Fatal("accepted invalid online key selection")
			}
		})
	}
}

func TestCheckOnlineKeysRejectsInvalidRegistryRoot(t *testing.T) {
	for _, name := range []string{"unsigned", "expired", "shared-role", "online-threshold", "changed-key-id"} {
		t.Run(name, func(t *testing.T) {
			dir, root, online := onlineFixture(t)
			check(t, run([]string{"check-online-keys", root, online}))
			r, err := metadata.Root().FromFile(root)
			check(t, err)
			r.Signatures = nil
			switch name {
			case "expired":
				r.Signed.Expires = time.Now().Add(-time.Hour)
			case "shared-role":
				r.Signed.Roles["targets"].KeyIDs = r.Signed.Roles["snapshot"].KeyIDs
			case "online-threshold":
				r.Signed.Roles["targets"].Threshold = 2
			case "changed-key-id":
				keyID := r.Signed.Roles["targets"].KeyIDs[0]
				r.Signed.Keys["wrong-id"] = r.Signed.Keys[keyID]
				delete(r.Signed.Keys, keyID)
				r.Signed.Roles["targets"].KeyIDs[0] = "wrong-id"
			}
			if name != "unsigned" {
				for _, key := range []string{"root1.pem", "root2.pem"} {
					s, err := signer(filepath.Join(dir, key))
					check(t, err)
					_, err = r.Sign(s)
					check(t, err)
				}
			}
			body, err := r.ToBytes(true)
			check(t, err)
			check(t, os.WriteFile(root, body, 0600))
			if err := run([]string{"check-online-keys", root, online}); err == nil {
				t.Fatal("accepted invalid registry root")
			}
		})
	}
}
