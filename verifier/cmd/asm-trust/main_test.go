// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"

	"github.com/theupdateframework/go-tuf/v2/metadata"
)

func check(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func fixture(t *testing.T) (string, string, string) {
	t.Helper()
	dir := privateFixtureDirectory(t)
	args := []string{"prepare-root", filepath.Join(dir, "unsigned.json")}
	for _, name := range []string{"root1", "root2", "root3", "targets", "snapshot", "timestamp"} {
		seed := sha256.Sum256([]byte("ASM MAINTAINER TOOL TEST ONLY " + name))
		private := ed25519.NewKeyFromSeed(seed[:])
		pub, err := x509.MarshalPKIXPublicKey(private.Public())
		check(t, err)
		priv, err := x509.MarshalPKCS8PrivateKey(private)
		check(t, err)
		check(t, os.WriteFile(filepath.Join(dir, name+".pub"), pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pub}), 0600))
		check(t, os.WriteFile(filepath.Join(dir, name+".pem"), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: priv}), 0600))
		args = append(args, filepath.Join(dir, name+".pub"))
	}
	check(t, run(args))
	check(t, run([]string{"sign-root", args[1], filepath.Join(dir, "root1.pem"), filepath.Join(dir, "one.json")}))
	one, err := metadata.Root().FromFile(filepath.Join(dir, "one.json"))
	check(t, err)
	if one.VerifyDelegate("root", one) == nil {
		t.Fatal("one root signature met threshold")
	}
	root := filepath.Join(dir, "root.json")
	check(t, run([]string{"sign-root", filepath.Join(dir, "one.json"), filepath.Join(dir, "root2.pem"), root}))
	check(t, os.WriteFile(filepath.Join(dir, "index.tsv"), []byte("# asm-registry-v1\n"), 0600))
	check(t, os.WriteFile(filepath.Join(dir, "candidate"), []byte("candidate fixture"), 0600))
	encoded, err := json.Marshal(map[string]string{"index.tsv": filepath.Join(dir, "index.tsv"), "asm-0.5.0-x86_64-linux": filepath.Join(dir, "candidate")})
	check(t, err)
	targetMap := filepath.Join(dir, "map.json")
	check(t, os.WriteFile(targetMap, encoded, 0600))
	return dir, root, targetMap
}

func TestPublicationAndRenewal(t *testing.T) {
	dir, root, targetMap := fixture(t)
	first, second := filepath.Join(dir, "first"), filepath.Join(dir, "second")
	check(t, publish(root, dir, "-", targetMap, first))
	check(t, publish(root, dir, first, targetMap, second))
	check(t, inspect(root, second, targetMap))
	r, err := metadata.Root().FromFile(root)
	check(t, err)
	targets, err := metadata.Targets().FromFile(filepath.Join(second, "metadata/2.targets.json"))
	check(t, err)
	check(t, r.VerifyDelegate("targets", targets))
	if targets.Signed.Version != 2 || len(targets.Signed.Targets) != 2 {
		t.Fatal("invalid target renewal")
	}
	old, err := os.ReadFile(filepath.Join(first, "metadata/1.targets.json"))
	check(t, err)
	retained, err := os.ReadFile(filepath.Join(second, "metadata/1.targets.json"))
	check(t, err)
	if string(old) != string(retained) {
		t.Fatal("immutable metadata changed")
	}
	timestamp, err := metadata.Timestamp().FromFile(filepath.Join(second, "metadata/timestamp.json"))
	check(t, err)
	check(t, r.VerifyDelegate("timestamp", timestamp))
	if timestamp.Signed.Version != 2 {
		t.Fatal("timestamp did not advance")
	}
	if err := publish(root, dir, second, targetMap, first); err == nil {
		t.Fatal("replaced existing output")
	}
}

func TestWrongOnlineKeyLeavesNoPublication(t *testing.T) {
	dir, root, targetMap := fixture(t)
	wrong, err := os.ReadFile(filepath.Join(dir, "timestamp.pem"))
	check(t, err)
	check(t, os.WriteFile(filepath.Join(dir, "targets.pem"), wrong, 0600))
	out := filepath.Join(dir, "output")
	if publish(root, dir, "-", targetMap, out) == nil {
		t.Fatal("accepted wrong role key")
	}
	if _, err := os.Lstat(out); !os.IsNotExist(err) {
		t.Fatal("exposed failed publication")
	}
}

func TestAmbiguousPublicationInputsLeaveNoOutput(t *testing.T) {
	for _, input := range []string{`{"index.tsv":"first","index.tsv":"second"}`, `{"index.tsv":"first","index\u002etsv":"second"}`, `{} {}`, `{"nested":{"key":1,"key":2}}`} {
		t.Run(input, func(t *testing.T) {
			dir, root, targetMap := fixture(t)
			check(t, os.WriteFile(targetMap, []byte(input), 0600))
			output := filepath.Join(dir, "publication")
			if publish(root, dir, "-", targetMap, output) == nil {
				t.Fatal("accepted ambiguous target map")
			}
			if _, err := os.Lstat(output); !os.IsNotExist(err) {
				t.Fatal("exposed failed publication")
			}
		})
	}
}
