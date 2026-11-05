// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func windowsSigningKeyFixture(t *testing.T) (string, []byte, ed25519.PublicKey) {
	t.Helper()
	seed := sha256.Sum256([]byte("ASM WINDOWS PRIVATE KEY TEST ONLY"))
	private := ed25519.NewKeyFromSeed(seed[:])
	encoded, err := x509.MarshalPKCS8PrivateKey(private)
	check(t, err)
	data := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encoded})
	path := filepath.Join(privateFixtureDirectory(t), "signing.pem")
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	check(t, err)
	descriptor, err := windows.SecurityDescriptorFromString("O:" + user.User.Sid.String() +
		"D:P(A;;FA;;;" + user.User.Sid.String() + ")(A;;FA;;;SY)(A;;FA;;;BA)")
	check(t, err)
	attributes := windows.SecurityAttributes{
		Length:             uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		SecurityDescriptor: descriptor,
	}
	name, err := windows.UTF16PtrFromString(path)
	check(t, err)
	handle, err := windows.CreateFile(name, windows.GENERIC_WRITE, windows.FILE_SHARE_READ,
		&attributes, windows.CREATE_NEW, windows.FILE_ATTRIBUTE_NORMAL, 0)
	check(t, err)
	file := os.NewFile(uintptr(handle), path)
	_, err = file.Write(data)
	closeErr := file.Close()
	check(t, err)
	check(t, closeErr)
	return path, data, private.Public().(ed25519.PublicKey)
}

// Only the owned key file changes. Restore its original DACL before the
// temporary directory is removed, including after an assertion fails.
func windowsSigningKeyDACL(t *testing.T, path string, null bool) {
	t.Helper()
	name, err := windows.UTF16PtrFromString(path)
	check(t, err)
	open := func() windows.Handle {
		handle, err := windows.CreateFile(name, windows.READ_CONTROL|windows.WRITE_DAC,
			windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
			nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
		check(t, err)
		return handle
	}
	handle := open()
	defer windows.CloseHandle(handle)
	original, err := windows.GetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	check(t, err)
	originalACL, _, err := original.DACL()
	check(t, err)
	t.Cleanup(func() {
		handle := open()
		defer windows.CloseHandle(handle)
		check(t, windows.SetSecurityInfo(handle, windows.SE_FILE_OBJECT,
			windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
			nil, nil, originalACL, nil))
	})
	var acl *windows.ACL
	if !null {
		user, err := windows.GetCurrentProcessToken().GetTokenUser()
		check(t, err)
		descriptor, err := windows.SecurityDescriptorFromString(
			"D:P(A;;FA;;;" + user.User.Sid.String() + ")(A;;GR;;;WD)")
		check(t, err)
		acl, _, err = descriptor.DACL()
		check(t, err)
	}
	check(t, windows.SetSecurityInfo(handle, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, acl, nil))
}

func windowsAssertKeyBytes(t *testing.T, path string, expected []byte) {
	t.Helper()
	actual, err := os.ReadFile(path)
	check(t, err)
	if !bytes.Equal(actual, expected) {
		t.Fatal("private-key operation changed the existing key bytes")
	}
}

func TestWindowsSigningKeyAcceptsPrivateACL(t *testing.T) {
	path, original, public := windowsSigningKeyFixture(t)
	key, err := signer(path)
	check(t, err)
	message := []byte("Asm signing-key gate fixture")
	signature, err := key.SignMessage(bytes.NewReader(message))
	check(t, err)
	if !ed25519.Verify(public, message, signature) {
		t.Fatal("protected signing key did not produce its expected Ed25519 signature")
	}
	windowsAssertKeyBytes(t, path, original)
}

func TestWindowsSigningKeyAcceptsRelativePath(t *testing.T) {
	path, original, public := windowsSigningKeyFixture(t)
	directory := filepath.Dir(path)
	keyPath := filepath.Join(directory, "key.pem")
	check(t, os.Rename(path, keyPath))
	t.Chdir(directory)
	key, err := signer("key.pem")
	check(t, err)
	message := []byte("Asm relative signing-key fixture")
	signature, err := key.SignMessage(bytes.NewReader(message))
	check(t, err)
	if !ed25519.Verify(public, message, signature) {
		t.Fatal("relative signing key did not produce its expected Ed25519 signature")
	}
	windowsAssertKeyBytes(t, keyPath, original)
}

func TestWindowsSigningKeyRejectsEveryoneRead(t *testing.T) {
	path, original, _ := windowsSigningKeyFixture(t)
	_, err := signer(path)
	check(t, err)
	windowsSigningKeyDACL(t, path, false)
	if _, err := signer(path); err == nil {
		t.Fatal("accepted a private key with a read-only grant to Everyone")
	}
	windowsAssertKeyBytes(t, path, original)
}

func TestWindowsSigningKeyRejectsNULLDACL(t *testing.T) {
	path, original, _ := windowsSigningKeyFixture(t)
	_, err := signer(path)
	check(t, err)
	windowsSigningKeyDACL(t, path, true)
	if _, err := signer(path); err == nil {
		t.Fatal("accepted a private key with a permissive NULL access list")
	}
	windowsAssertKeyBytes(t, path, original)
}

func TestWindowsSigningKeyRejectsHardLinks(t *testing.T) {
	path, original, _ := windowsSigningKeyFixture(t)
	_, err := signer(path)
	check(t, err)
	alias := filepath.Join(filepath.Dir(path), "second.pem")
	check(t, os.Link(path, alias))
	for _, name := range []string{path, alias} {
		if _, err := signer(name); err == nil {
			t.Fatal("accepted a private key with another hard link")
		}
		windowsAssertKeyBytes(t, name, original)
	}
}
