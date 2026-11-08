// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"bytes"
	"context"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata"
)

const testRegistryID = "0123456789abcdef0123456789abcdef"

// Exercise the command boundary with real HTTPS and signed TUF bytes. The
// fixture remaps transport addresses only; it does not replace verification.
func registryFixture(t *testing.T, beforeTarget ...func()) (*repositoryFixture, []string) {
	t.Helper()
	r := newRepositoryFixture(t)
	issued := time.Now().UTC().Truncate(time.Second)
	r.timestamp.Signed.Expires = issued.Add(5 * time.Minute)
	r.timestamp.Signed.UnrecognizedFields = map[string]any{
		"asm_registry_id": testRegistryID, "asm_issued_at": issued.Format(time.RFC3339),
	}
	name := "registries/" + testRegistryID + "/policy.tsv"
	data := []byte("private fixture policy bytes\n")
	r.targets.Signed.Targets = map[string]*metadata.TargetFiles{name: targetBytes(data)}
	r.files[targetsURL+"/registries/"+testRegistryID+"/"+digestString(data)+".policy.tsv"] = data
	r.publish()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		var address string
		path := strings.TrimPrefix(req.URL.Path, "/alternate")
		switch {
		case strings.HasPrefix(path, "/metadata/"):
			address = metadataURL + strings.TrimPrefix(path, "/metadata")
		case strings.HasPrefix(path, "/targets/"):
			if len(beforeTarget) > 0 {
				beforeTarget[0]()
			}
			address = targetsURL + strings.TrimPrefix(path, "/targets")
		default:
			http.NotFound(w, req)
			return
		}
		data, ok := r.files[address]
		if !ok {
			http.NotFound(w, req)
			return
		}
		_, _ = w.Write(data)
	}))
	t.Cleanup(server.Close)
	dir := filepath.Dir(statePath(t))
	root, ca := filepath.Join(dir, "registry-root.json"), filepath.Join(dir, "ca.pem")
	must(t, os.WriteFile(root, r.anchor, 0600))
	must(t, os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}), 0600))
	return r, []string{"registry-target", root, filepath.Join(dir, "registry-state"), testRegistryID,
		server.URL, name, filepath.Join(dir, "result"), ca}
}

func TestRegistryTargetHTTPSAndExclusiveOutput(t *testing.T) {
	_, args := registryFixture(t)
	must(t, run(context.Background(), args))
	data, err := os.ReadFile(args[6])
	must(t, err)
	if string(data) != "private fixture policy bytes\n" {
		t.Fatal("authenticated target bytes changed")
	}
	if err := run(context.Background(), args); err == nil {
		t.Fatal("replaced an existing caller output")
	}
	after, err := os.ReadFile(args[6])
	must(t, err)
	if !bytes.Equal(data, after) {
		t.Fatal("existing output changed after refusal")
	}
	must(t, os.Remove(args[6]))
	args[4] += "/alternate"
	must(t, run(context.Background(), args))
}

func TestRegistryTargetRejectsCrossRegistryStateBeforeRefresh(t *testing.T) {
	r, args := registryFixture(t)
	must(t, run(context.Background(), args))
	if err := r.refresh(args[2]); err == nil {
		t.Fatal("legacy update profile adopted registry state")
	}
	must(t, os.Remove(args[6]))
	before, err := os.ReadFile(filepath.Join(args[2], "root.json"))
	must(t, err)
	args[3] = strings.Repeat("f", 32)
	args[5] = "registries/" + args[3] + "/policy.tsv"
	if err := run(context.Background(), args); err == nil {
		t.Fatal("reused another registry's trust state")
	}
	args[3], args[5] = testRegistryID, "registries/"+testRegistryID+"/policy.tsv"
	r.root.Signed.Version = 2
	otherRoot := signedBytes(t, r.root, r.keys["root"], r.keys["root2"])
	must(t, os.WriteFile(args[1], otherRoot, 0600))
	if err := run(context.Background(), args); err == nil {
		t.Fatal("silently replaced the registry's initial trust anchor")
	}
	after, err := os.ReadFile(filepath.Join(args[2], "root.json"))
	must(t, err)
	if !bytes.Equal(before, after) {
		t.Fatal("refused profile changed cached trust")
	}
}

func TestRegistryProfileRecoversRotatedOnlineKeyAtSelectedMirror(t *testing.T) {
	r, args := registryFixture(t)
	r.timestamp.Signed.Version = 100
	r.publish()
	must(t, run(context.Background(), args))
	must(t, os.Remove(args[6]))
	rotateOnlineKey(t, r, "timestamp")
	publishRecovery(r)
	must(t, run(context.Background(), args))
	must(t, os.Remove(args[6]))
	must(t, run(context.Background(), args))
}

func TestRegistryRefusesUnboundLegacyState(t *testing.T) {
	_, args := registryFixture(t)
	legacy := newRepositoryFixture(t)
	must(t, legacy.refresh(args[2]))
	if err := run(context.Background(), args); err == nil {
		t.Fatal("registry profile adopted unbound legacy state")
	}
	if _, err := os.Stat(args[6]); !os.IsNotExist(err) {
		t.Fatal("refused state exposed output")
	}
}

func TestRegistryMirrorRetryRetainsNewerVerifiedTimestamp(t *testing.T) {
	r, args := registryFixture(t)
	must(t, run(context.Background(), args))
	must(t, os.Remove(args[6]))
	old := bytes.Clone(r.files[metadataURL+"/timestamp.json"])
	r.timestamp.Signed.Version = 2
	r.timestamp.Signed.Meta["snapshot.json"].Version = 2
	r.files[metadataURL+"/timestamp.json"] = signedBytes(t, r.timestamp, r.keys["timestamp"])
	if run(context.Background(), args) == nil {
		t.Fatal("accepted a missing newer snapshot")
	}
	r.files[metadataURL+"/timestamp.json"] = old
	args[4] += "/alternate"
	if run(context.Background(), args) == nil {
		t.Fatal("mirror retry forgot the previously verified timestamp")
	}
	if _, err := os.Stat(args[6]); !os.IsNotExist(err) {
		t.Fatal("failed trust refresh exposed target output")
	}
}

func TestRegistryTargetRefusesCorruptionAndUnsafeInputs(t *testing.T) {
	for _, attack := range []string{"target bytes", "wrong registry prefix", "dot traversal", "encoded separator", "HTTP", "credentials", "network"} {
		t.Run(attack, func(t *testing.T) {
			r, args := registryFixture(t)
			switch attack {
			case "target bytes":
				for address := range r.files {
					if strings.HasSuffix(address, ".policy.tsv") {
						r.files[address] = []byte("wrong bytes")
					}
				}
			case "wrong registry prefix":
				args[5] = "registries/" + strings.Repeat("f", 32) + "/policy.tsv"
			case "dot traversal":
				args[5] = "registries/" + testRegistryID + "/../policy.tsv"
			case "encoded separator":
				args[5] += "%2fsecret"
			case "HTTP":
				args[4] = "http://127.0.0.1:1"
			case "credentials":
				args[4] = "https://secret@127.0.0.1:1"
			case "network":
				args[4] = "https://127.0.0.1:1"
			}
			if run(context.Background(), args) == nil {
				t.Fatal("accepted " + attack)
			}
			if _, err := os.Stat(args[6]); !os.IsNotExist(err) {
				t.Fatal("failed request exposed target output")
			}
		})
	}
}

func TestRegistryTargetRejectsStaleOrUnscopedSignedCheckpoints(t *testing.T) {
	for _, attack := range []string{"missing-id", "wrong-id", "missing-issued", "issued-future", "issued-stale", "expiry-beyond-window", "noncanonical-issued", "wrong-type"} {
		t.Run(attack, func(t *testing.T) {
			r, args := registryFixture(t)
			issued := time.Now().UTC().Truncate(time.Second)
			switch attack {
			case "missing-id":
				delete(r.timestamp.Signed.UnrecognizedFields, "asm_registry_id")
			case "wrong-id":
				r.timestamp.Signed.UnrecognizedFields["asm_registry_id"] = strings.Repeat("f", 32)
			case "missing-issued":
				delete(r.timestamp.Signed.UnrecognizedFields, "asm_issued_at")
			case "issued-future":
				issued = issued.Add(time.Minute)
				r.timestamp.Signed.UnrecognizedFields["asm_issued_at"] = issued.Format(time.RFC3339)
				r.timestamp.Signed.Expires = issued.Add(5 * time.Minute)
			case "issued-stale":
				// A valid TUF signature and future expiry do not establish age.
				r.timestamp.Signed.UnrecognizedFields["asm_issued_at"] = issued.Add(-6 * time.Minute).Format(time.RFC3339)
				r.timestamp.Signed.Expires = issued.Add(24 * time.Hour)
			case "expiry-beyond-window":
				r.timestamp.Signed.Expires = issued.Add(24 * time.Hour)
			case "noncanonical-issued":
				r.timestamp.Signed.UnrecognizedFields["asm_issued_at"] = issued.Format("2006-01-02T15:04:05+00:00")
			case "wrong-type":
				r.timestamp.Signed.UnrecognizedFields["asm_registry_id"] = 123
			}
			r.publish()
			if run(context.Background(), args) == nil {
				t.Fatal("accepted a signed checkpoint outside the V2 freshness profile: " + attack)
			}
			if _, err := os.Stat(args[6]); !os.IsNotExist(err) {
				t.Fatal("invalid checkpoint exposed target output")
			}
		})
	}
}

func TestRegistryTargetRejectsAmbientCAOverridesBeforeState(t *testing.T) {
	for _, variable := range []string{"SSL_CERT_FILE", "SSL_CERT_DIR"} {
		t.Run(variable, func(t *testing.T) {
			_, args := registryFixture(t)
			t.Setenv(variable, "untrusted-fixture-CA-override")
			if run(context.Background(), args) == nil {
				t.Fatal("accepted ambient CA configuration")
			}
			if _, err := os.Lstat(args[2]); !os.IsNotExist(err) {
				t.Fatal("ambient CA refusal changed trust state")
			}
		})
	}
}

func TestRegistryCheckpointMirrorRefusalDoesNotPoisonTimestampCache(t *testing.T) {
	r, args := registryFixture(t)
	r.timestamp.Signed.Version = 1000
	r.timestamp.Signed.UnrecognizedFields["asm_registry_id"] = strings.Repeat("f", 32)
	r.publish()
	if run(context.Background(), args) == nil {
		t.Fatal("accepted another registry checkpoint")
	}
	r.timestamp.Signed.Version = 1
	r.timestamp.Signed.UnrecognizedFields["asm_registry_id"] = testRegistryID
	r.publish()
	args[4] += "/alternate"
	must(t, run(context.Background(), args))
}

func TestRegistryCheckpointAgeAndClockSkewBounds(t *testing.T) {
	now := time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)
	for _, sample := range []struct {
		age time.Duration
		ok  bool
	}{{-30 * time.Second, true}, {-31 * time.Second, false}, {299 * time.Second, true}, {300 * time.Second, false}, {301 * time.Second, false}} {
		issued := now.Add(-sample.age)
		timestamp := metadata.Timestamp(issued.Add(5 * time.Minute))
		timestamp.Signed.UnrecognizedFields = map[string]any{
			"asm_registry_id": testRegistryID, "asm_issued_at": issued.Format(time.RFC3339),
		}
		if got := registryCheckpoint(timestamp.Signed, testRegistryID, now) == nil; got != sample.ok {
			t.Fatalf("age %v: accepted=%v, expected=%v", sample.age, got, sample.ok)
		}
	}
}

func TestRegistryTargetCannotOutliveItsVerifiedCheckpointDuringDownload(t *testing.T) {
	started := make(chan struct{}, 1)
	r, args := registryFixture(t, func() {
		select {
		case started <- struct{}{}:
		default:
		}
		time.Sleep(3 * time.Second)
	})
	r.timestamp.Signed.Expires = time.Now().UTC().Add(2 * time.Second)
	r.publish()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if run(ctx, args) == nil {
		t.Fatal("slow target response exposed bytes after the verified checkpoint expired")
	}
	select {
	case <-started:
	default:
		t.Fatal("fixture expired before target download; the delayed response was not exercised")
	}
	if _, err := os.Lstat(args[6]); !os.IsNotExist(err) {
		t.Fatal("expired checkpoint exposed target output")
	}
}
