// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/theupdateframework/go-tuf/v2/metadata"
)

var registryIdentity = regexp.MustCompile(`^[0-9a-f]{32}$`)
var registryRootName = regexp.MustCompile(`^[1-9][0-9]*\.root\.json$`)

// Public immutable history remains in retained delivery storage. A new bundle
// carries the bounded root chain and current metadata/targets only, so routine
// renewal does not recopy all historical targets and snapshots.
func retainRegistryRoots(previous, stage string) error {
	entries, err := os.ReadDir(filepath.Join(previous, "metadata"))
	if err != nil {
		return err
	}
	count, total := 0, int64(0)
	for _, entry := range entries {
		if !registryRootName.MatchString(entry.Name()) {
			continue
		}
		count++
		if count > 4096 {
			return errors.New("registry root history exceeds file limit")
		}
		data, err := readJSON(filepath.Join(previous, "metadata", entry.Name()), 1<<20)
		if err != nil {
			return err
		}
		total += int64(len(data))
		if total > 32<<20 {
			return errors.New("registry root history exceeds byte limit")
		}
		dest := filepath.Join(stage, "metadata", entry.Name())
		if err := os.MkdirAll(filepath.Dir(dest), 0700); err != nil {
			return err
		}
		if err := exclusive(dest, data); err != nil {
			return err
		}
	}
	return nil
}

// Registry target names are opaque byte addresses. Package and lifecycle
// decisions remain with the authoritative exporter and assembly client.
func safeRegistryTarget(id, name string) bool {
	if len(name) > 512 || !strings.HasPrefix(name, "registries/"+id+"/") {
		return false
	}
	for _, part := range strings.Split(name, "/") {
		if part == "" || part == "." || part == ".." || len(part) > 128 {
			return false
		}
		for _, c := range []byte(part) {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
				return false
			}
		}
	}
	return true
}

func registryRootProfile(root metadata.RootType) error {
	seen := map[string]bool{}
	for _, name := range []string{"root", "targets", "snapshot", "timestamp"} {
		role := root.Roles[name]
		if role == nil || role.Threshold < 1 || role.Threshold > len(role.KeyIDs) ||
			(name == "root" && (role.Threshold < 2 || len(role.KeyIDs) < 3)) {
			return errors.New("invalid registry root threshold")
		}
		for _, id := range role.KeyIDs {
			key := root.Keys[id]
			if key == nil || key.Type != "ed25519" || key.Scheme != "ed25519" || seen[key.Value.PublicKey] {
				return errors.New("registry signing roles require distinct Ed25519 keys")
			}
			seen[key.Value.PublicKey] = true
		}
	}
	return nil
}
