// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata"
	"github.com/theupdateframework/go-tuf/v2/metadata/config"
	"github.com/theupdateframework/go-tuf/v2/metadata/updater"
)

const registryTimestampLifetime = 5 * time.Minute

var errFullRegistryRefresh = errors.New("full registry refresh required")

func setRegistryCheckpoint(timestamp *metadata.TimestampType, id string, now time.Time) {
	issued := now.UTC().Truncate(time.Second)
	timestamp.Expires = issued.Add(registryTimestampLifetime)
	timestamp.UnrecognizedFields = map[string]any{
		"asm_registry_id": id, "asm_issued_at": issued.Format(time.RFC3339),
	}
}

// A timestamp renewal signs no package bytes and fetches nothing. It retains
// the exact root, targets and snapshot and uses only the online timestamp key.
// A changed root or roles near expiry need the full, separately checked path.
func refreshRegistry(rootPath, keys, previous, output, id string, version int64) error {
	if !registryIdentity.MatchString(id) || version < 1 {
		return errors.New("invalid registry refresh identity or version")
	}
	if _, err := os.Lstat(output); !os.IsNotExist(err) {
		return errors.New("output must be a new directory")
	}
	rootBytes, err := readJSON(rootPath, 1<<20)
	if err != nil {
		return err
	}
	r, err := metadata.Root().FromBytes(rootBytes)
	if err != nil {
		return err
	}
	if err := r.VerifyDelegate("root", r); err != nil {
		return err
	}
	if err := registryRootProfile(r.Signed); err != nil {
		return err
	}
	now := time.Now().UTC()
	if r.Signed.Type != "root" || !r.Signed.ConsistentSnapshot || !r.Signed.Expires.After(now) || r.Signed.Version < 1 {
		return errors.New("registry root is not current")
	}
	oldRootBytes, err := readJSON(filepath.Join(previous, "metadata/root.json"), 1<<20)
	if err != nil {
		return err
	}
	verificationRoot := r
	rootRotation := !bytes.Equal(rootBytes, oldRootBytes)
	if rootRotation {
		old, err := metadata.Root().FromBytes(oldRootBytes)
		if err != nil {
			return err
		}
		if err := old.VerifyDelegate("root", old); err != nil {
			return err
		}
		if err := registryRootProfile(old.Signed); err != nil {
			return err
		}
		if old.Signed.Type != "root" || !old.Signed.ConsistentSnapshot || old.Signed.Version < 1 {
			return errors.New("retained root is outside the registry profile")
		}
		if r.Signed.Version != old.Signed.Version+1 {
			return errors.New("registry root changed without a sequential rotation")
		}
		if err := old.VerifyDelegate("root", r); err != nil {
			return err
		}
		verificationRoot = old
	}
	timestampBytes, err := readJSON(filepath.Join(previous, "metadata/timestamp.json"), 16384)
	if err != nil {
		return err
	}
	oldTimestamp, err := metadata.Timestamp().FromBytes(timestampBytes)
	if err != nil {
		return err
	}
	if err := verificationRoot.VerifyDelegate("timestamp", oldTimestamp); err != nil {
		return err
	}
	issuedText, issuedOK := oldTimestamp.Signed.UnrecognizedFields["asm_issued_at"].(string)
	issued, issueErr := time.Parse(time.RFC3339, issuedText)
	if oldTimestamp.Signed.UnrecognizedFields["asm_registry_id"] != id || !issuedOK || issueErr != nil ||
		issued.UTC().Format(time.RFC3339) != issuedText || issued.After(now.Add(30*time.Second)) ||
		!oldTimestamp.Signed.Expires.After(issued) || oldTimestamp.Signed.Expires.After(issued.Add(registryTimestampLifetime)) {
		return errors.New("retained timestamp is outside the scoped registry checkpoint profile")
	}
	if version <= oldTimestamp.Signed.Version || oldTimestamp.Signed.Version < 1 {
		return errors.New("timestamp version must exceed its retained version")
	}
	snapshotBytes, err := readJSON(filepath.Join(previous, "metadata/snapshot.json"), 1<<20)
	if err != nil {
		return err
	}
	snapshot, err := metadata.Snapshot().FromBytes(snapshotBytes)
	if err != nil {
		return err
	}
	if err := verificationRoot.VerifyDelegate("snapshot", snapshot); err != nil {
		return err
	}
	targetsBytes, err := readJSON(filepath.Join(previous, "metadata/targets.json"), 1<<20)
	if err != nil {
		return err
	}
	targets, err := metadata.Targets().FromBytes(targetsBytes)
	if err != nil {
		return err
	}
	if err := verificationRoot.VerifyDelegate("targets", targets); err != nil {
		return err
	}
	if oldTimestamp.Signed.Type != "timestamp" || snapshot.Signed.Type != "snapshot" || targets.Signed.Type != "targets" ||
		len(oldTimestamp.Signed.Meta) != 1 || len(snapshot.Signed.Meta) != 1 || targets.Signed.Delegations != nil ||
		snapshot.Signed.Version < 1 || targets.Signed.Version < 1 || len(targets.Signed.Targets) == 0 || len(targets.Signed.Targets) > 4096 {
		return errors.New("invalid registry metadata graph")
	}
	if err := refreshBinding(oldTimestamp.Signed.Meta["snapshot.json"], snapshot.Signed.Version, snapshotBytes); err != nil {
		return err
	}
	if err := refreshBinding(snapshot.Signed.Meta["targets.json"], targets.Signed.Version, targetsBytes); err != nil {
		return err
	}
	for name, target := range targets.Signed.Targets {
		if !safeRegistryTarget(id, name) || target == nil || target.Length < 1 || target.Length > 1<<20 ||
			len(target.Hashes) != 1 || len(target.Hashes["sha256"]) != 32 {
			return errors.New("retained targets belong to another registry profile")
		}
	}
	timestamp := metadata.Timestamp(now.Add(registryTimestampLifetime))
	setRegistryCheckpoint(&timestamp.Signed, id, now)
	timestamp.Signed.Version = version
	timestamp.Signed.Meta["snapshot.json"] = binding(snapshot.Signed.Version, snapshotBytes)
	key, err := signer(filepath.Join(keys, "timestamp.pem"))
	if err != nil {
		return err
	}
	if _, err := timestamp.Sign(key); err != nil {
		return err
	}
	if err := r.VerifyDelegate("timestamp", timestamp); err != nil {
		return err
	}
	// An expired prior timestamp can be renewed by its authorized signer. It
	// cannot make an expired/near-expiry snapshot or targets role usable again.
	if rootRotation || !snapshot.Signed.Expires.After(now.Add(24*time.Hour)) || !targets.Signed.Expires.After(now.Add(24*time.Hour)) {
		return errFullRegistryRefresh
	}
	encoded, err := timestamp.ToBytes(false)
	if err != nil {
		return err
	}
	if len(encoded) > 16384 {
		return errors.New("registry timestamp exceeds its client bound")
	}
	stage, err := os.MkdirTemp(filepath.Dir(output), ".asm-trust-refresh-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	if err := retainRegistryRoots(previous, stage); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(stage, "metadata"), 0700); err != nil {
		return err
	}
	versionedRoot := fmt.Sprintf("%d.root.json", r.Signed.Version)
	current, err := readJSON(filepath.Join(stage, "metadata", versionedRoot), 1<<20)
	if err != nil || !bytes.Equal(current, rootBytes) {
		return errors.New("retained versioned root differs from the current root")
	}
	files := map[string][]byte{
		"root.json": rootBytes, "targets.json": targetsBytes, "snapshot.json": snapshotBytes,
		"timestamp.json": encoded, fmt.Sprintf("%d.targets.json", targets.Signed.Version): targetsBytes,
		fmt.Sprintf("%d.snapshot.json", snapshot.Signed.Version): snapshotBytes,
		fmt.Sprintf("%d.timestamp.json", version):                encoded,
	}
	for name, data := range files {
		if err := exclusive(filepath.Join(stage, "metadata", name), data); err != nil {
			return err
		}
	}
	if err := inspectRegistryGraph(rootBytes, stage); err != nil {
		return err
	}
	if _, err := os.Lstat(output); !os.IsNotExist(err) {
		return errors.New("output appeared during registry refresh")
	}
	return os.Rename(stage, output)
}

// Require all graph bindings. The library accepts optional hash/length fields
// for other TUF profiles; this registry profile always emits both SHA256 and size.
func refreshBinding(meta *metadata.MetaFiles, version int64, data []byte) error {
	if meta == nil || meta.Version != version || meta.Length != int64(len(data)) || len(meta.Hashes) != 1 || len(meta.Hashes["sha256"]) != 32 {
		return errors.New("registry metadata binding is incomplete")
	}
	return meta.VerifyLengthHashes(data)
}

// Validate the complete fresh root→timestamp→snapshot→targets graph with the
// maintained updater. Its fixed local fetcher cannot make a network request,
// and Refresh does not download any target payload.
func inspectRegistryGraph(anchor []byte, directory string) error {
	cfg, err := config.New("https://publication.invalid/metadata", anchor)
	if err != nil {
		return err
	}
	cfg.DisableLocalCache = true
	cfg.Fetcher = localMirror(directory)
	cfg.RootMaxLength, cfg.TimestampMaxLength = 1<<20, 16384
	cfg.SnapshotMaxLength, cfg.TargetsMaxLength = 1<<20, 1<<20
	cfg.MaxRootRotations, cfg.MaxDelegations = 32, 0
	u, err := updater.New(cfg)
	if err != nil {
		return err
	}
	return u.Refresh()
}
