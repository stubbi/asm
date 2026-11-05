// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"bytes"
	"crypto"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/sigstore/sigstore/pkg/signature"
	"github.com/theupdateframework/go-tuf/v2/metadata"
)

type repositoryFixture struct {
	t         *testing.T
	root      *metadata.Metadata[metadata.RootType]
	targets   *metadata.Metadata[metadata.TargetsType]
	snapshot  *metadata.Metadata[metadata.SnapshotType]
	timestamp *metadata.Metadata[metadata.TimestampType]
	keys      map[string]signature.Signer
	files     map[string][]byte
	anchor    []byte
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func signedBytes[T metadata.RootType | metadata.TargetsType | metadata.SnapshotType | metadata.TimestampType](t *testing.T, m *metadata.Metadata[T], signers ...signature.Signer) []byte {
	t.Helper()
	m.ClearSignatures()
	for _, signer := range signers {
		_, err := m.Sign(signer)
		must(t, err)
	}
	data, err := m.ToBytes(false)
	must(t, err)
	return data
}

func newRepositoryFixture(t *testing.T) *repositoryFixture {
	t.Helper()
	expires := time.Now().Add(24 * time.Hour)
	r := &repositoryFixture{t: t, root: metadata.Root(expires), targets: metadata.Targets(expires),
		snapshot: metadata.Snapshot(expires), timestamp: metadata.Timestamp(expires),
		keys: map[string]signature.Signer{}, files: map[string][]byte{}}
	for _, name := range []string{"root", "root2", "root3", "targets", "snapshot", "timestamp"} {
		// Deterministic test-only seeds. Never use these public fixtures for a
		// production root; no private key is written to the repository or disk.
		seed := sha256.Sum256([]byte("ASM TEST KEY ONLY: " + name))
		private := ed25519.NewKeyFromSeed(seed[:])
		signer, err := signature.LoadSignerVerifier(private, crypto.Hash(0))
		must(t, err)
		r.keys[name] = signer
		key, err := metadata.KeyFromPublicKey(private.Public())
		must(t, err)
		role := name
		if name == "root2" || name == "root3" {
			role = "root"
		}
		must(t, r.root.Signed.AddKey(key, role))
	}
	r.root.Signed.Roles["root"].Threshold = 2
	r.anchor = signedBytes(t, r.root, r.keys["root"], r.keys["root2"])
	must(t, checkRoot(r.anchor, time.Now()))
	index := []byte("authenticated index fixture\n")
	r.targets.Signed.Targets["index.tsv"] = targetBytes(index)
	r.files[targetsURL+"/"+digestString(index)+".index.tsv"] = index
	r.publish()
	return r
}

func targetBytes(data []byte) *metadata.TargetFiles {
	h := sha256.Sum256(data)
	return &metadata.TargetFiles{Length: int64(len(data)), Hashes: metadata.Hashes{"sha256": h[:]}}
}

func metaBytes(version int64, data []byte) *metadata.MetaFiles {
	target := targetBytes(data)
	return &metadata.MetaFiles{Version: version, Length: target.Length, Hashes: target.Hashes}
}

func (r *repositoryFixture) publish() {
	targets := signedBytes(r.t, r.targets, r.keys["targets"])
	r.files[metadataURL+"/1.targets.json"] = targets
	r.snapshot.Signed.Meta["targets.json"] = metaBytes(r.targets.Signed.Version, targets)
	snapshot := signedBytes(r.t, r.snapshot, r.keys["snapshot"])
	r.files[metadataURL+"/1.snapshot.json"] = snapshot
	r.timestamp.Signed.Meta["snapshot.json"] = metaBytes(r.snapshot.Signed.Version, snapshot)
	r.files[metadataURL+"/timestamp.json"] = signedBytes(r.t, r.timestamp, r.keys["timestamp"])
}

func (r *repositoryFixture) DownloadFile(address string, limit int64, _ time.Duration) ([]byte, error) {
	data, ok := r.files[address]
	if !ok {
		return nil, &metadata.ErrDownloadHTTP{StatusCode: 404, URL: address}
	}
	if int64(len(data)) > limit {
		return nil, errors.New("fixture byte limit")
	}
	return bytes.Clone(data), nil
}

func (r *repositoryFixture) refresh(state string) error {
	return useRepository(r.anchor, state, r, func(u *trustedRepository) error {
		data, err := u.download("index.tsv")
		if err != nil {
			return err
		}
		if !bytes.Equal(data, []byte("authenticated index fixture\n")) {
			return errors.New("wrong target")
		}
		return nil
	})
}

func statePath(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	must(t, os.Chmod(dir, 0700))
	// Darwin's temporary directory can start with the system /var symlink.
	// Supply its canonical path; production still refuses symlink components.
	dir, err := filepath.EvalSymlinks(dir)
	must(t, err)
	return filepath.Join(dir, "state")
}

func TestRefreshAndPersistentRollback(t *testing.T) {
	r := newRepositoryFixture(t)
	state := statePath(t)
	must(t, r.refresh(state))
	old := bytes.Clone(r.files[metadataURL+"/timestamp.json"])
	r.timestamp.Signed.Version = 2
	r.publish()
	must(t, r.refresh(state))
	r.files[metadataURL+"/timestamp.json"] = old
	if err := r.refresh(state); err == nil {
		t.Fatal("accepted replay after restart")
	}
}

func TestRejectExpiredTamperedMixedAndMissing(t *testing.T) {
	for _, attack := range []string{"timestamp expiry", "targets expiry", "signature", "snapshot hash", "target bytes", "missing target", "missing metadata"} {
		t.Run(attack, func(t *testing.T) {
			r := newRepositoryFixture(t)
			switch attack {
			case "timestamp expiry":
				r.timestamp.Signed.Expires = time.Now().Add(-time.Hour)
				r.publish()
			case "targets expiry":
				r.targets.Signed.Expires = time.Now().Add(-time.Hour)
				r.publish()
			case "signature":
				r.files[metadataURL+"/timestamp.json"] = signedBytes(t, r.timestamp, r.keys["targets"])
			case "snapshot hash":
				r.files[metadataURL+"/1.snapshot.json"] = append(r.files[metadataURL+"/1.snapshot.json"], ' ')
			case "target bytes":
				for path := range r.files {
					if filepath.Ext(path) == ".tsv" {
						r.files[path] = []byte("corrupted")
					}
				}
			case "missing target":
				delete(r.targets.Signed.Targets, "index.tsv")
				r.publish()
			case "missing metadata":
				delete(r.files, metadataURL+"/timestamp.json")
			}
			if err := r.refresh(statePath(t)); err == nil {
				t.Fatal("accepted attack")
			}
		})
	}
}

func TestRootRotationAndThreshold(t *testing.T) {
	for _, enough := range []bool{false, true} {
		t.Run(map[bool]string{false: "insufficient signatures", true: "dual threshold rotation"}[enough], func(t *testing.T) {
			r := newRepositoryFixture(t)
			r.root.Signed.Version = 2
			seed := sha256.Sum256([]byte("ASM TEST ROTATED KEY"))
			private := ed25519.NewKeyFromSeed(seed[:])
			signer, err := signature.LoadSignerVerifier(private, crypto.Hash(0))
			must(t, err)
			key, err := metadata.KeyFromPublicKey(private.Public())
			must(t, err)
			oldID := r.root.Signed.Roles["root"].KeyIDs[0]
			must(t, r.root.Signed.RevokeKey(oldID, "root"))
			must(t, r.root.Signed.AddKey(key, "root"))
			signers := []signature.Signer{signer}
			if enough {
				signers = append(signers, r.keys["root"], r.keys["root2"], r.keys["root3"])
			}
			r.files[metadataURL+"/2.root.json"] = signedBytes(t, r.root, signers...)
			state := statePath(t)
			err = r.refresh(state)
			if enough {
				must(t, err)
				delete(r.files, metadataURL+"/2.root.json")
				must(t, r.refresh(state)) // starts at the persisted rotated root
			} else if err == nil {
				t.Fatal("accepted insufficient root signatures")
			}
		})
	}
}

func TestNewTimestampSurvivesLaterFailure(t *testing.T) {
	r := newRepositoryFixture(t)
	state := statePath(t)
	must(t, r.refresh(state))
	old := bytes.Clone(r.files[metadataURL+"/timestamp.json"])
	r.timestamp.Signed.Version = 2
	r.timestamp.Signed.Meta["snapshot.json"].Version = 2
	r.files[metadataURL+"/timestamp.json"] = signedBytes(t, r.timestamp, r.keys["timestamp"])
	if r.refresh(state) == nil {
		t.Fatal("missing snapshot accepted")
	}
	r.files[metadataURL+"/timestamp.json"] = old
	if r.refresh(state) == nil {
		t.Fatal("forgot newer verified timestamp after failure")
	}
}

func TestDarwinAncestorACL(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Darwin ACL contract")
	}
	r := newRepositoryFixture(t)
	state := statePath(t)
	parent := filepath.Dir(state)
	must(t, exec.Command("/bin/chmod", "+a", "everyone allow add_subdirectory", parent).Run())
	t.Cleanup(func() { _ = exec.Command("/bin/chmod", "-N", parent).Run() })
	if r.refresh(state) == nil {
		t.Fatal("accepted writable ancestor ACL")
	}
	must(t, exec.Command("/bin/chmod", "-N", parent).Run())
	must(t, r.refresh(state))
}

func TestRootProfileAndJSON(t *testing.T) {
	if checkRoot(initialRoot, time.Now()) == nil {
		t.Fatal("production root unexpectedly provisioned: update activation tests with ceremony evidence")
	}
	r := newRepositoryFixture(t)
	r.root.Signed.Roles["root"].Threshold = 1
	data := signedBytes(t, r.root, r.keys["root"])
	if checkRoot(data, time.Now()) == nil {
		t.Fatal("weak root accepted")
	}
	for _, data := range []string{`{"a":1,"a":2}`, `{"a":{"b":1,"b":2}}`, `{} {}`, `{"a":`, "", `{"a":1,"\u0061":2}`} {
		if strictJSON([]byte(data)) == nil {
			t.Fatalf("accepted %q", data)
		}
	}
	must(t, strictJSON([]byte(` {"a":[1,true,null,{"b":"c"}]} `)))
	var encoded map[string]any
	must(t, json.Unmarshal(r.anchor, &encoded))
}
