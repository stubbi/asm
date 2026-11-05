//go:build linux || darwin

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

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
