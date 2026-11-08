// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata"
)

func refreshFixture(t *testing.T) (string, string, string) {
	t.Helper()
	dir, root, _ := fixture(t)
	targetMap, _ := registryMap(t, dir)
	previous := filepath.Join(dir, "previous")
	check(t, run([]string{"publish-registry", root, dir, "-", targetMap, previous, registryID, "5"}))
	return dir, root, previous
}

func refreshStatus(t *testing.T, root, keys, previous, output, version string) (string, error) {
	t.Helper()
	reader, writer, err := os.Pipe()
	check(t, err)
	old := os.Stdout
	os.Stdout = writer
	defer func() { os.Stdout = old }()
	err = run([]string{"refresh-registry", root, keys, previous, output, registryID, version})
	check(t, writer.Close())
	raw, readErr := io.ReadAll(reader)
	check(t, readErr)
	check(t, reader.Close())
	if err != nil {
		if len(raw) != 0 {
			t.Fatal("failed refresh emitted success output")
		}
		return "", err
	}
	var result map[string]string
	check(t, json.Unmarshal(raw, &result))
	if len(result) != 1 || (result["status"] != "refreshed" && result["status"] != "full-refresh-required") {
		t.Fatalf("invalid refresh status %q", raw)
	}
	return result["status"], nil
}

func TestRegistryTimestampHasFiveMinuteCriticalWindow(t *testing.T) {
	_, _, previous := refreshFixture(t)
	ts, err := metadata.Timestamp().FromFile(filepath.Join(previous, "metadata/timestamp.json"))
	check(t, err)
	remaining := time.Until(ts.Signed.Expires)
	if remaining > 5*time.Minute || remaining < 4*time.Minute {
		t.Fatalf("registry timestamp expiry is %v, expected at most five minutes", remaining)
	}
}

func TestLegacyTimestampRetainsItsExistingWindow(t *testing.T) {
	dir, root, targetMap := fixture(t)
	output := filepath.Join(dir, "legacy")
	check(t, publish(root, dir, "-", targetMap, output))
	ts, err := metadata.Timestamp().FromFile(filepath.Join(output, "metadata/timestamp.json"))
	check(t, err)
	remaining := time.Until(ts.Signed.Expires)
	if remaining > 24*time.Hour || remaining < 23*time.Hour {
		t.Fatalf("legacy timestamp window changed: %v", remaining)
	}
}

type noRefreshNetwork struct{ calls int }

func (transport *noRefreshNetwork) RoundTrip(*http.Request) (*http.Response, error) {
	transport.calls++
	return nil, errors.New("network is forbidden in the offline refresh fixture")
}

func TestTimestampOnlyRefreshPreservesRoleBytesWithoutTargetsOrNetwork(t *testing.T) {
	dir, root, previous := refreshFixture(t)
	check(t, os.RemoveAll(filepath.Join(previous, "targets")))
	for _, name := range []string{"root1", "root2", "root3", "targets", "snapshot"} {
		check(t, os.Remove(filepath.Join(dir, name+".pem")))
	}
	network := &noRefreshNetwork{}
	old := http.DefaultTransport
	http.DefaultTransport = network
	defer func() { http.DefaultTransport = old }()
	output := filepath.Join(dir, "refreshed")
	status, err := refreshStatus(t, root, dir, previous, output, "8")
	check(t, err)
	if status != "refreshed" {
		t.Fatal("routine refresh required full publication")
	}
	for _, name := range []string{"root.json", "targets.json", "snapshot.json", "1.root.json", "5.targets.json", "5.snapshot.json"} {
		before, err := os.ReadFile(filepath.Join(previous, "metadata", name))
		check(t, err)
		after, err := os.ReadFile(filepath.Join(output, "metadata", name))
		check(t, err)
		if !bytes.Equal(before, after) {
			t.Fatal("refresh changed retained role bytes: " + name)
		}
	}
	if _, err := os.Lstat(filepath.Join(output, "targets")); !os.IsNotExist(err) {
		t.Fatal("timestamp-only refresh copied target payloads")
	}
	ts, err := metadata.Timestamp().FromFile(filepath.Join(output, "metadata/8.timestamp.json"))
	check(t, err)
	if ts.Signed.Version != 8 || ts.Signed.Meta["snapshot.json"].Version != 5 || time.Until(ts.Signed.Expires) > 5*time.Minute {
		t.Fatal("refresh lost reserved timestamp or unchanged snapshot binding")
	}
	second := filepath.Join(dir, "second-refresh")
	status, err = refreshStatus(t, root, dir, output, second, "13")
	check(t, err)
	if status != "refreshed" || network.calls != 0 {
		t.Fatalf("refresh touched network or failed: %s, calls=%d", status, network.calls)
	}
}

func rebindRefreshTargets(t *testing.T, dir, previous string, expiry time.Time) {
	t.Helper()
	targets, err := metadata.Targets().FromFile(filepath.Join(previous, "metadata/targets.json"))
	check(t, err)
	targets.Signed.Expires = expiry
	key, err := signer(filepath.Join(dir, "targets.pem"))
	check(t, err)
	targets.Signatures = nil
	_, err = targets.Sign(key)
	check(t, err)
	encoded, err := targets.ToBytes(false)
	check(t, err)
	check(t, os.WriteFile(filepath.Join(previous, "metadata/targets.json"), encoded, 0600))
	check(t, os.WriteFile(filepath.Join(previous, "metadata/5.targets.json"), encoded, 0600))
	snapshot, err := metadata.Snapshot().FromFile(filepath.Join(previous, "metadata/snapshot.json"))
	check(t, err)
	snapshot.Signed.Meta["targets.json"] = binding(5, encoded)
	snapshot.Signatures = nil
	key, err = signer(filepath.Join(dir, "snapshot.pem"))
	check(t, err)
	_, err = snapshot.Sign(key)
	check(t, err)
	encoded, err = snapshot.ToBytes(false)
	check(t, err)
	check(t, os.WriteFile(filepath.Join(previous, "metadata/snapshot.json"), encoded, 0600))
	check(t, os.WriteFile(filepath.Join(previous, "metadata/5.snapshot.json"), encoded, 0600))
	ts, err := metadata.Timestamp().FromFile(filepath.Join(previous, "metadata/timestamp.json"))
	check(t, err)
	ts.Signed.Meta["snapshot.json"] = binding(5, encoded)
	ts.Signatures = nil
	key, err = signer(filepath.Join(dir, "timestamp.pem"))
	check(t, err)
	_, err = ts.Sign(key)
	check(t, err)
	encoded, err = ts.ToBytes(false)
	check(t, err)
	check(t, os.WriteFile(filepath.Join(previous, "metadata/timestamp.json"), encoded, 0600))
}

func TestTimestampRefreshRequiresFullRefreshBeforeRoleExpiryWithoutOutput(t *testing.T) {
	dir, root, previous := refreshFixture(t)
	rebindRefreshTargets(t, dir, previous, time.Now().UTC().Add(23*time.Hour))
	output := filepath.Join(dir, "must-not-exist")
	status, err := refreshStatus(t, root, dir, previous, output, "8")
	check(t, err)
	if status != "full-refresh-required" {
		t.Fatal("soon-expiring targets did not require full refresh")
	}
	if _, err := os.Lstat(output); !os.IsNotExist(err) {
		t.Fatal("full-refresh-required created output")
	}
}

func TestTimestampRefreshAcceptsAnExpiredPriorTimestampWithoutChangingItsGraph(t *testing.T) {
	dir, root, previous := refreshFixture(t)
	ts, err := metadata.Timestamp().FromFile(filepath.Join(previous, "metadata/timestamp.json"))
	check(t, err)
	ts.Signed.Expires = time.Now().UTC().Truncate(time.Second).Add(-time.Minute)
	ts.Signed.UnrecognizedFields["asm_issued_at"] = ts.Signed.Expires.Add(-5 * time.Minute).UTC().Truncate(time.Second).Format(time.RFC3339)
	ts.Signatures = nil
	key, err := signer(filepath.Join(dir, "timestamp.pem"))
	check(t, err)
	_, err = ts.Sign(key)
	check(t, err)
	data, err := ts.ToBytes(false)
	check(t, err)
	check(t, os.WriteFile(filepath.Join(previous, "metadata/timestamp.json"), data, 0600))
	status, err := refreshStatus(t, root, dir, previous, filepath.Join(dir, "renewed-after-delay"), "8")
	check(t, err)
	if status != "refreshed" {
		t.Fatal("late authorized renewal required recopying package targets")
	}
}

func TestTimestampRefreshRootRotationRequiresFullSigningAndValidPreviousGraph(t *testing.T) {
	dir, root, previous := refreshFixture(t)
	r, err := metadata.Root().FromFile(root)
	check(t, err)
	r.Signed.Version++
	r.Signatures = nil
	for _, name := range []string{"root1", "root2"} {
		key, err := signer(filepath.Join(dir, name+".pem"))
		check(t, err)
		_, err = r.Sign(key)
		check(t, err)
	}
	data, err := r.ToBytes(false)
	check(t, err)
	rotated := filepath.Join(dir, "rotated-root.json")
	check(t, os.WriteFile(rotated, data, 0600))
	output := filepath.Join(dir, "not-exposed")
	status, err := refreshStatus(t, rotated, dir, previous, output, "8")
	check(t, err)
	if status != "full-refresh-required" {
		t.Fatal("root rollover used timestamp-only signing")
	}
	if _, err := os.Lstat(output); !os.IsNotExist(err) {
		t.Fatal("root rollover exposed partial output")
	}
	check(t, os.WriteFile(filepath.Join(previous, "metadata/targets.json"), []byte("{}"), 0600))
	if _, err := refreshStatus(t, rotated, dir, previous, output, "8"); err == nil {
		t.Fatal("root rollover hid an invalid previous graph behind the full refresh status")
	}
}

func TestTimestampRefreshRejectsInvalidVersionsKeysGraphsAndExistingOutput(t *testing.T) {
	for _, attack := range []string{"0", "5", "05", "+8", "9223372036854775808", "wrong-key", "wrong-key-near-expiry", "graph", "root", "existing"} {
		t.Run(attack, func(t *testing.T) {
			dir, root, previous := refreshFixture(t)
			output, version := filepath.Join(dir, "output"), "8"
			switch attack {
			case "wrong-key", "wrong-key-near-expiry":
				if attack == "wrong-key-near-expiry" {
					rebindRefreshTargets(t, dir, previous, time.Now().UTC().Add(23*time.Hour))
				}
				wrong, err := os.ReadFile(filepath.Join(dir, "targets.pem"))
				check(t, err)
				check(t, os.WriteFile(filepath.Join(dir, "timestamp.pem"), wrong, 0600))
			case "graph":
				path := filepath.Join(previous, "metadata/targets.json")
				data, err := os.ReadFile(path)
				check(t, err)
				check(t, os.WriteFile(path, append(data, ' '), 0600))
			case "root":
				data, err := os.ReadFile(root)
				check(t, err)
				check(t, os.WriteFile(root, append(data, ' '), 0600))
			case "existing":
				check(t, os.Mkdir(output, 0700))
			default:
				version = attack
			}
			if _, err := refreshStatus(t, root, dir, previous, output, version); err == nil {
				t.Fatal("accepted invalid refresh: " + attack)
			}
			if attack != "existing" {
				if _, err := os.Lstat(output); !os.IsNotExist(err) {
					t.Fatal("invalid refresh exposed output")
				}
			}
		})
	}
}
