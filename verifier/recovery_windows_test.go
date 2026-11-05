// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

type failedCleanupMirror struct {
	*repositoryFixture
	state string
	held  windows.Handle
}

func (r *failedCleanupMirror) DownloadFile(address string, limit int64, timeout time.Duration) ([]byte, error) {
	if address == metadataURL+"/3.root.json" {
		// File flushes remain permitted. Delete sharing alone is withheld,
		// so recovery reaches the second deletion before it fails.
		r.held = windowsRawHandle(r.t, filepath.Join(r.state, "snapshot.json"),
			windows.GENERIC_READ|windows.GENERIC_WRITE,
			windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE)
	}
	return r.repositoryFixture.DownloadFile(address, limit, timeout)
}

func TestFailedCleanupRetainsRecoveryCheckpoint(t *testing.T) {
	r := newRepositoryFixture(t)
	state := statePath(t)
	fastForwardState(t, r, "timestamp", state)
	snapshot := filepath.Join(state, "snapshot.json")
	checkpoint := filepath.Join(state, "rotation-root.json")
	snapshotBefore, err := os.ReadFile(snapshot)
	must(t, err)
	checkpointBefore, err := os.ReadFile(checkpoint)
	must(t, err)
	rotateOnlineKey(t, r, "timestamp")
	publishRecovery(r)
	mirror := &failedCleanupMirror{repositoryFixture: r, state: state, held: windows.InvalidHandle}
	t.Cleanup(func() {
		if mirror.held != windows.InvalidHandle {
			_ = windows.CloseHandle(mirror.held)
		}
	})
	err = useRepository(r.anchor, state, mirror, func(*trustedRepository) error { return nil })
	if err == nil {
		t.Fatal("ignored incomplete cache cleanup")
	}
	if mirror.held == windows.InvalidHandle {
		t.Fatal("did not hold the snapshot at the recovery boundary")
	}
	if _, err := os.Stat(filepath.Join(state, "timestamp.json")); !os.IsNotExist(err) {
		t.Fatal("did not reach the interruption between cache deletions")
	}
	for _, tc := range []struct {
		path string
		data []byte
	}{{snapshot, snapshotBefore}, {checkpoint, checkpointBefore}} {
		data, err := os.ReadFile(tc.path)
		must(t, err)
		if !bytes.Equal(data, tc.data) {
			t.Fatalf("incomplete recovery changed %s", filepath.Base(tc.path))
		}
	}
	must(t, windows.CloseHandle(mirror.held))
	mirror.held = windows.InvalidHandle
	must(t, r.refresh(state))
	must(t, r.refresh(state))
}

type rootPersistenceMirror struct {
	*repositoryFixture
	initialRoot <-chan struct{}
	wait        <-chan struct{}
}

func (r rootPersistenceMirror) DownloadFile(address string, limit int64, timeout time.Duration) ([]byte, error) {
	if address == metadataURL+"/2.root.json" {
		// Consume and rearm after the initial root rewrite before serving root 2.
		// An earlier root-1 notification cannot become the root-2 exit trigger.
		<-r.initialRoot
	}
	if address == metadataURL+"/3.root.json" {
		// Only the filesystem observer terminates this child. Holding this
		// request prevents ordinary completion from advancing the checkpoint.
		<-r.wait
	}
	return r.repositoryFixture.DownloadFile(address, limit, timeout)
}

func windowsReadObservedRoot(path string) ([]byte, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	// An observer read must not prevent a later metadata rename.
	handle, err := windows.CreateFile(name, windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(handle), path)
	data, err := io.ReadAll(io.LimitReader(file, maxMetadata+1))
	return data, errors.Join(err, file.Close())
}

func windowsStartRootPersistenceObserver(t *testing.T, state string, initial, expected []byte) <-chan struct{} {
	t.Helper()
	name, err := windows.UTF16PtrFromString(state)
	must(t, err)
	// Keep the asynchronous handle away from os.NewFile and Go's IOCP setup.
	// A separate synchronous descriptor supplies the retained directory identity.
	directory, err := os.Open(state)
	must(t, err)
	identity, err := directory.Stat()
	if err != nil {
		directory.Close()
		t.Fatal(err)
	}
	handle, err := windows.CreateFile(name, windows.FILE_LIST_DIRECTORY|windows.FILE_READ_ATTRIBUTES,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OVERLAPPED, 0)
	if err != nil {
		directory.Close()
		t.Fatal(err)
	}
	event, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		windows.CloseHandle(handle)
		directory.Close()
		t.Fatal(err)
	}
	words := new([4096]uint32) // DWORD-aligned 16 KiB notification buffer.
	buffer := unsafe.Slice((*byte)(unsafe.Pointer(&words[0])), len(words)*4)
	overlapped := &windows.Overlapped{HEvent: event}
	pinned := new(runtime.Pinner)
	pinned.Pin(&words[0])
	pinned.Pin(overlapped)
	queue := func() error {
		*overlapped = windows.Overlapped{HEvent: event}
		return windows.ReadDirectoryChanges(handle, &buffer[0], uint32(len(buffer)), true,
			windows.FILE_NOTIFY_CHANGE_FILE_NAME, nil, overlapped, 0)
	}
	// Arm the native watch before the updater can create or rename metadata.
	if err := queue(); err != nil && !errors.Is(err, windows.ERROR_IO_PENDING) {
		pinned.Unpin()
		windows.CloseHandle(event)
		windows.CloseHandle(handle)
		directory.Close()
		t.Fatal(err)
	}
	initialRoot := make(chan struct{})
	go func() {
		defer directory.Close()
		defer windows.CloseHandle(handle)
		defer windows.CloseHandle(event)
		defer pinned.Unpin()
		fail := func(err error) {
			fmt.Fprintf(os.Stderr, "root persistence observer: %v\n", err)
			os.Exit(74)
		}
		initialObserved := false
		rootAllowed := false
		for {
			var count uint32
			if err := windows.GetOverlappedResult(handle, overlapped, &count, true); err != nil {
				fail(err)
			}
			if count == 0 || count > uint32(len(buffer)) {
				fail(errors.New("notification overflow or invalid completion length"))
			}
			for offset := uint32(0); ; {
				if count-offset < 12 {
					fail(errors.New("truncated file notification"))
				}
				entry := buffer[offset:count]
				next := binary.LittleEndian.Uint32(entry[0:4])
				action := binary.LittleEndian.Uint32(entry[4:8])
				length := binary.LittleEndian.Uint32(entry[8:12])
				if length%2 != 0 || length > uint32(len(entry))-12 {
					fail(errors.New("invalid notification name length"))
				}
				units := make([]uint16, length/2)
				for i := range units {
					units[i] = binary.LittleEndian.Uint16(entry[12+i*2 : 14+i*2])
				}
				name := string(utf16.Decode(units))
				if action == windows.FILE_ACTION_RENAMED_NEW_NAME && strings.EqualFold(filepath.Base(name), "root.json") {
					path := filepath.Join(state, name)
					data, err := windowsReadObservedRoot(path)
					if err != nil {
						fail(err)
					}
					if bytes.Equal(data, initial) || bytes.Equal(data, expected) {
						actual, err := os.Stat(filepath.Dir(path))
						if err != nil {
							fail(err)
						}
						if !strings.EqualFold(filepath.Dir(path), state) || !os.SameFile(identity, actual) {
							fail(errors.New("library persisted root outside the retained state directory"))
						}
						if bytes.Equal(data, expected) {
							if !rootAllowed {
								fail(errors.New("rotated root appeared before the initial notification boundary"))
							}
							fmt.Fprintln(os.Stdout, "observed retained root.json rename")
							os.Exit(73)
						}
						initialObserved = true
					}
				}
				if next == 0 {
					break
				}
				if next%4 != 0 || next < 12+length || next >= count-offset {
					fail(errors.New("invalid file notification offset"))
				}
				offset += next
			}
			if err := windows.ResetEvent(event); err != nil {
				fail(err)
			}
			if err := queue(); err != nil && !errors.Is(err, windows.ERROR_IO_PENDING) {
				fail(err)
			}
			if initialObserved && !rootAllowed {
				rootAllowed = true
				close(initialRoot)
			}
		}
	}()
	return initialRoot
}

func TestWindowsRootPersistenceObservedBeforeProcessExit(t *testing.T) {
	type fixture struct {
		Anchor []byte
		Root   []byte
		Files  map[string][]byte
		State  string
	}
	if path := os.Getenv("ASM_WINDOWS_ROOT_OBSERVER_FIXTURE"); path != "" {
		var server fixture
		data, err := os.ReadFile(path)
		must(t, err)
		must(t, json.Unmarshal(data, &server))
		initialRoot := windowsStartRootPersistenceObserver(t, server.State, server.Anchor, server.Root)
		mirror := rootPersistenceMirror{repositoryFixture: &repositoryFixture{t: t, files: server.Files},
			initialRoot: initialRoot, wait: make(chan struct{})}
		err = useRepository(server.Anchor, server.State, mirror, func(*trustedRepository) error { return nil })
		t.Fatalf("refresh returned before the filesystem observer interrupted it: %v", err)
	}
	for _, role := range []string{"timestamp", "snapshot"} {
		t.Run(role, func(t *testing.T) {
			r := newRepositoryFixture(t)
			state := statePath(t)
			fastForwardState(t, r, role, state)
			checkpointPath := filepath.Join(state, "rotation-root.json")
			checkpointBefore, err := os.ReadFile(checkpointPath)
			must(t, err)
			rotateOnlineKey(t, r, role)
			publishRecovery(r)
			root := r.files[metadataURL+"/2.root.json"]
			data, err := json.Marshal(fixture{Anchor: r.anchor, Root: root, Files: r.files, State: state})
			must(t, err)
			path := filepath.Join(filepath.Dir(state), "root-observer.json")
			must(t, os.WriteFile(path, data, 0600))
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestWindowsRootPersistenceObservedBeforeProcessExit$")
			command.Env = append(os.Environ(), "ASM_WINDOWS_ROOT_OBSERVER_FIXTURE="+path)
			output, err := command.CombinedOutput()
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 73 || !bytes.Contains(output, []byte("observed retained root.json rename")) {
				t.Fatalf("filesystem-observed interruption: %v, output %q", err, output)
			}
			actual, err := os.ReadFile(filepath.Join(state, "root.json"))
			must(t, err)
			if !bytes.Equal(actual, root) {
				t.Fatal("process exit lost the root observed at its retained filename")
			}
			actual, err = os.ReadFile(checkpointPath)
			must(t, err)
			if !bytes.Equal(actual, checkpointBefore) {
				t.Fatal("process exit advanced the recovery checkpoint before cleanup")
			}
			must(t, r.refresh(state))
			must(t, r.refresh(state))
		})
	}
}
