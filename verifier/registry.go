// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata"
	"github.com/theupdateframework/go-tuf/v2/metadata/fetcher"
)

const registryProfileFile = "registry-profile"
const registryCheckpointAge = 5 * time.Minute
const registryClockSkew = 30 * time.Second

var registryIdentity = regexp.MustCompile(`^[0-9a-f]{32}$`)

// registry-target ROOT STATE ID MIRROR TARGET OUTPUT [CA] authenticates one
// opaque target. The assembly caller owns mirror ordering and package policy.
// ROOT/CA and OUTPUT use owned private parent directories. STATE is durable;
// an existing state with another profile is never adopted or reset.
func registryTarget(ctx context.Context, args []string) error {
	if len(args) != 6 && len(args) != 7 {
		return errors.New("expected registry-target ROOT STATE ID MIRROR TARGET OUTPUT [CA]")
	}
	if os.Getenv("SSL_CERT_FILE") != "" || os.Getenv("SSL_CERT_DIR") != "" {
		return errors.New("registry transport refuses ambient CA overrides; use an explicit CA file")
	}
	rootPath, state, id, base, target, output := args[0], args[1], args[2], args[3], args[4], args[5]
	if !registryIdentity.MatchString(id) || !safeRegistryTarget(id, target) {
		return errors.New("invalid registry identity or target path")
	}
	u, err := url.Parse(base)
	if err != nil || len(base) > 2048 || u.Scheme != "https" || u.Hostname() == "" || u.User != nil ||
		u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.RawPath != "" || u.Opaque != "" ||
		strings.ContainsAny(base, "\\%\r\n\t") {
		return errors.New("registry mirror requires a clean HTTPS base URL")
	}
	base = strings.TrimRight(base, "/")
	for _, path := range []string{rootPath, state, output} {
		if !filepath.IsAbs(path) || filepath.Clean(path) != path {
			return errors.New("registry paths must be clean absolute paths")
		}
	}
	rootDirectory, err := openState(filepath.Dir(rootPath))
	if err != nil {
		return err
	}
	defer rootDirectory.Close()
	anchor, err := readRegular(rootPath, maxMetadata)
	if err != nil {
		return err
	}
	if err := checkRoot(anchor, time.Time{}); err != nil {
		return err
	}
	outputDirectory, err := openState(filepath.Dir(output))
	if err != nil {
		return err
	}
	defer outputDirectory.Close()
	if _, err := os.Lstat(output); !os.IsNotExist(err) {
		return errors.New("registry target output must not exist")
	}
	transport := newFetcher(ctx)
	// Registry transport accepts no ambient proxy or custom CA environment.
	clientTransport := transport.client.Transport.(*http.Transport)
	clientTransport.Proxy = nil
	if len(args) == 7 {
		caPath := args[6]
		if !filepath.IsAbs(caPath) || filepath.Clean(caPath) != caPath {
			return errors.New("CA path must be a clean absolute path")
		}
		caDirectory, err := openState(filepath.Dir(caPath))
		if err != nil {
			return err
		}
		defer caDirectory.Close()
		encoded, err := readRegular(caPath, maxMetadata)
		if err != nil {
			return err
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(encoded) {
			return errors.New("explicit CA file contains no certificates")
		}
		clientTransport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	binding := []byte("asm-registry-v2\t" + id + "\t" + digestString(anchor) + "\n")
	scopedTransport := &registryTimestampFetcher{Fetcher: transport, id: id}
	return useRepositoryAt(anchor, state, base+"/metadata", base+"/targets", scopedTransport, binding,
		func(repository *trustedRepository) error {
			trusted := repository.updater.GetTrustedMetadataSet()
			if trusted.Timestamp == nil {
				return errors.New("registry timestamp is absent")
			}
			if err := registryCheckpoint(trusted.Timestamp.Signed, id, time.Now().UTC()); err != nil {
				return err
			}
			if len(repository.updater.GetTopLevelTargets()) > 4096 {
				return errors.New("registry targets exceed the bounded profile")
			}
			data, err := repository.download(target)
			if err != nil {
				return err
			}
			// A slow target response cannot extend its verified checkpoint.
			if err := registryCheckpoint(trusted.Timestamp.Signed, id, time.Now().UTC()); err != nil {
				return err
			}
			return writeExclusive(output, data)
		})
}

// Reject a wrong-scope or stale untrusted timestamp before its version can
// poison durable rollback state. This prefilter only rejects bytes; the TUF
// updater still authenticates every accepted signature and metadata binding.
type registryTimestampFetcher struct {
	fetcher.Fetcher
	id string
}

func (transport *registryTimestampFetcher) DownloadFile(address string, limit int64, timeout time.Duration) ([]byte, error) {
	data, err := transport.Fetcher.DownloadFile(address, limit, timeout)
	if err != nil || !strings.HasSuffix(address, "/timestamp.json") {
		return data, err
	}
	if err := strictJSON(data); err != nil {
		return nil, err
	}
	timestamp, err := metadata.Timestamp().FromBytes(data)
	if err != nil {
		return nil, err
	}
	if err := registryCheckpoint(timestamp.Signed, transport.id, time.Now().UTC()); err != nil {
		return nil, err
	}
	return data, nil
}

// These fields are covered by the maintained TUF signature verification.
// Expiry alone cannot establish checkpoint age. Permit at most30s of future
// clock skew; require the canonical UTC seconds encoding and a five-minute
// lifetime. Package interpretation remains with the assembly caller.
func registryCheckpoint(timestamp metadata.TimestampType, id string, now time.Time) error {
	scope, scopeOK := timestamp.UnrecognizedFields["asm_registry_id"].(string)
	issuedText, issuedOK := timestamp.UnrecognizedFields["asm_issued_at"].(string)
	if !scopeOK || scope != id || !issuedOK {
		return errors.New("registry timestamp has no matching scoped checkpoint")
	}
	issued, err := time.Parse(time.RFC3339, issuedText)
	if err != nil || issued.UTC().Format(time.RFC3339) != issuedText || issued.After(now.Add(registryClockSkew)) ||
		now.Sub(issued) > registryCheckpointAge || !timestamp.Expires.After(now) ||
		!timestamp.Expires.After(issued) || timestamp.Expires.After(issued.Add(registryCheckpointAge)) {
		return errors.New("registry checkpoint is stale, future-dated, or exceeds its five-minute lifetime")
	}
	return nil
}

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

// Called under the same trust-state lock as all updater writes. Refuse an
// unbound nonempty directory, including legacy self-update state. A mirror URL
// is deliberately absent from this identity: mirrors never reset authority.
func bindRepositoryProfile(state string, directory *stateDirectory, expected []byte) error {
	path := filepath.Join(state, registryProfileFile)
	current, err := readRegular(path, 256)
	if err == nil {
		if len(expected) == 0 || !bytes.Equal(current, expected) {
			return errors.New("trust state belongs to another registry profile")
		}
		return nil
	}
	if !os.IsNotExist(err) {
		return err
	}
	if len(expected) == 0 {
		return nil
	}
	entries, err := os.ReadDir(state)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.Name() != "lock" {
			return errors.New("refusing to adopt unbound trust state")
		}
	}
	if err := writeExclusive(path, expected); err != nil {
		return err
	}
	return directory.Sync()
}
