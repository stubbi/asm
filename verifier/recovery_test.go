// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/sigstore/sigstore/pkg/signature"
	"github.com/theupdateframework/go-tuf/v2/metadata"
)

func rotateOnlineKey(t *testing.T, r *repositoryFixture, role string) {
	t.Helper()
	r.root.Signed.Version++
	old := r.root.Signed.Roles[role].KeyIDs[0]
	must(t, r.root.Signed.RevokeKey(old, role))
	seed := sha256.Sum256([]byte("ASM RECOVERY TEST KEY ONLY: " + role))
	private := ed25519.NewKeyFromSeed(seed[:])
	key, err := metadata.KeyFromPublicKey(private.Public())
	must(t, err)
	must(t, r.root.Signed.AddKey(key, role))
	r.keys[role], err = signature.LoadSignerVerifier(private, crypto.Hash(0))
	must(t, err)
	r.files[metadataURL+"/2.root.json"] = signedBytes(t, r.root, r.keys["root"], r.keys["root2"])
}

// A compromised timestamp can fast-forward its own version. A compromised
// snapshot and timestamp can also retain a nonexistent targets version before
// the targets download fails. Neither case requires a targets signing key.
func fastForwardState(t *testing.T, r *repositoryFixture, role, state string) {
	t.Helper()
	r.timestamp.Signed.Version = 100
	if role == "snapshot" {
		r.publish()
		must(t, r.refresh(state))
		return
	}
	r.snapshot.Signed.Version = 100
	r.snapshot.Signed.Meta["targets.json"].Version = 100
	snapshot := signedBytes(t, r.snapshot, r.keys["snapshot"])
	r.files[metadataURL+"/100.snapshot.json"] = snapshot
	r.timestamp.Signed.Meta["snapshot.json"] = metaBytes(100, snapshot)
	r.files[metadataURL+"/timestamp.json"] = signedBytes(t, r.timestamp, r.keys["timestamp"])
	if r.refresh(state) == nil {
		t.Fatal("accepted nonexistent targets version")
	}
	if _, err := os.Stat(filepath.Join(state, "snapshot.json")); err != nil {
		t.Fatalf("failed refresh did not retain the verified snapshot: %v", err)
	}
}

func publishRecovery(r *repositoryFixture) {
	r.timestamp.Signed.Version = 1
	r.snapshot.Signed.Version = 1
	r.publish()
}

func TestOnlineKeyRotationRecoversFastForward(t *testing.T) {
	for _, role := range []string{"timestamp", "snapshot"} {
		t.Run(role, func(t *testing.T) {
			r := newRepositoryFixture(t)
			state := statePath(t)
			fastForwardState(t, r, role, state)
			rotateOnlineKey(t, r, role)
			publishRecovery(r)
			must(t, r.refresh(state))
			must(t, r.refresh(state)) // cleanup must survive a process restart
		})
	}
}

func TestUnchangedOnlineKeysPreserveRollbackHistory(t *testing.T) {
	r := newRepositoryFixture(t)
	state := statePath(t)
	r.timestamp.Signed.Version = 100
	r.publish()
	must(t, r.refresh(state))
	r.root.Signed.Version = 2
	r.files[metadataURL+"/2.root.json"] = signedBytes(t, r.root, r.keys["root"], r.keys["root2"])
	publishRecovery(r)
	if r.refresh(state) == nil {
		t.Fatal("root renewal with unchanged online keys erased rollback history")
	}
	if r.refresh(state) == nil {
		t.Fatal("restart erased unchanged-key rollback history")
	}
}

func TestUnverifiedRootDoesNotDiscardHistory(t *testing.T) {
	r := newRepositoryFixture(t)
	state := statePath(t)
	fastForwardState(t, r, "snapshot", state)
	before := map[string][]byte{}
	for _, name := range []string{"timestamp.json", "snapshot.json", "targets.json"} {
		data, err := os.ReadFile(filepath.Join(state, name))
		must(t, err)
		before[name] = data
	}
	rotateOnlineKey(t, r, "snapshot")
	r.files[metadataURL+"/2.root.json"] = signedBytes(t, r.root, r.keys["root"])
	publishRecovery(r)
	if r.refresh(state) == nil {
		t.Fatal("accepted root without its signature threshold")
	}
	for name, expected := range before {
		data, err := os.ReadFile(filepath.Join(state, name))
		must(t, err)
		if !bytes.Equal(data, expected) {
			t.Fatalf("unverified root changed %s", name)
		}
	}
}

func TestResumedRotationWaitsForValidFinalRoot(t *testing.T) {
	r := newRepositoryFixture(t)
	state := statePath(t)
	fastForwardState(t, r, "snapshot", state)
	before, err := os.ReadFile(filepath.Join(state, "timestamp.json"))
	must(t, err)
	rotateOnlineKey(t, r, "snapshot")
	publishRecovery(r)
	r.root.Signed.Version = 3
	r.files[metadataURL+"/3.root.json"] = signedBytes(t, r.root, r.keys["root"])
	for i := 0; i < 2; i++ {
		if r.refresh(state) == nil {
			t.Fatal("accepted an incorrectly signed later root")
		}
		after, err := os.ReadFile(filepath.Join(state, "timestamp.json"))
		must(t, err)
		if !bytes.Equal(before, after) {
			t.Fatal("incomplete root chain discarded online history")
		}
	}
	delete(r.files, metadataURL+"/3.root.json")
	must(t, r.refresh(state))
}

func TestOnlineKeyAliasesDoNotDiscardHistory(t *testing.T) {
	r := newRepositoryFixture(t)
	state := statePath(t)
	fastForwardState(t, r, "snapshot", state)
	r.root.Signed.Version = 2
	for _, role := range []string{"timestamp", "snapshot"} {
		old := r.root.Signed.Roles[role].KeyIDs[0]
		// Metadata key identifiers do not make a public key new. Retain both
		// identifiers in reversed order to also exercise key-order renewal.
		r.root.Signed.Keys["alias-"+role] = r.root.Signed.Keys[old]
		r.root.Signed.Roles[role].KeyIDs = []string{"alias-" + role, old}
	}
	r.files[metadataURL+"/2.root.json"] = signedBytes(t, r.root, r.keys["root"], r.keys["root2"])
	publishRecovery(r)
	if r.refresh(state) == nil {
		t.Fatal("key identifiers erased unchanged-key rollback history")
	}
	if r.refresh(state) == nil {
		t.Fatal("restart erased unchanged-key rollback history")
	}
}

func TestExpiredRotatedRootRetainsHistoryUntilCurrentRoot(t *testing.T) {
	r := newRepositoryFixture(t)
	state := statePath(t)
	fastForwardState(t, r, "snapshot", state)
	before, err := os.ReadFile(filepath.Join(state, "timestamp.json"))
	must(t, err)
	rotateOnlineKey(t, r, "snapshot")
	r.root.Signed.Expires = time.Now().Add(-time.Hour)
	r.files[metadataURL+"/2.root.json"] = signedBytes(t, r.root, r.keys["root"], r.keys["root2"])
	publishRecovery(r)
	if r.refresh(state) == nil {
		t.Fatal("accepted expired final root")
	}
	after, err := os.ReadFile(filepath.Join(state, "timestamp.json"))
	must(t, err)
	if !bytes.Equal(before, after) {
		t.Fatal("expired final root discarded timestamp history")
	}
	r.root.Signed.Version = 3
	r.root.Signed.Expires = time.Now().Add(24 * time.Hour)
	r.files[metadataURL+"/3.root.json"] = signedBytes(t, r.root, r.keys["root"], r.keys["root2"])
	must(t, r.refresh(state))
}

func TestRecoveredRootRetainsNewTimestampAfterFailure(t *testing.T) {
	r := newRepositoryFixture(t)
	state := statePath(t)
	fastForwardState(t, r, "snapshot", state)
	rotateOnlineKey(t, r, "snapshot")
	publishRecovery(r)
	r.timestamp.Signed.Version = 2
	r.publish()
	r.files[metadataURL+"/1.snapshot.json"] = append(r.files[metadataURL+"/1.snapshot.json"], ' ')
	if r.refresh(state) == nil {
		t.Fatal("accepted altered snapshot after recovery")
	}
	publishRecovery(r)
	if r.refresh(state) == nil {
		t.Fatal("recovery was repeated and erased the new timestamp after failure")
	}
	r.timestamp.Signed.Version = 2
	r.publish()
	must(t, r.refresh(state))
}

type failedCleanupMirror struct {
	*repositoryFixture
	state string
}

func (r failedCleanupMirror) DownloadFile(address string, limit int64, timeout time.Duration) ([]byte, error) {
	if address == metadataURL+"/3.root.json" {
		// Force the second deletion to fail after timestamp removal. The
		// replacement happens after initial path validation, only in this test.
		snapshot := filepath.Join(r.state, "snapshot.json")
		must(r.t, os.Rename(snapshot, filepath.Join(r.state, "saved-snapshot")))
		must(r.t, os.Mkdir(snapshot, 0700))
		must(r.t, os.WriteFile(filepath.Join(snapshot, "block-removal"), []byte("fixture"), 0600))
	}
	return r.repositoryFixture.DownloadFile(address, limit, timeout)
}

func TestFailedCleanupRetainsRecoveryCheckpoint(t *testing.T) {
	r := newRepositoryFixture(t)
	state := statePath(t)
	fastForwardState(t, r, "timestamp", state)
	rotateOnlineKey(t, r, "timestamp")
	publishRecovery(r)
	err := useRepository(r.anchor, state, failedCleanupMirror{r, state}, func(*trustedRepository) error { return nil })
	if err == nil {
		t.Fatal("ignored incomplete cache cleanup")
	}
	if _, err := os.Stat(filepath.Join(state, "timestamp.json")); !os.IsNotExist(err) {
		t.Fatal("did not reach the interruption between cache deletions")
	}
	must(t, os.RemoveAll(filepath.Join(state, "snapshot.json")))
	must(t, os.Rename(filepath.Join(state, "saved-snapshot"), filepath.Join(state, "snapshot.json")))
	must(t, r.refresh(state))
}

type interruptedRecoveryMirror struct {
	files map[string][]byte
}

func (r interruptedRecoveryMirror) DownloadFile(address string, limit int64, _ time.Duration) ([]byte, error) {
	// The maintained updater persists root 2 before it requests root 3. Exit
	// without running defers, before the adapter can process that rotation.
	if address == metadataURL+"/3.root.json" {
		os.Exit(73)
	}
	data, ok := r.files[address]
	if !ok {
		return nil, &metadata.ErrDownloadHTTP{StatusCode: 404, URL: address}
	}
	if int64(len(data)) > limit {
		return nil, errors.New("fixture byte limit")
	}
	return data, nil
}

func TestInterruptedOnlineKeyRecovery(t *testing.T) {
	if fixture := os.Getenv("ASM_RECOVERY_TEST_FIXTURE"); fixture != "" {
		var server struct {
			Anchor []byte
			Files  map[string][]byte
			State  string
		}
		data, err := os.ReadFile(fixture)
		must(t, err)
		must(t, json.Unmarshal(data, &server))
		must(t, useRepository(server.Anchor, server.State, interruptedRecoveryMirror{server.Files}, func(*trustedRepository) error { return nil }))
		t.Fatal("did not interrupt root rotation")
	}
	for _, role := range []string{"timestamp", "snapshot"} {
		for _, partialCleanup := range []bool{false, true} {
			name := role + "/root persisted"
			if partialCleanup {
				name = role + "/timestamp removed"
			}
			t.Run(name, func(t *testing.T) {
				r := newRepositoryFixture(t)
				state := statePath(t)
				fastForwardState(t, r, role, state)
				rotateOnlineKey(t, r, role)
				publishRecovery(r)
				server, err := json.Marshal(struct {
					Anchor []byte
					Files  map[string][]byte
					State  string
				}{r.anchor, r.files, state})
				must(t, err)
				fixture := filepath.Join(filepath.Dir(state), "server.json")
				must(t, os.WriteFile(fixture, server, 0600))
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestInterruptedOnlineKeyRecovery$")
				cmd.Env = append(os.Environ(), "ASM_RECOVERY_TEST_FIXTURE="+fixture)
				err = cmd.Run()
				var exit *exec.ExitError
				if !errors.As(err, &exit) || exit.ExitCode() != 73 {
					t.Fatalf("unexpected interrupted process result: %v", err)
				}
				if partialCleanup {
					// Simulate a second interruption after the first mandated
					// deletion, before snapshot deletion or checkpoint advance.
					must(t, os.Remove(filepath.Join(state, "timestamp.json")))
				}
				must(t, r.refresh(state))
				must(t, r.refresh(state))
			})
		}
	}
}
