// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata"
)

// checkOnlineKeys validates the complete three-key online signing capability.
// It does not sign metadata, replace a root, or establish initial-root custody.
func checkOnlineKeys(rootPath, directory string) error {
	data, err := readJSON(rootPath, 1<<20)
	if err != nil {
		return err
	}
	root, err := metadata.Root().FromBytes(data)
	if err != nil {
		return err
	}
	if err := root.VerifyDelegate("root", root); err != nil {
		return err
	}
	if root.Signed.Type != "root" || root.Signed.Version < 1 || !root.Signed.ConsistentSnapshot || !root.Signed.Expires.After(time.Now()) {
		return errors.New("expected a current registry root with consistent snapshots")
	}
	if err := registryRootProfile(root.Signed); err != nil {
		return err
	}
	opened, err := openOnlineKeyDirectory(directory)
	if err != nil {
		return err
	}
	defer opened.Close()
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	expected := map[string]bool{"targets.pem": true, "snapshot.pem": true, "timestamp.pem": true}
	// Preparation validates a pinned public-root copy, then removes it before
	// publishing the three-key snapshot. No other temporary input is accepted.
	if filepath.Clean(rootPath) == filepath.Join(filepath.Clean(directory), ".check-root.json") {
		expected[".check-root.json"] = true
	}
	if len(entries) != len(expected) {
		return errors.New("online directory must contain only its selected role keys")
	}
	for _, entry := range entries {
		if !expected[entry.Name()] || !entry.Type().IsRegular() {
			return errors.New("unexpected file in online signing directory")
		}
	}
	for _, role := range []string{"targets", "snapshot", "timestamp"} {
		// One fixed file supplies one signer. Multi-key online thresholds need
		// a different reviewed mechanism rather than a partial capability.
		if root.Signed.Roles[role].Threshold != 1 {
			return errors.New("one private key cannot meet the selected online threshold")
		}
		s, err := signer(filepath.Join(directory, role+".pem"))
		if err != nil {
			return err
		}
		public, err := s.PublicKey()
		if err != nil {
			return err
		}
		key, err := metadata.KeyFromPublicKey(public)
		if err != nil {
			return err
		}
		id, err := key.ID()
		if err != nil {
			return err
		}
		found := false
		for _, authorized := range root.Signed.Roles[role].KeyIDs {
			if authorized == id {
				found = true
			}
		}
		if !found {
			return errors.New("private key does not match the selected registry role")
		}
	}
	return nil
}
