// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/pem"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata"
)

func nextRootArgs(dir, current, output string) []string {
	args := []string{"prepare-next-root", current, output}
	for _, name := range []string{"root1", "root2", "root3", "targets", "snapshot", "timestamp"} {
		args = append(args, filepath.Join(dir, name+".pub"))
	}
	return args
}

func TestPrepareNextRootRenewsWithoutSigningOrReplacing(t *testing.T) {
	dir, current, _ := fixture(t)
	before, err := os.ReadFile(current)
	check(t, err)
	output := filepath.Join(dir, "next.json")
	check(t, run(nextRootArgs(dir, current, output)))
	next, err := metadata.Root().FromFile(output)
	check(t, err)
	if next.Signed.Version != 2 || len(next.Signatures) != 0 || !next.Signed.ConsistentSnapshot ||
		next.Signed.Roles["root"].Threshold != 2 || !next.Signed.Expires.After(time.Now().Add(364*24*time.Hour)) {
		t.Fatal("next root does not have the unsigned sequential renewal profile")
	}
	check(t, registryRootProfile(next.Signed))
	if next.VerifyDelegate("root", next) == nil {
		t.Fatal("unsigned next root met its signature threshold")
	}
	if err := run(nextRootArgs(dir, current, output)); err == nil {
		t.Fatal("replaced an existing ceremony document")
	}
	after, err := os.ReadFile(current)
	check(t, err)
	if string(after) != string(before) {
		t.Fatal("changed the existing root")
	}
}

func TestPrepareNextRootRotatesOnlineKeyAndRequiresOfflineThreshold(t *testing.T) {
	dir, current, _ := fixture(t)
	seed := sha256.Sum256([]byte("ASM NEXT ROOT TEST ONLY timestamp"))
	private := ed25519.NewKeyFromSeed(seed[:])
	public, err := x509.MarshalPKIXPublicKey(private.Public())
	check(t, err)
	check(t, os.WriteFile(filepath.Join(dir, "timestamp.pub"), pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: public}), 0600))
	output := filepath.Join(dir, "next.json")
	check(t, run(nextRootArgs(dir, current, output)))
	old, err := metadata.Root().FromFile(current)
	check(t, err)
	next, err := metadata.Root().FromFile(output)
	check(t, err)
	if next.Signed.Roles["timestamp"].KeyIDs[0] == old.Signed.Roles["timestamp"].KeyIDs[0] {
		t.Fatal("did not rotate the timestamp key")
	}
	one := filepath.Join(dir, "next-one.json")
	check(t, run([]string{"sign-root", output, filepath.Join(dir, "root1.pem"), one}))
	next, err = metadata.Root().FromFile(one)
	check(t, err)
	if old.VerifyDelegate("root", next) == nil {
		t.Fatal("one old root signature authorized rotation")
	}
	two := filepath.Join(dir, "next-two.json")
	check(t, run([]string{"sign-root", one, filepath.Join(dir, "root2.pem"), two}))
	next, err = metadata.Root().FromFile(two)
	check(t, err)
	check(t, old.VerifyDelegate("root", next))
	check(t, next.VerifyDelegate("root", next))
}

func TestPrepareNextRootRejectsInvalidAuthorityAndKeysWithoutOutput(t *testing.T) {
	for _, name := range []string{"unsigned-current", "invalid-profile", "duplicate-key", "private-key", "invalid-version", "overflow"} {
		t.Run(name, func(t *testing.T) {
			dir, current, _ := fixture(t)
			root, err := metadata.Root().FromFile(current)
			check(t, err)
			switch name {
			case "unsigned-current":
				current = filepath.Join(dir, "unsigned.json")
			case "invalid-profile":
				root.Signed.Roles["root"].Threshold = 1
			case "duplicate-key":
				key, err := os.ReadFile(filepath.Join(dir, "targets.pub"))
				check(t, err)
				check(t, os.WriteFile(filepath.Join(dir, "snapshot.pub"), key, 0600))
			case "private-key":
				key, err := os.ReadFile(filepath.Join(dir, "targets.pem"))
				check(t, err)
				check(t, os.WriteFile(filepath.Join(dir, "targets.pub"), key, 0600))
			case "invalid-version":
				root.Signed.Version = 0
			case "overflow":
				root.Signed.Version = math.MaxInt64
			}
			if name == "invalid-profile" || name == "invalid-version" || name == "overflow" {
				root.Signatures = nil
				for _, key := range []string{"root1.pem", "root2.pem"} {
					s, err := signer(filepath.Join(dir, key))
					check(t, err)
					_, err = root.Sign(s)
					check(t, err)
				}
				data, err := root.ToBytes(true)
				check(t, err)
				check(t, os.WriteFile(current, data, 0600))
			}
			output := filepath.Join(dir, "refused.json")
			if err := run(nextRootArgs(dir, current, output)); err == nil {
				t.Fatal("accepted invalid ceremony inputs")
			}
			if _, err := os.Lstat(output); !os.IsNotExist(err) {
				t.Fatal("exposed an invalid ceremony document")
			}
		})
	}
}
