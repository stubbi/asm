// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"context"
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata"
	"github.com/theupdateframework/go-tuf/v2/metadata/config"
	"github.com/theupdateframework/go-tuf/v2/metadata/fetcher"
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
		return fmt.Errorf("ASM root is not provisioned: %w", err)
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
				return errors.New("ASM root profile requires Ed25519 keys")
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
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return errors.New("another trust refresh is in progress")
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	// No pathname supplied by remote metadata is used for persistent state.
	// Delegated roles are deliberately outside this small self-update profile.
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
	cfg, err := config.New(metadataURL, anchor)
	if err != nil {
		return err
	}
	cfg.LocalMetadataDir = state
	cfg.LocalTargetsDir = state
	cfg.RemoteTargetsURL = targetsURL
	cfg.Fetcher = transport
	cfg.RootMaxLength, cfg.TimestampMaxLength = maxMetadata, 16384
	cfg.SnapshotMaxLength, cfg.TargetsMaxLength = maxMetadata, maxMetadata
	cfg.MaxRootRotations, cfg.MaxDelegations = 32, 0
	u, err := updater.New(cfg)
	if err != nil {
		return err
	}
	refreshErr := u.Refresh()
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
		err = f.Sync()
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

// openState walks each component without following symlinks. Root-owned sticky
// /tmp (or /private/tmp) is allowed only above a protected user-owned child.
// Same-account mutation and an administrator remain outside this boundary.
func openState(path string) (*os.File, error) {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path || path == "/" {
		return nil, errors.New("trust state requires a clean absolute path")
	}
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	prefix := ""
	needOwned := false
	for i, part := range parts {
		prefix += "/" + part
		next, err := unix.Openat(fd, part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if err == unix.ENOENT && i == len(parts)-1 {
			if err = unix.Mkdirat(fd, part, 0700); err == nil {
				next, err = unix.Openat(fd, part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
			}
		}
		unix.Close(fd)
		if err != nil {
			return nil, err
		}
		fd = next
		var st unix.Stat_t
		if err = unix.Fstat(fd, &st); err != nil {
			unix.Close(fd)
			return nil, err
		}
		owned := st.Uid == uint32(os.Getuid())
		sticky := st.Uid == 0 && st.Mode&unix.S_ISVTX != 0 && (prefix == "/tmp" || prefix == "/private/tmp")
		if (!owned && st.Uid != 0) || (needOwned && (!owned || st.Mode&0022 != 0)) ||
			(st.Mode&0022 != 0 && !sticky) || (i == len(parts)-1 && (!owned || st.Mode&0077 != 0)) {
			unix.Close(fd)
			return nil, errors.New("trust state has unsafe ownership or directory permissions")
		}
		needOwned = sticky
	}
	directory := os.NewFile(uintptr(fd), path)
	if err := platformPermissions(directory); err != nil {
		directory.Close()
		return nil, err
	}
	return directory, nil
}

func openFile(path string, flags int, mode uint32) (*os.File, error) {
	fd, err := unix.Open(path, flags|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, mode)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path)
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	st := info.Sys().(*syscall.Stat_t)
	if !info.Mode().IsRegular() || st.Nlink != 1 || st.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0022 != 0 {
		f.Close()
		return nil, errors.New("expected an owned regular file with one link and protected permissions")
	}
	if err := platformPermissions(f); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
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

func atomicWrite(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".trust-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	err = errors.Join(err, f.Close())
	if err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
