// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors

// asm-trust is maintainer tooling. It is never linked into the distributed CLI.
package main

import (
	"bytes"
	"crypto"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/sigstore/sigstore/pkg/signature"
	"github.com/theupdateframework/go-tuf/v2/metadata"
	"github.com/theupdateframework/go-tuf/v2/metadata/config"
	"github.com/theupdateframework/go-tuf/v2/metadata/updater"
)

var allowedTarget = regexp.MustCompile(`^(index(-macos)?\.tsv|asm-[0-9]+\.[0-9]+\.[0-9]+-(x86_64-linux|aarch64-linux|aarch64-macos))$`)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "Asm trust:", err)
		os.Exit(1)
	}
}

func read(path string, limit int64) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() < 1 || info.Size() > limit {
		return nil, errors.New("invalid input file")
	}
	return os.ReadFile(path)
}

// Reject ambiguous signed documents and target maps before decoding.
func strictJSON(data []byte) error {
	if len(data) == 0 || len(data) > 1<<20 {
		return errors.New("invalid JSON size")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var value func(int) error
	value = func(depth int) error {
		if depth > 64 {
			return errors.New("JSON nesting limit exceeded")
		}
		token, err := d.Token()
		if err != nil {
			return err
		}
		open, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		if open != '{' && open != '[' {
			return errors.New("invalid JSON delimiter")
		}
		seen := map[string]bool{}
		for d.More() {
			if open == '{' {
				key, err := d.Token()
				if err != nil {
					return err
				}
				s, ok := key.(string)
				if !ok || seen[s] {
					return errors.New("duplicate or invalid JSON key")
				}
				seen[s] = true
			}
			if err := value(depth + 1); err != nil {
				return err
			}
		}
		_, err = d.Token()
		return err
	}
	if err := value(0); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return errors.New("trailing JSON data")
	}
	return nil
}

func readJSON(path string, limit int64) ([]byte, error) {
	data, err := read(path, limit)
	if err != nil {
		return nil, err
	}
	if err := strictJSON(data); err != nil {
		return nil, err
	}
	return data, nil
}

func signer(path string) (signature.Signer, error) {
	data, err := readPrivateKey(path)
	if err != nil {
		return nil, err
	}
	block, rest := pem.Decode(data)
	if block == nil || block.Type != "PRIVATE KEY" || len(rest) != 0 {
		return nil, errors.New("expected one PKCS8 private key")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	if _, ok := key.(ed25519.PrivateKey); !ok {
		return nil, errors.New("expected Ed25519 key")
	}
	return signature.LoadSignerVerifier(key, crypto.Hash(0))
}

func exclusive(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	return errors.Join(err, f.Close())
}

func run(args []string) error {
	if len(args) == 4 && args[0] == "inspect" {
		return inspect(args[1], args[2], args[3])
	}
	if len(args) == 8 && args[0] == "prepare-root" {
		r := metadata.Root(time.Now().UTC().Add(365 * 24 * time.Hour))
		for i, role := range []string{"root", "root", "root", "targets", "snapshot", "timestamp"} {
			data, err := read(args[i+2], 16384)
			if err != nil {
				return err
			}
			block, rest := pem.Decode(data)
			if block == nil || block.Type != "PUBLIC KEY" || len(rest) != 0 {
				return errors.New("expected one public key")
			}
			public, err := x509.ParsePKIXPublicKey(block.Bytes)
			if err != nil {
				return err
			}
			if _, ok := public.(ed25519.PublicKey); !ok {
				return errors.New("expected Ed25519 public key")
			}
			key, err := metadata.KeyFromPublicKey(public)
			if err != nil {
				return err
			}
			if err := r.Signed.AddKey(key, role); err != nil {
				return err
			}
		}
		r.Signed.Roles["root"].Threshold = 2
		data, err := r.ToBytes(true)
		if err != nil {
			return err
		}
		return exclusive(args[1], data)
	}
	if len(args) == 4 && args[0] == "sign-root" {
		data, err := readJSON(args[1], 1<<20)
		if err != nil {
			return err
		}
		r, err := metadata.Root().FromBytes(data)
		if err != nil {
			return err
		}
		key, err := signer(args[2])
		if err != nil {
			return err
		}
		if _, err := r.Sign(key); err != nil {
			return err
		}
		data, err = r.ToBytes(true)
		if err != nil {
			return err
		}
		return exclusive(args[3], data)
	}
	if len(args) == 6 && args[0] == "publish" {
		return publish(args[1], args[2], args[3], args[4], args[5])
	}
	return errors.New("expected prepare-root OUTPUT ROOT1.pub ROOT2.pub ROOT3.pub TARGETS.pub SNAPSHOT.pub TIMESTAMP.pub; sign-root INPUT KEY OUTPUT; publish ROOT KEY_DIRECTORY PREVIOUS_DIRECTORY_OR_DASH TARGET_MAP OUTPUT_DIRECTORY; or inspect ROOT PUBLICATION TARGET_MAP")
}

// Inspect a staged publication with the same maintained TUF client. A local
// mirror changes transport only; signatures, expiry, versions and hashes stay
// mandatory. This command accepts a maintainer-selected root, never a key from
// the staged publication. It does not install or run an artifact.
func inspect(rootPath, repository, targetMap string) error {
	anchor, err := readJSON(rootPath, 1<<20)
	if err != nil {
		return err
	}
	cfg, err := config.New("https://publication.invalid/metadata", anchor)
	if err != nil {
		return err
	}
	cfg.DisableLocalCache = true
	cfg.RootMaxLength, cfg.TimestampMaxLength = 1<<20, 16384
	cfg.SnapshotMaxLength, cfg.TargetsMaxLength = 1<<20, 1<<20
	cfg.MaxDelegations = 0
	cfg.Fetcher = localMirror(repository)
	u, err := updater.New(cfg)
	if err != nil {
		return err
	}
	if err := u.Refresh(); err != nil {
		return err
	}
	data, err := readJSON(targetMap, 1<<20)
	if err != nil {
		return err
	}
	var files map[string]string
	if err := json.Unmarshal(data, &files); err != nil {
		return err
	}
	for name, path := range files {
		if !allowedTarget.MatchString(name) {
			return errors.New("invalid target name")
		}
		target, err := u.GetTargetInfo(name)
		if err != nil {
			return err
		}
		if target == nil {
			return errors.New("target is absent")
		}
		data, err := read(path, 64<<20)
		if err != nil {
			return err
		}
		if err := target.VerifyLengthHashes(data); err != nil {
			return err
		}
		if name == "index.tsv" || name == "index-macos.tsv" {
			digest := target.Hashes["sha256"]
			if len(digest) != 32 {
				return errors.New("index requires SHA-256")
			}
			stored, err := read(filepath.Join(repository, "targets", hex.EncodeToString(digest)+"."+name), 1<<20)
			if err != nil {
				return err
			}
			if err := target.VerifyLengthHashes(stored); err != nil {
				return err
			}
		}
	}
	return nil
}

type localMirror string

func (dir localMirror) DownloadFile(address string, limit int64, _ time.Duration) ([]byte, error) {
	name, ok := strings.CutPrefix(address, "https://publication.invalid/metadata/")
	if !ok || filepath.Base(name) != name {
		return nil, errors.New("invalid metadata path")
	}
	data, err := readJSON(filepath.Join(string(dir), "metadata", name), limit)
	if os.IsNotExist(err) {
		return nil, &metadata.ErrDownloadHTTP{StatusCode: 404, URL: address}
	}
	return data, err
}

func publish(rootPath, keys, previous, targetMap, output string) error {
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
	if !r.Signed.ConsistentSnapshot || !r.Signed.Expires.After(time.Now()) || r.Signed.Roles["root"].Threshold < 2 {
		return errors.New("expected current threshold root with consistent snapshots")
	}
	if _, err := os.Lstat(output); !os.IsNotExist(err) {
		return errors.New("output must be a new directory")
	}
	now := time.Now().UTC()
	targets := metadata.Targets(now.Add(30 * 24 * time.Hour))
	snapshot := metadata.Snapshot(now.Add(7 * 24 * time.Hour))
	timestamp := metadata.Timestamp(now.Add(24 * time.Hour))
	if previous != "-" {
		oldRootBytes, err := readJSON(filepath.Join(previous, "metadata/root.json"), 1<<20)
		if err != nil {
			return err
		}
		oldRoot, err := metadata.Root().FromBytes(oldRootBytes)
		if err != nil {
			return err
		}
		if oldRoot.Signed.Version != r.Signed.Version && oldRoot.Signed.Version+1 != r.Signed.Version {
			return errors.New("root versions must be equal or sequential")
		}
		if err := oldRoot.VerifyDelegate("root", r); err != nil {
			return err
		}
		if oldRoot.Signed.Version == r.Signed.Version && string(oldRootBytes) != string(rootBytes) {
			return errors.New("existing root bytes are immutable")
		}
		data, err := readJSON(filepath.Join(previous, "metadata/targets.json"), 1<<20)
		if err != nil {
			return err
		}
		oldTargets, err := metadata.Targets().FromBytes(data)
		if err != nil {
			return err
		}
		if err := oldRoot.VerifyDelegate("targets", oldTargets); err != nil {
			return err
		}
		targets.Signed.Version = oldTargets.Signed.Version + 1
		data, err = readJSON(filepath.Join(previous, "metadata/snapshot.json"), 1<<20)
		if err != nil {
			return err
		}
		oldSnapshot, err := metadata.Snapshot().FromBytes(data)
		if err != nil {
			return err
		}
		if err := oldRoot.VerifyDelegate("snapshot", oldSnapshot); err != nil {
			return err
		}
		snapshot.Signed.Version = oldSnapshot.Signed.Version + 1
		data, err = readJSON(filepath.Join(previous, "metadata/timestamp.json"), 1<<20)
		if err != nil {
			return err
		}
		oldTimestamp, err := metadata.Timestamp().FromBytes(data)
		if err != nil {
			return err
		}
		if err := oldRoot.VerifyDelegate("timestamp", oldTimestamp); err != nil {
			return err
		}
		timestamp.Signed.Version = oldTimestamp.Signed.Version + 1
	}
	data, err := readJSON(targetMap, 1<<20)
	if err != nil {
		return err
	}
	var files map[string]string
	if err := json.Unmarshal(data, &files); err != nil {
		return err
	}
	if files["index.tsv"] == "" || len(files) > 4096 {
		return errors.New("target map requires an index and at most 4096 targets")
	}
	stage, err := os.MkdirTemp(filepath.Dir(output), ".asm-trust-publication-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	if previous != "-" {
		if err := filepath.WalkDir(previous, func(path string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			rel, err := filepath.Rel(previous, path)
			if err != nil {
				return err
			}
			dest := filepath.Join(stage, rel)
			if entry.IsDir() {
				return os.MkdirAll(dest, 0700)
			}
			data, err := read(path, 1<<20)
			if err != nil {
				return err
			}
			return exclusive(dest, data)
		}); err != nil {
			return err
		}
	}
	for _, dir := range []string{"metadata", "targets"} {
		if err := os.MkdirAll(filepath.Join(stage, dir), 0700); err != nil {
			return err
		}
	}
	for name, path := range files {
		if !allowedTarget.MatchString(name) {
			return errors.New("invalid target name")
		}
		data, err := read(path, 64<<20)
		if err != nil {
			return err
		}
		h := sha256.Sum256(data)
		targets.Signed.Targets[name] = &metadata.TargetFiles{Length: int64(len(data)), Hashes: metadata.Hashes{"sha256": h[:]}}
		if name == "index.tsv" || name == "index-macos.tsv" {
			if len(data) > 1<<20 {
				return errors.New("index exceeds client limit")
			}
			dest := filepath.Join(stage, "targets", hex.EncodeToString(h[:])+"."+name)
			if old, err := os.ReadFile(dest); err == nil {
				if string(old) != string(data) {
					return errors.New("immutable target changed")
				}
			} else if err := exclusive(dest, data); err != nil {
				return err
			}
		}
	}
	for _, name := range []string{"targets", "snapshot", "timestamp"} {
		key, err := signer(filepath.Join(keys, name+".pem"))
		if err != nil {
			return err
		}
		var encoded []byte
		var version int64
		switch name {
		case "targets":
			_, err = targets.Sign(key)
			if err == nil {
				err = r.VerifyDelegate(name, targets)
			}
			if err == nil {
				encoded, err = targets.ToBytes(false)
			}
			version = targets.Signed.Version
			snapshot.Signed.Meta["targets.json"] = binding(version, encoded)
		case "snapshot":
			_, err = snapshot.Sign(key)
			if err == nil {
				err = r.VerifyDelegate(name, snapshot)
			}
			if err == nil {
				encoded, err = snapshot.ToBytes(false)
			}
			version = snapshot.Signed.Version
			timestamp.Signed.Meta["snapshot.json"] = binding(version, encoded)
		case "timestamp":
			_, err = timestamp.Sign(key)
			if err == nil {
				err = r.VerifyDelegate(name, timestamp)
			}
			if err == nil {
				encoded, err = timestamp.ToBytes(false)
			}
		}
		if err != nil {
			return err
		}
		if len(encoded) > 1<<20 {
			return errors.New("metadata exceeds client limit")
		}
		if name != "timestamp" {
			if err := exclusive(filepath.Join(stage, "metadata", fmt.Sprintf("%d.%s.json", version, name)), encoded); err != nil {
				return err
			}
		}
		if err := os.WriteFile(filepath.Join(stage, "metadata", name+".json"), encoded, 0600); err != nil {
			return err
		}
	}
	versionedRoot := filepath.Join(stage, "metadata", fmt.Sprintf("%d.root.json", r.Signed.Version))
	if old, err := os.ReadFile(versionedRoot); err == nil {
		if string(old) != string(rootBytes) {
			return errors.New("immutable root changed")
		}
	} else if err := exclusive(versionedRoot, rootBytes); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(stage, "metadata/root.json"), rootBytes, 0600); err != nil {
		return err
	}
	return os.Rename(stage, output)
}

func binding(version int64, data []byte) *metadata.MetaFiles {
	h := sha256.Sum256(data)
	return &metadata.MetaFiles{Version: version, Length: int64(len(data)), Hashes: metadata.Hashes{"sha256": h[:]}}
}
