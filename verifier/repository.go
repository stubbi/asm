// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata"
	"github.com/theupdateframework/go-tuf/v2/metadata/config"
	"github.com/theupdateframework/go-tuf/v2/metadata/fetcher"
	"github.com/theupdateframework/go-tuf/v2/metadata/trustedmetadata"
	"github.com/theupdateframework/go-tuf/v2/metadata/updater"
)

var artifactName = regexp.MustCompile(`^asm-[0-9]+\.[0-9]+\.[0-9]+-(x86_64-linux|aarch64-linux|aarch64-macos)$`)
var roles = []string{"root.json", "timestamp.json", "snapshot.json", "targets.json"}

type trustedRepository struct {
	updater *updater.Updater
	state   string
}

// checkRoot is an activation gate, not a replacement for the library's root
// rotation algorithm. Each signing role has disjoint key material. The offline
// root requires two of three independent keys; online roles cannot replace it.
func checkRoot(data []byte, now time.Time) error {
	if err := strictJSON(data); err != nil {
		return fmt.Errorf("Asm root is not provisioned: %w", err)
	}
	r, err := metadata.Root().FromBytes(data)
	if err != nil {
		return err
	}
	if r.Signed.Type != "root" || !r.Signed.ConsistentSnapshot || !r.Signed.Expires.After(now) {
		return errors.New("root must be current and enable consistent snapshots")
	}
	seen := map[string]bool{}
	for _, name := range []string{"root", "targets", "snapshot", "timestamp"} {
		role, ok := r.Signed.Roles[name]
		if !ok || role.Threshold < 1 || role.Threshold > len(role.KeyIDs) {
			return errors.New("missing or invalid root role")
		}
		if name == "root" && (role.Threshold < 2 || len(role.KeyIDs) < 3) {
			return errors.New("offline root requires at least two of three keys")
		}
		for _, id := range role.KeyIDs {
			key := r.Signed.Keys[id]
			if key == nil || key.Type != "ed25519" || key.Scheme != "ed25519" {
				return errors.New("Asm root profile requires Ed25519 keys")
			}
			material := key.Value.PublicKey
			if seen[material] {
				return errors.New("signing roles must use distinct public keys")
			}
			seen[material] = true
		}
	}
	return r.VerifyDelegate("root", r)
}

func withRepository(ctx context.Context, state string, operation func(*trustedRepository) error) error {
	// The compiled root can expire while cached rotated roots remain current.
	// Bootstrap validation checks signatures/profile here; Refresh checks expiry
	// on the final root after sequentially verifying any rotations.
	if err := checkRoot(initialRoot, time.Time{}); err != nil {
		return err
	}
	return useRepository(initialRoot, state, newFetcher(ctx), operation)
}

func useRepository(anchor []byte, state string, transport fetcher.Fetcher, operation func(*trustedRepository) error) error {
	return useRepositoryAt(anchor, state, metadataURL, targetsURL, transport, nil, operation)
}

// Profiles share the maintained updater and retained recovery rules. Transport
// URLs do not select authority; the caller supplies the independently trusted
// anchor and a durable profile binding before any cached root can be read.
func useRepositoryAt(anchor []byte, state, metadataBase, targetsBase string, transport fetcher.Fetcher, binding []byte, operation func(*trustedRepository) error) error {
	directory, err := openState(state)
	if err != nil {
		return err
	}
	defer directory.Close()
	lock, err := openFile(filepath.Join(state, "lock"), os.O_RDWR|os.O_CREATE, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	unlock, err := acquireStateLock(lock)
	if err != nil {
		return errors.New("another trust refresh is in progress")
	}
	defer unlock()
	if err := bindRepositoryProfile(state, directory, binding); err != nil {
		return err
	}
	// Validate every existing fixed role before the library reads or replaces it.
	// No pathname supplied by remote metadata is used for persistent state.
	// MaxDelegations=0 prevents delegated-role persistence. The pinned updater
	// writes only root.json, timestamp.json, snapshot.json, and targets.json.
	// Windows holds the private directory and its protected ancestors throughout
	// this operation, so unrelated accounts cannot redirect path-based I/O.
	for _, name := range roles {
		data, err := readRegular(filepath.Join(state, name), maxMetadata)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		if err := strictJSON(data); err != nil {
			return err
		}
		if name == "root.json" {
			anchor = data
		}
	}
	clock := filepath.Join(state, "clock")
	if data, err := readRegular(clock, 64); err == nil {
		previous, err := time.Parse(time.RFC3339, string(data))
		if err != nil {
			return err
		}
		if time.Now().Before(previous.Add(-5 * time.Minute)) {
			return errors.New("system clock moved backwards; correct the clock")
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := atomicWrite(clock, []byte(time.Now().UTC().Format(time.RFC3339))); err != nil {
		return err
	}
	// go-tuf v2.4.2 persists rotated roots but does not implement TUF 5.3.11.
	// Flush the last processed root before Refresh can replace root.json.
	// A restart can then finish cleanup even if root persistence was interrupted.
	current, err := trustedmetadata.New(anchor)
	if err != nil {
		return err
	}
	checkpoint := filepath.Join(state, "rotation-root.json")
	previousBytes, err := readRegular(checkpoint, maxMetadata)
	if os.IsNotExist(err) {
		previousBytes = anchor
		if err := atomicWrite(checkpoint, previousBytes); err != nil {
			return err
		}
		if err := directory.Sync(); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	if err := strictJSON(previousBytes); err != nil {
		return err
	}
	previous, err := trustedmetadata.New(previousBytes)
	if err != nil {
		return err
	}
	if current.Root.Signed.Version < previous.Root.Signed.Version {
		return errors.New("cached root predates its recovery checkpoint")
	}
	cfg, err := config.New(metadataBase, anchor)
	if err != nil {
		return err
	}
	cfg.LocalMetadataDir = state
	cfg.LocalTargetsDir = state
	cfg.RemoteTargetsURL = targetsBase
	var u *updater.Updater
	cfg.Fetcher = &checkpointFetcher{checkpoint: directory.Sync, Fetcher: &rotationFetcher{Fetcher: transport, timestampURL: metadataBase + "/timestamp.json", beforeTimestamp: func() error {
		verified := u.GetTrustedMetadataSet()
		if verified.Root.Signed.IsExpired(verified.RefTime) {
			return &metadata.ErrExpiredMetadata{Msg: "final root.json is expired"}
		}
		changed, err := onlineKeysChanged(previous.Root.Signed, verified.Root.Signed)
		if err != nil {
			return err
		}
		if changed {
			return errOnlineKeyRotation
		}
		return nil
	}}}
	cfg.RootMaxLength, cfg.TimestampMaxLength = maxMetadata, 16384
	cfg.SnapshotMaxLength, cfg.TargetsMaxLength = maxMetadata, maxMetadata
	cfg.MaxRootRotations, cfg.MaxDelegations = 32, 0
	u, err = updater.New(cfg)
	if err != nil {
		return err
	}
	refreshErr := u.Refresh()
	if errors.Is(refreshErr, errOnlineKeyRotation) {
		anchor, err = readRegular(filepath.Join(state, "root.json"), maxMetadata)
		if err != nil {
			return err
		}
		if err := completeRootRecovery(state, directory, anchor); err != nil {
			return err
		}
		// The first updater already completed and verified the root phase. Start
		// the online roles again without its in-memory pre-rotation timestamp.
		cfg.LocalTrustedRoot, cfg.Fetcher, cfg.MaxRootRotations = anchor, &checkpointFetcher{Fetcher: transport, checkpoint: directory.Sync}, 0
		u, err = updater.New(cfg)
		if err != nil {
			return err
		}
		refreshErr = u.Refresh()
	}
	// Retain every successfully verified metadata version, even if a later role
	// fails. Restarting must not forget a newer timestamp or completed rotation.
	for _, name := range roles {
		f, err := openFile(filepath.Join(state, name), os.O_RDONLY, 0)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return errors.Join(refreshErr, err)
		}
		err = syncOpenedFile(f)
		err = errors.Join(err, f.Close())
		if err != nil {
			return errors.Join(refreshErr, err)
		}
	}
	if err := directory.Sync(); err != nil {
		return errors.Join(refreshErr, err)
	}
	if refreshErr != nil {
		return refreshErr
	}
	return operation(&trustedRepository{updater: u, state: state})
}

var errOnlineKeyRotation = errors.New("online signing keys rotated")

// Stop before the first remote timestamp fetch, after the maintained client has
// verified and persisted the complete root chain. No rejected network check is
// retried: this sentinel only discards the updater's obsolete in-memory state.
type rotationFetcher struct {
	fetcher.Fetcher
	timestampURL    string
	beforeTimestamp func() error
}

func (f *rotationFetcher) DownloadFile(address string, limit int64, timeout time.Duration) ([]byte, error) {
	if address == f.timestampURL {
		if err := f.beforeTimestamp(); err != nil {
			return nil, err
		}
	}
	return f.Fetcher.DownloadFile(address, limit, timeout)
}

func onlineKeysChanged(previous, current metadata.RootType) (bool, error) {
	for _, role := range []string{"timestamp", "snapshot"} {
		keySet := func(root metadata.RootType) (map[string]bool, error) {
			keys := map[string]bool{}
			if root.Roles[role] == nil {
				return nil, errors.New("missing online signing role")
			}
			for _, id := range root.Roles[role].KeyIDs {
				key := root.Keys[id]
				if key == nil {
					return nil, errors.New("missing online signing key")
				}
				public, err := key.ToPublicKey()
				if err != nil {
					return nil, err
				}
				encoded, err := x509.MarshalPKIXPublicKey(public)
				if err != nil {
					return nil, err
				}
				keys[string(encoded)+":"+key.Scheme] = true
			}
			return keys, nil
		}
		oldKeys, err := keySet(previous)
		if err != nil {
			return false, err
		}
		newKeys, err := keySet(current)
		if err != nil {
			return false, err
		}
		if !maps.Equal(oldKeys, newKeys) {
			return true, nil
		}
	}
	return false, nil
}

// Commit the verified root before removing timestamp/snapshot history. Keep the
// old checkpoint until both removals and the platform flush complete. Process
// interruption repeats cleanup. Hardware power-loss recovery is not promised.
// Targets and the clock observation remain intact.
func completeRootRecovery(state string, directory *stateDirectory, rootBytes []byte) error {
	if err := atomicWrite(filepath.Join(state, "root.json"), rootBytes); err != nil {
		return err
	}
	if err := directory.Sync(); err != nil {
		return err
	}
	for _, name := range []string{"timestamp.json", "snapshot.json"} {
		if err := os.Remove(filepath.Join(state, name)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	if err := directory.Sync(); err != nil {
		return err
	}
	if err := atomicWrite(filepath.Join(state, "rotation-root.json"), rootBytes); err != nil {
		return err
	}
	return directory.Sync()
}

func (r *trustedRepository) download(name string) ([]byte, error) {
	target, err := r.updater.GetTargetInfo(name)
	if err != nil {
		return nil, err
	}
	if target == nil || target.Length < 1 || target.Length > maxMetadata {
		return nil, errors.New("invalid authenticated index size")
	}
	// Use the library's target hash/length and consistent-snapshot checks. The
	// target is cached in the protected state directory, never at the caller's
	// output path until all checks succeed.
	stage, err := os.MkdirTemp(r.state, ".target-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(stage)
	_, data, err := r.updater.DownloadTarget(target, filepath.Join(stage, "index"), "")
	if err != nil {
		return nil, err
	}
	return data, nil
}

func readRegular(path string, limit int64) ([]byte, error) {
	f, err := openFile(path, os.O_RDONLY, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if info.Size() < 1 || info.Size() > limit {
		return nil, errors.New("file exceeds size bounds")
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) != info.Size() {
		return nil, errors.New("file size changed while reading")
	}
	return data, nil
}

func writeExclusive(path string, data []byte) error {
	f, err := openFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	err = errors.Join(err, f.Close())
	if err != nil {
		os.Remove(path)
	}
	return err
}
