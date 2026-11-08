// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/theupdateframework/go-tuf/v2/metadata"
)

const registryID = "0123456789abcdef0123456789abcdef"

func registryMap(t *testing.T, dir string) (string, string) {
	t.Helper()
	name := "registries/" + registryID + "/releases/fixture/hello/1.0.0.json"
	data := []byte("{\"schema\":2}\n")
	source := filepath.Join(dir, "manifest.json")
	check(t, os.WriteFile(source, data, 0600))
	encoded, err := json.Marshal(map[string]string{name: source})
	check(t, err)
	path := filepath.Join(dir, "registry-map.json")
	check(t, os.WriteFile(path, encoded, 0600))
	return path, name
}

func TestRegistryPublicationCopiesEverySignedTargetAndRenews(t *testing.T) {
	dir, root, _ := fixture(t)
	targetMap, name := registryMap(t, dir)
	first, second := filepath.Join(dir, "registry-first"), filepath.Join(dir, "registry-second")
	check(t, run([]string{"publish-registry", root, dir, "-", targetMap, first, registryID, "5"}))
	check(t, run([]string{"publish-registry", root, dir, first, targetMap, second, registryID, "8"}))
	check(t, run([]string{"inspect-registry", root, second, targetMap, registryID}))
	targets, err := metadata.Targets().FromFile(filepath.Join(second, "metadata/8.targets.json"))
	check(t, err)
	target := targets.Signed.Targets[name]
	if target == nil || len(targets.Signed.Targets) != 1 {
		t.Fatal("wrong signed registry target set")
	}
	stored := filepath.Join(second, "targets", filepath.Dir(name), hex.EncodeToString(target.Hashes["sha256"])+"."+filepath.Base(name))
	data, err := os.ReadFile(stored)
	check(t, err)
	check(t, target.VerifyLengthHashes(data))
	if string(data) != "{\"schema\":2}\n" {
		t.Fatal("retained target bytes changed")
	}
	if targets.Signed.Version != 8 {
		t.Fatal("reserved version was not used")
	}
	if _, err := os.Stat(filepath.Join(second, "metadata/1.root.json")); err != nil {
		t.Fatal("renewal lost the root chain")
	}
	if _, err := os.Stat(filepath.Join(second, "metadata/5.targets.json")); !os.IsNotExist(err) {
		t.Fatal("routine registry renewal recopied prior online-role history")
	}
	check(t, os.WriteFile(stored, []byte("tampered retained bytes"), 0600))
	if run([]string{"inspect-registry", root, second, targetMap, registryID}) == nil {
		t.Fatal("inspection accepted changed retained bytes")
	}
}

func TestRegistryReservedVersionsAndImmutableReleaseBytes(t *testing.T) {
	dir, root, _ := fixture(t)
	targetMap, _ := registryMap(t, dir)
	first := filepath.Join(dir, "first")
	check(t, run([]string{"publish-registry", root, dir, "-", targetMap, first, registryID, "5"}))
	for _, version := range []string{"0", "4", "5", "+6", "06", "9223372036854775808"} {
		out := filepath.Join(dir, "reused-"+version)
		if run([]string{"publish-registry", root, dir, first, targetMap, out, registryID, version}) == nil {
			t.Fatal("accepted invalid or reused reserved version " + version)
		}
		if _, err := os.Stat(out); !os.IsNotExist(err) {
			t.Fatal("invalid version exposed output")
		}
	}
	check(t, os.WriteFile(filepath.Join(dir, "manifest.json"), []byte("changed immutable release"), 0600))
	if run([]string{"publish-registry", root, dir, first, targetMap, filepath.Join(dir, "changed"), registryID, "6"}) == nil {
		t.Fatal("replaced immutable release target bytes")
	}
}

func TestRegistryPublicationRejectsForeignTargetsAndCrossRegistryHistory(t *testing.T) {
	dir, root, _ := fixture(t)
	targetMap, _ := registryMap(t, dir)
	first := filepath.Join(dir, "first")
	check(t, run([]string{"publish-registry", root, dir, "-", targetMap, first, registryID, "5"}))
	for _, attack := range []string{"foreign target", "changed registry", "traversal"} {
		t.Run(attack, func(t *testing.T) {
			selected := registryID
			name := "registries/" + registryID + "/policy.tsv"
			switch attack {
			case "foreign target":
				name = "registries/ffffffffffffffffffffffffffffffff/policy.tsv"
			case "changed registry":
				selected = "ffffffffffffffffffffffffffffffff"
				name = "registries/" + selected + "/policy.tsv"
			case "traversal":
				name = "registries/" + registryID + "/../policy.tsv"
			}
			encoded, err := json.Marshal(map[string]string{name: filepath.Join(dir, "manifest.json")})
			check(t, err)
			check(t, os.WriteFile(targetMap, encoded, 0600))
			out := filepath.Join(dir, "refused-"+attack)
			if run([]string{"publish-registry", root, dir, first, targetMap, out, selected, "6"}) == nil {
				t.Fatal("accepted " + attack)
			}
			if _, err := os.Stat(out); !os.IsNotExist(err) {
				t.Fatal("exposed refused publication")
			}
		})
	}
}
