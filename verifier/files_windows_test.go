// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
	"unsafe"

	"github.com/stubbi/asm/verifier/internal/securefs"
	"golang.org/x/sys/windows"
)

func TestWindowsPrivateStateCreation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state")
	directory, err := openState(path)
	must(t, err)
	defer directory.Close()
	sd, err := windows.GetSecurityInfo(windows.Handle(directory.Fd()), windows.SE_FILE_OBJECT,
		windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	must(t, err)
	owner, _, err := sd.Owner()
	must(t, err)
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	must(t, err)
	if owner == nil || !windows.EqualSid(owner, user.User.Sid) {
		t.Fatal("new state does not belong to the current user")
	}
	control, _, err := sd.Control()
	must(t, err)
	if control&windows.SE_DACL_PROTECTED == 0 {
		t.Fatal("new state inherits an unprotected access list")
	}
	windowsAssertPrivateACL(t, windows.Handle(directory.Fd()))
	path = filepath.Join(path, "fixture")
	must(t, writeExclusive(path, []byte("preserve")))
	data, err := readRegular(path, 64)
	must(t, err)
	if string(data) != "preserve" {
		t.Fatal("new state file has unexpected bytes")
	}
}

// Create fixtures through the public state boundary, under the native user's
// ordinary temporary directory. No fixture changes a system or profile ACL.
func windowsStateFixture(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "state")
	directory, err := openState(path)
	must(t, err)
	must(t, directory.Close())
	return path
}

func windowsUserSID(t *testing.T) string {
	t.Helper()
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	must(t, err)
	return user.User.Sid.String()
}

func windowsRawHandle(t *testing.T, path string, access, sharing uint32) windows.Handle {
	t.Helper()
	name, err := windows.UTF16PtrFromString(path)
	must(t, err)
	handle, err := windows.CreateFile(name, access, sharing, nil, windows.OPEN_EXISTING,
		windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	must(t, err)
	return handle
}

// Restore the original descriptor before temporary-directory cleanup. In
// particular, a NULL-DACL fixture must never remain permissive after the test.
func windowsSetFixtureDACL(t *testing.T, path, sddl string, null bool) {
	t.Helper()
	handle := windowsRawHandle(t, path, windows.READ_CONTROL|windows.WRITE_DAC,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE)
	defer windows.CloseHandle(handle)
	original, err := windows.GetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	must(t, err)
	originalACL, _, err := original.DACL()
	must(t, err)
	control, _, err := original.Control()
	must(t, err)
	t.Cleanup(func() {
		handle := windowsRawHandle(t, path, windows.WRITE_DAC,
			windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE)
		defer windows.CloseHandle(handle)
		flags := windows.SECURITY_INFORMATION(windows.DACL_SECURITY_INFORMATION)
		if control&windows.SE_DACL_PROTECTED != 0 {
			flags |= windows.PROTECTED_DACL_SECURITY_INFORMATION
		} else {
			flags |= windows.UNPROTECTED_DACL_SECURITY_INFORMATION
		}
		must(t, windows.SetSecurityInfo(handle, windows.SE_FILE_OBJECT, flags, nil, nil, originalACL, nil))
	})
	var acl *windows.ACL
	if !null {
		descriptor, err := windows.SecurityDescriptorFromString(sddl)
		must(t, err)
		acl, _, err = descriptor.DACL()
		must(t, err)
		// Keep the descriptor alive through SetSecurityInfo below.
		must(t, windows.SetSecurityInfo(handle, windows.SE_FILE_OBJECT,
			windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
			nil, nil, acl, nil))
		return
	}
	must(t, windows.SetSecurityInfo(handle, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, nil, nil))
}

func windowsAssertPrivateACL(t *testing.T, handle windows.Handle) {
	t.Helper()
	descriptor, err := windows.GetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	must(t, err)
	acl, _, err := descriptor.DACL()
	must(t, err)
	if acl == nil {
		t.Fatal("private object has a permissive NULL access list")
	}
	user := windowsUserSID(t)
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		must(t, windows.GetAce(acl, i, &ace))
		if ace.Header.AceType == windows.ACCESS_DENIED_ACE_TYPE {
			continue
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			t.Fatalf("private object contains unexpected ACE type %d", ace.Header.AceType)
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if sid.String() != user && !sid.IsWellKnown(windows.WinLocalSystemSid) &&
			!sid.IsWellKnown(windows.WinBuiltinAdministratorsSid) {
			t.Fatalf("private object grants access to %s", sid.String())
		}
	}
}

func TestWindowsRejectUnsafeStateACL(t *testing.T) {
	for _, ancestor := range []bool{false, true} {
		for _, null := range []bool{false, true} {
			name := "final/allow"
			if ancestor {
				name = "ancestor/allow"
			}
			if null {
				name = strings.TrimSuffix(name, "allow") + "null"
			}
			t.Run(name, func(t *testing.T) {
				fixture := windowsStateFixture(t)
				state := fixture
				if ancestor {
					state = filepath.Join(fixture, "child")
					directory, err := openState(state)
					must(t, err)
					must(t, directory.Close())
				}
				windowsSetFixtureDACL(t, fixture,
					"D:P(A;OICI;FA;;;"+windowsUserSID(t)+")(A;OICI;GRGW;;;WD)", null)
				if directory, err := openState(state); err == nil {
					directory.Close()
					t.Fatal("accepted a state path with an unsafe access list")
				}
			})
		}
	}
	for _, access := range []string{"GR", "GW"} {
		t.Run("final/inherit-only-"+access, func(t *testing.T) {
			state := windowsStateFixture(t)
			windowsSetFixtureDACL(t, state,
				"D:P(A;OICI;FA;;;"+windowsUserSID(t)+")(A;OICIIO;"+access+";;;WD)", false)
			if directory, err := openState(state); err == nil {
				directory.Close()
				t.Fatal("accepted private state that exposes inherited metadata temporaries")
			}
		})
	}
	for name, inheritance := range map[string]string{"none": "", "no-propagation": "OICINP"} {
		t.Run("final/private-inheritance-"+name, func(t *testing.T) {
			state := windowsStateFixture(t)
			windowsSetFixtureDACL(t, state,
				"D:P(A;"+inheritance+";FA;;;"+windowsUserSID(t)+")", false)
			if directory, err := openState(state); err == nil {
				directory.Close()
				t.Fatal("accepted private state without continued private child inheritance")
			}
		})
	}
}

type rejectingStateFetcher struct{ calls int }

func (f *rejectingStateFetcher) DownloadFile(_ string, _ int64, _ time.Duration) ([]byte, error) {
	f.calls++
	return nil, errors.New("unexpected network access before local role validation")
}

func TestWindowsRejectUnsafeExistingRolesBeforeRefresh(t *testing.T) {
	for _, role := range []string{"root.json", "timestamp.json", "snapshot.json", "targets.json"} {
		for _, attack := range []string{"hardlink", "junction", "ACL"} {
			t.Run(role+"/"+attack, func(t *testing.T) {
				r := newRepositoryFixture(t)
				state := statePath(t)
				must(t, r.refresh(state))
				// Make a later clock write observable even within this second.
				must(t, atomicWrite(filepath.Join(state, "clock"),
					[]byte(time.Now().Add(-time.Minute).UTC().Format(time.RFC3339))))
				before := map[string][]byte{}
				for _, name := range []string{"root.json", "timestamp.json", "snapshot.json", "targets.json", "clock", "rotation-root.json"} {
					data, err := os.ReadFile(filepath.Join(state, name))
					must(t, err)
					before[name] = data
				}
				path := filepath.Join(state, role)
				original := path
				switch attack {
				case "hardlink":
					must(t, os.Link(path, filepath.Join(state, "extra-link")))
				case "junction":
					original = filepath.Join(state, "original-role")
					must(t, os.Rename(path, original))
					target := filepath.Join(state, "junction-target")
					must(t, os.Mkdir(target, 0700))
					windowsCreateJunction(t, path, target)
				case "ACL":
					windowsSetFixtureDACL(t, path,
						"D:P(A;;FA;;;"+windowsUserSID(t)+")(A;;GW;;;WD)", false)
				}
				transport := new(rejectingStateFetcher)
				err := useRepository(r.anchor, state, transport, func(*trustedRepository) error {
					t.Error("ran the repository operation with an unsafe retained role")
					return nil
				})
				if err == nil {
					t.Fatal("accepted an unsafe retained role")
				}
				if transport.calls != 0 {
					t.Fatal("started network access before rejecting an unsafe retained role")
				}
				for name, expected := range before {
					path := filepath.Join(state, name)
					if name == role {
						path = original
					}
					data, err := os.ReadFile(path)
					must(t, err)
					if !bytes.Equal(data, expected) {
						t.Fatalf("rejected role changed retained %s bytes", name)
					}
				}
			})
		}
	}
}

func TestWindowsRejectUnsafeFileACL(t *testing.T) {
	for _, null := range []bool{false, true} {
		t.Run(map[bool]string{false: "allow", true: "null"}[null], func(t *testing.T) {
			path := filepath.Join(windowsStateFixture(t), "root.json")
			must(t, writeExclusive(path, []byte("preserve")))
			windowsSetFixtureDACL(t, path,
				"D:P(A;;FA;;;"+windowsUserSID(t)+")(A;;GRGW;;;WD)", null)
			if file, err := openFile(path, os.O_RDONLY, 0); err == nil {
				file.Close()
				t.Fatal("accepted a trust file with an unsafe access list")
			}
			data, err := os.ReadFile(path)
			must(t, err)
			if string(data) != "preserve" {
				t.Fatal("rejected access list changed the file")
			}
		})
	}
}

func TestWindowsPrivateCreationBlocksInheritedReadAccess(t *testing.T) {
	parent := windowsStateFixture(t)
	windowsSetFixtureDACL(t, parent,
		"D:P(A;OICI;FA;;;"+windowsUserSID(t)+")(A;OICI;GR;;;WD)", false)
	state := filepath.Join(parent, "private")
	directory, err := openState(state)
	must(t, err)
	defer directory.Close()
	windowsAssertPrivateACL(t, windows.Handle(directory.Fd()))
	path := filepath.Join(state, "clock")
	must(t, atomicWrite(path, []byte("new bytes")))
	file, err := openFile(path, os.O_RDONLY, 0)
	must(t, err)
	defer file.Close()
	windowsAssertPrivateACL(t, windows.Handle(file.Fd()))
	must(t, directory.Sync())
}

// Build a mount-point reparse buffer directly. Junction fixtures do not depend
// on a shell, a developer-mode setting, or symbolic-link creation privileges.
func windowsCreateJunction(t *testing.T, path, target string) {
	t.Helper()
	must(t, os.Mkdir(path, 0700))
	substitute := utf16.Encode([]rune(`\??\` + target))
	printName := utf16.Encode([]rune(target))
	paths := append(append(substitute, 0), append(printName, 0)...)
	buffer := make([]byte, 16+len(paths)*2)
	binary.LittleEndian.PutUint32(buffer[0:4], windows.IO_REPARSE_TAG_MOUNT_POINT)
	binary.LittleEndian.PutUint16(buffer[4:6], uint16(len(buffer)-8))
	binary.LittleEndian.PutUint16(buffer[10:12], uint16(len(substitute)*2))
	binary.LittleEndian.PutUint16(buffer[12:14], uint16((len(substitute)+1)*2))
	binary.LittleEndian.PutUint16(buffer[14:16], uint16(len(printName)*2))
	for i, value := range paths {
		binary.LittleEndian.PutUint16(buffer[16+i*2:18+i*2], value)
	}
	handle := windowsRawHandle(t, path, windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE)
	defer windows.CloseHandle(handle)
	var returned uint32
	must(t, windows.DeviceIoControl(handle, windows.FSCTL_SET_REPARSE_POINT,
		&buffer[0], uint32(len(buffer)), nil, 0, &returned, nil))
	info, err := os.Lstat(path)
	must(t, err)
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatal("junction fixture is not a reparse link")
	}
}

func TestWindowsRejectJunctionStatePaths(t *testing.T) {
	parent := windowsStateFixture(t)
	target := filepath.Join(parent, "target")
	directory, err := openState(target)
	must(t, err)
	must(t, directory.Close())
	child, err := openState(filepath.Join(target, "child"))
	must(t, err)
	must(t, child.Close())
	alias := filepath.Join(parent, "alias")
	windowsCreateJunction(t, alias, target)
	for _, path := range []string{alias, filepath.Join(alias, "child")} {
		if directory, err := openState(path); err == nil {
			directory.Close()
			t.Fatalf("accepted junction state path %q", path)
		}
	}
	if file, err := openFile(alias, os.O_RDONLY, 0); err == nil {
		file.Close()
		t.Fatal("accepted a directory junction as a trust file")
	}
}

func TestWindowsRejectSymbolicLinks(t *testing.T) {
	state := windowsStateFixture(t)
	victim := filepath.Join(state, "victim")
	must(t, writeExclusive(victim, []byte("preserve")))
	alias := filepath.Join(state, "root.json")
	if err := os.Symlink(victim, alias); err != nil {
		if errors.Is(err, windows.ERROR_PRIVILEGE_NOT_HELD) {
			t.Skip("symbolic-link fixture requires Developer Mode or SeCreateSymbolicLinkPrivilege")
		}
		t.Fatal(err)
	}
	if file, err := openFile(alias, os.O_RDWR, 0); err == nil {
		file.Close()
		t.Fatal("accepted symbolic-link metadata")
	}
	if err := writeExclusive(alias, []byte("replace")); err == nil {
		t.Fatal("accepted symbolic-link output")
	}
	directoryAlias := filepath.Join(filepath.Dir(state), "state-link")
	must(t, os.Symlink(state, directoryAlias))
	if directory, err := openState(directoryAlias); err == nil {
		directory.Close()
		t.Fatal("accepted symbolic-link state")
	}
	data, err := os.ReadFile(victim)
	must(t, err)
	if string(data) != "preserve" {
		t.Fatal("symbolic-link rejection changed the target")
	}
}

func TestWindowsRejectHardLinks(t *testing.T) {
	for _, name := range []string{"root.json", "lock", "output"} {
		t.Run(name, func(t *testing.T) {
			state := windowsStateFixture(t)
			victim := filepath.Join(state, "victim")
			must(t, writeExclusive(victim, []byte("preserve")))
			alias := filepath.Join(state, name)
			must(t, os.Link(victim, alias))
			if file, err := openFile(alias, os.O_RDWR, 0); err == nil {
				file.Close()
				t.Fatal("accepted a hardlinked trust file")
			}
			if err := writeExclusive(alias, []byte("replace")); err == nil {
				t.Fatal("accepted hardlinked output")
			}
			if err := atomicWrite(alias, []byte("replace")); err == nil {
				t.Fatal("replaced a hardlinked trust destination")
			}
			data, err := os.ReadFile(victim)
			must(t, err)
			if string(data) != "preserve" {
				t.Fatal("hardlink rejection changed the other name")
			}
		})
	}
}

func windowsTokenPrivilege(t *testing.T, token windows.Token, luid windows.LUID) (uint32, bool) {
	t.Helper()
	var required uint32
	err := windows.GetTokenInformation(token, windows.TokenPrivileges, nil, 0, &required)
	if !errors.Is(err, windows.ERROR_INSUFFICIENT_BUFFER) {
		t.Fatalf("query token privilege size: %v", err)
	}
	if required < 4 || required > 65536 {
		t.Fatalf("unexpected token privilege size %d", required)
	}
	buffer := make([]byte, required)
	must(t, windows.GetTokenInformation(token, windows.TokenPrivileges, &buffer[0], required, &required))
	privileges := (*windows.Tokenprivileges)(unsafe.Pointer(&buffer[0]))
	if uint64(privileges.PrivilegeCount)*12+4 > uint64(len(buffer)) {
		t.Fatal("token privilege count exceeds its returned buffer")
	}
	for _, privilege := range privileges.AllPrivileges() {
		if privilege.Luid == luid {
			return privilege.Attributes, true
		}
	}
	return 0, false
}

func TestWindowsRejectForeignOwnerWhenRestorePrivilegeExists(t *testing.T) {
	if windowsUserSID(t) == "S-1-5-18" {
		t.Skip("SYSTEM is the current account, so it cannot supply a foreign-owner fixture")
	}
	path := filepath.Join(windowsStateFixture(t), "foreign-owner")
	must(t, atomicWrite(path, []byte("preserve")))
	data, err := securefs.ReadPrivate(path, 64)
	must(t, err)
	if string(data) != "preserve" {
		t.Fatal("private ownership fixture has unexpected bytes")
	}
	var token windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY|windows.TOKEN_ADJUST_PRIVILEGES, &token); err != nil {
		if errors.Is(err, windows.ERROR_ACCESS_DENIED) {
			t.Skip("foreign-owner fixture requires access to adjust SeRestorePrivilege in the test process token")
		}
		t.Fatal(err)
	}
	defer token.Close()
	name, err := windows.UTF16PtrFromString("SeRestorePrivilege")
	must(t, err)
	var luid windows.LUID
	must(t, windows.LookupPrivilegeValue(nil, name, &luid))
	originalAttributes, present := windowsTokenPrivilege(t, token, luid)
	if !present {
		t.Skip("foreign-owner fixture requires SeRestorePrivilege in the native test process token")
	}
	requested := windows.Tokenprivileges{PrivilegeCount: 1,
		Privileges: [1]windows.LUIDAndAttributes{{Luid: luid, Attributes: windows.SE_PRIVILEGE_ENABLED}}}
	var previous windows.Tokenprivileges
	var returned uint32
	must(t, windows.AdjustTokenPrivileges(token, false, &requested, uint32(unsafe.Sizeof(previous)), &previous, &returned))
	defer func() {
		if err := windows.AdjustTokenPrivileges(token, false, &previous, 0, nil, nil); err != nil {
			t.Errorf("restore test token privilege: %v", err)
			return
		}
		if attributes, present := windowsTokenPrivilege(t, token, luid); !present ||
			attributes&windows.SE_PRIVILEGE_ENABLED != originalAttributes&windows.SE_PRIVILEGE_ENABLED {
			t.Error("test token did not restore the original SeRestorePrivilege state")
		}
	}()
	if attributes, present := windowsTokenPrivilege(t, token, luid); !present || attributes&windows.SE_PRIVILEGE_ENABLED == 0 {
		t.Skip("native token did not permit enabling SeRestorePrivilege for the foreign-owner fixture")
	}
	handle := windowsRawHandle(t, path, windows.READ_CONTROL|windows.WRITE_OWNER,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE)
	defer windows.CloseHandle(handle)
	descriptor, err := windows.GetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION)
	must(t, err)
	owner, _, err := descriptor.Owner()
	must(t, err)
	original, err := owner.Copy()
	must(t, err)
	system, err := windows.CreateWellKnownSid(windows.WinLocalSystemSid)
	must(t, err)
	if err := windows.SetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION, system, nil, nil, nil); err != nil {
		if errors.Is(err, windows.ERROR_PRIVILEGE_NOT_HELD) || errors.Is(err, windows.ERROR_ACCESS_DENIED) {
			t.Skipf("native token cannot assign the SYSTEM owner to a disposable fixture: %v", err)
		}
		t.Fatal(err)
	}
	// Owner restoration runs before the handle and privilege defers above.
	defer func() {
		if err := windows.SetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION, original, nil, nil, nil); err != nil {
			t.Errorf("restore disposable fixture owner: %v", err)
		}
	}()
	descriptor, err = windows.GetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION)
	must(t, err)
	owner, _, err = descriptor.Owner()
	must(t, err)
	if !owner.IsWellKnown(windows.WinLocalSystemSid) {
		t.Fatal("foreign-owner fixture was not assigned to SYSTEM")
	}
	if file, err := openFile(path, os.O_RDONLY, 0); err == nil {
		file.Close()
		t.Error("accepted a regular file owned by SYSTEM")
	}
	if data, err := securefs.ReadPrivate(path, 64); err == nil || len(data) != 0 {
		t.Error("private reader exposed a key owned by SYSTEM")
	}
	data, err = os.ReadFile(path)
	must(t, err)
	if string(data) != "preserve" {
		t.Fatal("foreign-owner rejection changed the existing bytes")
	}
}

func TestWindowsHeldAncestorsRefuseRename(t *testing.T) {
	parent := windowsStateFixture(t)
	directory, err := openState(filepath.Join(parent, "child"))
	must(t, err)
	closed := false
	t.Cleanup(func() {
		if !closed {
			_ = directory.Close()
		}
	})
	renamed := parent + "-renamed"
	if err := os.Rename(parent, renamed); err == nil {
		directory.Close()
		closed = true
		_ = os.Rename(renamed, parent)
		t.Fatal("renamed a held state ancestor")
	}
	must(t, directory.Close())
	closed = true
	must(t, os.Rename(parent, renamed))
	must(t, os.Rename(renamed, parent))
}

func TestWindowsReplacementFailurePreservesExistingFile(t *testing.T) {
	state := windowsStateFixture(t)
	path := filepath.Join(state, "root.json")
	must(t, atomicWrite(path, []byte("preserve")))
	handle := windowsRawHandle(t, path, windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE)
	held := true
	t.Cleanup(func() {
		if held {
			_ = windows.CloseHandle(handle)
		}
	})
	if err := atomicWrite(path, []byte("replace")); err == nil {
		windows.CloseHandle(handle)
		held = false
		t.Fatal("replaced a destination held without delete sharing")
	}
	data, err := os.ReadFile(path)
	must(t, err)
	if string(data) != "preserve" {
		t.Fatal("failed replacement changed existing bytes")
	}
	must(t, windows.CloseHandle(handle))
	held = false
	must(t, atomicWrite(path, []byte("replace")))
	data, err = readRegular(path, 64)
	must(t, err)
	if string(data) != "replace" {
		t.Fatal("successful replacement did not expose complete new bytes")
	}
	entries, err := os.ReadDir(state)
	must(t, err)
	if len(entries) != 1 || entries[0].Name() != "root.json" {
		t.Fatal("replacement left temporary files in the trust state")
	}
}

func TestWindowsFlushFailuresPreserveCommittedBytes(t *testing.T) {
	state := windowsStateFixture(t)
	directory, err := openState(state)
	must(t, err)
	defer directory.Close()
	path := filepath.Join(state, "clock")
	must(t, atomicWrite(path, []byte("preserve")))
	windowsSetFixtureDACL(t, path, "D:P(A;;GR;;;"+windowsUserSID(t)+")", false)
	file, err := openFile(path, os.O_RDONLY, 0)
	must(t, err)
	defer file.Close()
	for name, flush := range map[string]func() error{
		"state": directory.Sync,
		"file":  func() error { return syncOpenedFile(file) },
	} {
		t.Run(name, func(t *testing.T) {
			if err := flush(); !errors.Is(err, windows.ERROR_ACCESS_DENIED) {
				t.Fatalf("flush without write access: %v; want access denied", err)
			}
			data, err := os.ReadFile(path)
			must(t, err)
			if string(data) != "preserve" {
				t.Fatal("failed flush changed the committed bytes")
			}
		})
	}
}

func TestWindowsRejectAmbiguousStatePaths(t *testing.T) {
	state := windowsStateFixture(t)
	for name, path := range map[string]string{
		"relative":         "relative-state",
		"drive relative":   `C:state`,
		"UNC":              `\\localhost\asm-test-no-share\state`,
		"device":           `\\.\NUL`,
		"extended":         `\\?\` + state,
		"stream":           state + ":stream",
		"dot component":    state + `\.\child`,
		"parent component": state + `\..\child`,
		"trailing dot":     state + ".",
		"trailing space":   state + " ",
		"reserved":         filepath.Join(state, "NUL"),
	} {
		t.Run(name, func(t *testing.T) {
			if directory, err := openState(path); err == nil {
				directory.Close()
				t.Fatalf("accepted ambiguous state path %q", path)
			}
		})
	}
}

func TestWindowsStateLockAcrossProcesses(t *testing.T) {
	if path := os.Getenv("ASM_WINDOWS_LOCK_TEST_PATH"); path != "" {
		file, err := openFile(path, os.O_RDWR|os.O_CREATE, 0600)
		must(t, err)
		defer file.Close()
		unlock, err := acquireStateLock(file)
		if os.Getenv("ASM_WINDOWS_LOCK_TEST_MODE") == "contend" {
			if err == nil {
				unlock()
				t.Fatal("acquired a lock held by another process")
			}
			os.Exit(71)
		}
		must(t, err)
		// Exit without unlocking or closing. The next process must recover.
		os.Exit(73)
	}
	state := windowsStateFixture(t)
	path := filepath.Join(state, "lock")
	file, err := openFile(path, os.O_RDWR|os.O_CREATE, 0600)
	must(t, err)
	defer file.Close()
	unlock, err := acquireStateLock(file)
	must(t, err)
	locked := true
	t.Cleanup(func() {
		if locked {
			_ = unlock()
		}
	})
	for _, tc := range []struct {
		mode string
		code int
	}{{"contend", 71}, {"exit", 73}} {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestWindowsStateLockAcrossProcesses$")
		command.Env = append(os.Environ(), "ASM_WINDOWS_LOCK_TEST_PATH="+path,
			"ASM_WINDOWS_LOCK_TEST_MODE="+tc.mode)
		output, err := command.CombinedOutput()
		cancel()
		var exit *exec.ExitError
		if !errors.As(err, &exit) || exit.ExitCode() != tc.code {
			t.Fatalf("%s lock process: %v, output %q", tc.mode, err, bytes.TrimSpace(output))
		}
		if locked {
			must(t, unlock())
			locked = false
		}
	}
	unlock, err = acquireStateLock(file)
	must(t, err)
	must(t, unlock())
}
