// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors

// asm-verify is a transport and cryptography adapter. Package selection, target
// policy, manifest parsing, and installation remain in the assembly CLI.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/sigstore/sigstore-go/pkg/bundle"
	"github.com/sigstore/sigstore-go/pkg/root"
	sigtuf "github.com/sigstore/sigstore-go/pkg/tuf"
	"github.com/sigstore/sigstore-go/pkg/verify"
	"github.com/theupdateframework/go-tuf/v2/metadata"
)

const (
	repository   = "https://github.com/stubbi/asm"
	repositoryID = "1441332955"
	workflow     = repository + "/.github/workflows/release.yml@refs/heads/main"
	issuer       = "https://token.actions.githubusercontent.com"
	predicate    = "https://slsa.dev/provenance/v1"
	metadataURL  = "https://asm.build/trust/v1/metadata"
	targetsURL   = "https://asm.build/trust/v1/targets"
	maxMetadata  = 1 << 20
	maxArtifact  = 64 << 20
)

// An empty file deliberately prevents activation before the offline root
// ceremony. Never substitute a generated development key for this trust anchor.
//
//go:embed trust/asm-root.json
var initialRoot []byte

var commitPattern = regexp.MustCompile(`^[0-9a-f]{40}$`)

func main() {
	// Bound the complete operation, including all metadata fetches. The assembly
	// caller also enforces a child deadline independently of this process.
	ctx, cancel := context.WithTimeout(context.Background(), 110*time.Second)
	defer cancel()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "asm verification:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) == 1 && args[0] == "--version" {
		fmt.Println("asm-verify 1")
		return nil
	}
	if len(args) == 2 && args[0] == "check-root" {
		data, err := readRegular(args[1], maxMetadata)
		if err != nil {
			return err
		}
		return checkRoot(data, time.Now())
	}
	if len(args) == 4 && args[0] == "provenance" {
		if args[3] != "-" && !commitPattern.MatchString(args[3]) {
			return errors.New("expected a full source commit")
		}
		artifact, err := readRegular(args[1], maxArtifact)
		if err != nil {
			return err
		}
		encoded, err := readRegular(args[2], maxMetadata)
		if err != nil {
			return err
		}
		if err := strictJSON(encoded); err != nil {
			return err
		}
		var b bundle.Bundle
		if err := json.Unmarshal(encoded, &b); err != nil {
			return err
		}
		// Explicit public-good root, mirror, and bounded transport. No custom CA,
		// trust-root URL, token, GitHub account, or tool configuration is accepted.
		opts := sigtuf.DefaultOptions().WithContext(ctx).WithDisableLocalCache()
		opts.Fetcher = newFetcher(ctx)
		client, err := sigtuf.New(opts)
		if err != nil {
			return err
		}
		trusted, err := root.GetTrustedRoot(client)
		if err != nil {
			return err
		}
		if err := verifyProvenance(&b, artifact, args[3], trusted); err != nil {
			return err
		}
		fmt.Println(repositoryID)
		return nil
	}
	if len(args) == 4 && args[0] == "metadata" {
		if args[2] != "index.tsv" && args[2] != "index-macos.tsv" {
			return errors.New("unsupported metadata target")
		}
		return withRepository(ctx, args[1], func(r *trustedRepository) error {
			data, err := r.download(args[2])
			if err != nil {
				return err
			}
			return writeExclusive(args[3], data)
		})
	}
	if len(args) == 4 && args[0] == "authorize" {
		if !artifactName.MatchString(args[2]) {
			return errors.New("unsupported release target")
		}
		data, err := readRegular(args[3], maxArtifact)
		if err != nil {
			return err
		}
		return withRepository(ctx, args[1], func(r *trustedRepository) error {
			target, err := r.updater.GetTargetInfo(args[2])
			if err != nil {
				return err
			}
			if target == nil {
				return errors.New("release is not authorized by current targets")
			}
			return target.VerifyLengthHashes(data)
		})
	}
	return errors.New("expected provenance FILE BUNDLE COMMIT, metadata STATE NAME OUTPUT, or authorize STATE NAME FILE")
}

func verifyProvenance(b *bundle.Bundle, artifact []byte, commit string, trusted root.TrustedMaterial) error {
	v, err := verify.NewVerifier(trusted, verify.WithSignedCertificateTimestamps(1),
		verify.WithTransparencyLog(1), verify.WithObserverTimestamps(1))
	if err != nil {
		return err
	}
	id, err := verify.NewShortCertificateIdentity(issuer, "", workflow, "")
	if err != nil {
		return err
	}
	digest := sha256.Sum256(artifact)
	result, err := v.Verify(b, verify.NewPolicy(verify.WithArtifactDigest("sha256", digest[:]), verify.WithCertificateIdentity(id)))
	if err != nil {
		return err
	}
	return checkProvenanceResult(result, commit)
}

func checkProvenanceResult(result *verify.VerificationResult, commit string) error {
	if result.Signature == nil || result.Signature.Certificate == nil || result.Statement == nil {
		return errors.New("missing verified certificate or provenance statement")
	}
	c := result.Signature.Certificate
	if c.SourceRepositoryURI != repository || c.SourceRepositoryIdentifier != repositoryID ||
		c.SourceRepositoryRef != "refs/heads/main" || c.RunnerEnvironment != "github-hosted" ||
		c.BuildSignerURI != workflow || result.Statement.PredicateType != predicate {
		return errors.New("release provenance does not match asm's publisher policy")
	}
	if !commitPattern.MatchString(c.SourceRepositoryDigest) || c.BuildSignerDigest != c.SourceRepositoryDigest {
		return errors.New("source and signer commits differ")
	}
	if commit != "-" && c.SourceRepositoryDigest != commit {
		return errors.New("provenance does not match the selected source commit")
	}
	return nil
}

// Reject duplicate keys before either library decodes signed JSON. Keep depth
// and input size bounded; a second value or trailing non-whitespace is invalid.
func strictJSON(data []byte) error {
	if len(data) == 0 || len(data) > maxMetadata {
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

// The protocol library controls signature, rotation, expiry and rollback
// checks. This fetcher adds a total deadline, HTTPS-only redirects and bounds.
type boundedFetcher struct {
	ctx    context.Context
	client *http.Client
}

func newFetcher(ctx context.Context) *boundedFetcher {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// A clean environment is supplied by the caller. Proxies affect routing;
	// neither TLS nor signature checks are replaced by proxy configuration.
	transport.TLSHandshakeTimeout = 10 * time.Second
	return &boundedFetcher{ctx: ctx, client: &http.Client{Transport: transport, Timeout: 30 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 4 || req.URL.Scheme != "https" || req.URL.User != nil {
				return errors.New("refused metadata redirect")
			}
			return nil
		}}}
}

func (f *boundedFetcher) DownloadFile(address string, limit int64, _ time.Duration) ([]byte, error) {
	u, err := url.Parse(address)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Fragment != "" {
		return nil, errors.New("metadata requires HTTPS")
	}
	if limit <= 0 || limit > maxMetadata {
		limit = maxMetadata
	}
	req, err := http.NewRequestWithContext(f.ctx, "GET", address, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "asm-verify/1")
	response, err := f.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, &metadata.ErrDownloadHTTP{StatusCode: response.StatusCode, URL: address}
	}
	if response.ContentLength > limit {
		return nil, errors.New("metadata exceeds byte limit")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, errors.New("metadata exceeds byte limit")
	}
	if strings.HasSuffix(u.Path, ".json") {
		if err := strictJSON(data); err != nil {
			return nil, err
		}
	}
	return data, nil
}

func digestString(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}
