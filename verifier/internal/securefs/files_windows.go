// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors

// Package securefs supplies Windows file protection for the verifier and its
// maintainer key reader. It supports fixed local NTFS volumes only.
package securefs

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Directory retains every ancestor without delete sharing. Path-based library
// I/O cannot be redirected by renaming a checked ancestor while it is held.
// Same-account mutation and administrators remain outside this boundary.
type Directory struct {
	*os.File
	parents []*os.File
}

// Close releases the directory and all retained ancestors.
func (d *Directory) Close() error {
	err := d.File.Close()
	for i := len(d.parents) - 1; i >= 0; i-- {
		err = errors.Join(err, d.parents[i].Close())
	}
	return err
}

type identity struct {
	user, installer *windows.SID
	elevated        bool
}

func currentIdentity() (*identity, error) {
	token := windows.GetCurrentProcessToken()
	user, err := token.GetTokenUser()
	if err != nil {
		return nil, err
	}
	sid, err := user.User.Sid.Copy()
	if err != nil {
		return nil, err
	}
	// This is an OS service identity, not a caller-supplied account or group.
	installer, _, _, err := windows.LookupSID("", `NT SERVICE\TrustedInstaller`)
	if err != nil {
		return nil, err
	}
	return &identity{user: sid, installer: installer, elevated: token.IsElevated()}, nil
}

func (id *identity) system(sid *windows.SID) bool {
	return sid.IsWellKnown(windows.WinLocalSystemSid) || sid.IsWellKnown(windows.WinBuiltinAdministratorsSid) || sid.Equals(id.installer)
}

func (id *identity) fileOwner(sid *windows.SID) bool {
	// Elevated Windows tokens can create ordinary files with Administrators as
	// their default owner. This privileged principal is already outside the
	// threat boundary; a filtered or ordinary user does not gain this exception.
	return sid.Equals(id.user) || (id.elevated && sid.IsWellKnown(windows.WinBuiltinAdministratorsSid))
}

func privateDescriptor(id *identity) (*windows.SECURITY_DESCRIPTOR, error) {
	sid := id.user.String()
	return windows.SecurityDescriptorFromString("O:" + sid + "D:P(A;OICI;FA;;;" + sid + ")(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
}

// cleanPath accepts canonical DOS drive paths, never UNC, device namespaces,
// alternate data streams, reserved DOS names, or trailing-dot/space aliases.
func cleanPath(path string) (string, []string, error) {
	volume := filepath.VolumeName(path)
	if len(volume) != 2 || volume[1] != ':' || !((volume[0] >= 'A' && volume[0] <= 'Z') || (volume[0] >= 'a' && volume[0] <= 'z')) || !filepath.IsAbs(path) || filepath.Clean(path) != path || strings.Contains(path, "/") || len(path) > 32700 {
		return "", nil, errors.New("expected a clean absolute local drive path")
	}
	rest := strings.TrimPrefix(path[len(volume):], `\`)
	if rest == "" {
		return volume + `\`, nil, nil
	}
	parts := strings.Split(rest, `\`)
	for _, part := range parts {
		if part == "" || part == "." || part == ".." || !filepath.IsLocal(part) || strings.ContainsAny(part, ":\x00") || strings.HasSuffix(part, ".") || strings.HasSuffix(part, " ") || len(part) > 255 {
			return "", nil, errors.New("unsupported Windows path component")
		}
		for _, r := range part {
			if r < 32 || r == 127 {
				return "", nil, errors.New("control character in path")
			}
		}
	}
	return volume + `\`, parts, nil
}

func pathError(op, path string, err error) error {
	if status, ok := err.(windows.NTStatus); ok {
		err = status.Errno()
	}
	return &os.PathError{Op: op, Path: path, Err: err}
}

func openAt(parent windows.Handle, name string, access, disposition, options uint32, descriptor *windows.SECURITY_DESCRIPTOR) (windows.Handle, error) {
	objectName, err := windows.NewNTUnicodeString(name)
	if err != nil {
		return windows.InvalidHandle, err
	}
	attributes := windows.OBJECT_ATTRIBUTES{Length: uint32(unsafe.Sizeof(windows.OBJECT_ATTRIBUTES{})), RootDirectory: parent, ObjectName: objectName, Attributes: windows.OBJ_CASE_INSENSITIVE, SecurityDescriptor: descriptor}
	var handle windows.Handle
	var status windows.IO_STATUS_BLOCK
	err = windows.NtCreateFile(&handle, access, &attributes, &status, nil, windows.FILE_ATTRIBUTE_NORMAL, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, disposition, options|windows.FILE_OPEN_REPARSE_POINT|windows.FILE_SYNCHRONOUS_IO_NONALERT, 0, 0)
	runtime.KeepAlive(descriptor)
	runtime.KeepAlive(objectName)
	if err != nil {
		return windows.InvalidHandle, err
	}
	return handle, nil
}

func inspect(handle windows.Handle, directory bool) (windows.ByHandleFileInformation, error) {
	var info windows.ByHandleFileInformation
	kind, err := windows.GetFileType(handle)
	if err != nil {
		return info, err
	}
	if kind != windows.FILE_TYPE_DISK {
		return info, errors.New("trust files require a disk handle")
	}
	if err = windows.GetFileInformationByHandle(handle, &info); err != nil {
		return info, err
	}
	if info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return info, errors.New("reparse points are not supported")
	}
	isDirectory := info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0
	if isDirectory != directory {
		return info, errors.New("unexpected file type")
	}
	if !directory && info.NumberOfLinks != 1 {
		return info, errors.New("trust files require exactly one hard link")
	}
	return info, nil
}

func checkVolume(handle windows.Handle) error {
	var fs [32]uint16
	var flags uint32
	if err := windows.GetVolumeInformationByHandle(handle, nil, 0, nil, nil, &flags, &fs[0], uint32(len(fs))); err != nil {
		return err
	}
	if windows.UTF16ToString(fs[:]) != "NTFS" || flags&windows.FILE_PERSISTENT_ACLS == 0 || flags&windows.FILE_READ_ONLY_VOLUME != 0 {
		return errors.New("trust state requires writable local NTFS with persistent ACLs")
	}
	var final [32768]uint16
	n, err := windows.GetFinalPathNameByHandle(handle, &final[0], uint32(len(final)), 1) // VOLUME_NAME_GUID
	if err != nil {
		return err
	}
	if n >= uint32(len(final)) {
		return errors.New("volume path exceeds its limit")
	}
	name := windows.UTF16ToString(final[:n])
	if !strings.HasPrefix(name, `\\?\Volume{`) {
		return errors.New("a local volume GUID is required")
	}
	end := strings.Index(name, `}\`)
	if end < 0 {
		return errors.New("invalid volume GUID path")
	}
	root, err := windows.UTF16PtrFromString(name[:end+2])
	if err != nil {
		return err
	}
	if windows.GetDriveType(root) != windows.DRIVE_FIXED {
		return errors.New("trust state requires a fixed local volume")
	}
	return nil
}

func checkSecurity(handle windows.Handle, id *identity, private, directory bool) error {
	descriptor, err := windows.GetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := descriptor.Owner()
	if err != nil {
		return err
	}
	if owner == nil || !owner.IsValid() {
		return errors.New("invalid file owner")
	}
	if private && directory {
		if !owner.Equals(id.user) {
			return errors.New("private state must belong to the current user")
		}
	} else if directory {
		if !owner.Equals(id.user) && !id.system(owner) {
			return errors.New("untrusted directory owner")
		}
	} else if !id.fileOwner(owner) {
		return errors.New("file owner differs from the current security token")
	}
	acl, _, err := descriptor.DACL()
	if err != nil || acl == nil {
		return errors.New("missing or NULL access-control list")
	}
	control, _, err := descriptor.Control()
	if err != nil {
		return err
	}
	if private && directory && control&windows.SE_DACL_PROTECTED == 0 {
		return errors.New("private state must have a protected access-control list")
	}
	if acl.AceCount > 1024 {
		return errors.New("access-control list exceeds its limit")
	}
	// Windows file access-rights constants absent from pinned x/sys:
	// FILE_DELETE_CHILD=0x40; FILE_ALL_ACCESS includes every file-specific bit.
	const fileDeleteChild = 0x40
	const fileAllAccess = windows.STANDARD_RIGHTS_REQUIRED | windows.SYNCHRONIZE | 0x1ff
	inheritsUserControl := false
	const dangerous = windows.GENERIC_ALL | windows.GENERIC_WRITE | windows.WRITE_DAC | windows.WRITE_OWNER | windows.DELETE | fileDeleteChild | windows.FILE_WRITE_DATA | windows.FILE_APPEND_DATA | windows.FILE_WRITE_EA | windows.FILE_WRITE_ATTRIBUTES
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, i, &ace); err != nil {
			return err
		}
		// A private directory also protects inherited child ACLs: the pinned
		// library creates metadata temporary files with default inheritance.
		// Ordinary ancestors are checked for effective access only; each
		// descendant is opened and checked independently.
		if ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0 && !(private && directory) {
			continue
		}
		if ace.Header.AceType == windows.ACCESS_DENIED_ACE_TYPE {
			continue
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return errors.New("unsupported access-control entry type")
		}
		if ace.Header.AceSize < 16 {
			return errors.New("truncated access-control entry")
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if 8+4*uint32(sid.SubAuthorityCount()) > uint32(ace.Header.AceSize)-8 || !sid.IsValid() {
			return errors.New("invalid access-control entry SID")
		}
		if sid.Equals(id.user) {
			flags := ace.Header.AceFlags
			full := ace.Mask&windows.GENERIC_ALL != 0 || ace.Mask&fileAllAccess == fileAllAccess
			inherit := byte(windows.OBJECT_INHERIT_ACE | windows.CONTAINER_INHERIT_ACE)
			if full && flags&inherit == inherit && flags&windows.NO_PROPAGATE_INHERIT_ACE == 0 {
				inheritsUserControl = true
			}
			continue
		}
		if id.system(sid) {
			continue
		}
		mask := uint32(ace.Mask)
		if private && mask != 0 {
			return errors.New("private data grants access to another account")
		}
		forbidden := uint32(dangerous)
		// Adding a new sibling directory does not authorize replacing an
		// existing protected child. Stock drive roots can grant this one bit.
		// FILE_WRITE_DATA, DELETE_CHILD and every other mutation remain denied.
		if directory {
			forbidden &^= windows.FILE_APPEND_DATA
		}
		if mask&forbidden != 0 {
			return errors.New("another account can modify a protected path")
		}
	}
	if private && directory && !inheritsUserControl {
		return errors.New("private state requires inheritable current-user full control")
	}
	return nil
}

// OpenDirectory walks handle-relative components and creates only a missing
// final private directory, with its protected ACL already supplied at creation.
func OpenDirectory(path string, private, create bool) (*Directory, error) {
	root, parts, err := cleanPath(path)
	if err != nil {
		return nil, err
	}
	if private && len(parts) == 0 {
		return nil, errors.New("the drive root cannot hold private state")
	}
	id, err := currentIdentity()
	if err != nil {
		return nil, err
	}
	pointer, err := windows.UTF16PtrFromString(root)
	if err != nil {
		return nil, err
	}
	access := uint32(windows.FILE_LIST_DIRECTORY | windows.FILE_READ_ATTRIBUTES | windows.READ_CONTROL | windows.SYNCHRONIZE)
	handle, err := windows.CreateFile(pointer, access, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, pathError("open", root, err)
	}
	files := []*os.File{os.NewFile(uintptr(handle), root)}
	fail := func(err error) (*Directory, error) {
		for i := len(files) - 1; i >= 0; i-- {
			err = errors.Join(err, files[i].Close())
		}
		return nil, err
	}
	if _, err = inspect(handle, true); err != nil {
		return fail(err)
	}
	if err = checkVolume(handle); err != nil {
		return fail(err)
	}
	if err = checkSecurity(handle, id, false, true); err != nil {
		return fail(err)
	}
	prefix := root
	for i, part := range parts {
		prefix = filepath.Join(prefix, part)
		next, err := openAt(handle, part, access, windows.FILE_OPEN, windows.FILE_DIRECTORY_FILE, nil)
		if err != nil && errors.Is(pathError("open", prefix, err), os.ErrNotExist) && create && i == len(parts)-1 {
			sd, sdErr := privateDescriptor(id)
			if sdErr != nil {
				return fail(sdErr)
			}
			next, err = openAt(handle, part, access, windows.FILE_CREATE, windows.FILE_DIRECTORY_FILE, sd)
		}
		if err != nil {
			return fail(pathError("open", prefix, err))
		}
		files = append(files, os.NewFile(uintptr(next), prefix))
		handle = next
		if _, err = inspect(handle, true); err != nil {
			return fail(err)
		}
		if err = checkSecurity(handle, id, private && i == len(parts)-1, true); err != nil {
			return fail(err)
		}
	}
	return &Directory{File: files[len(files)-1], parents: files[:len(files)-1]}, nil
}

func openFile(path string, flags int, private bool) (*os.File, error) {
	_, parts, err := cleanPath(path)
	if err != nil {
		return nil, err
	}
	if len(parts) == 0 {
		return nil, errors.New("a regular file is required")
	}
	if flags & ^(os.O_RDONLY|os.O_WRONLY|os.O_RDWR|os.O_CREATE|os.O_EXCL) != 0 {
		return nil, errors.New("unsupported secure file flags")
	}
	parent, err := OpenDirectory(filepath.Dir(path), false, false)
	if err != nil {
		return nil, err
	}
	defer parent.Close() // Read-only directory handles are released after open.
	id, err := currentIdentity()
	if err != nil {
		return nil, err
	}
	access := uint32(windows.READ_CONTROL | windows.FILE_READ_ATTRIBUTES | windows.SYNCHRONIZE)
	if flags&os.O_RDWR != 0 {
		access |= windows.GENERIC_READ | windows.GENERIC_WRITE
	} else if flags&os.O_WRONLY != 0 {
		access |= windows.GENERIC_WRITE
	} else {
		access |= windows.GENERIC_READ
	}
	disposition := uint32(windows.FILE_OPEN)
	var sd *windows.SECURITY_DESCRIPTOR
	if flags&os.O_CREATE != 0 {
		disposition = windows.FILE_OPEN_IF
		if flags&os.O_EXCL != 0 {
			disposition = windows.FILE_CREATE
		}
		sd, err = privateDescriptor(id)
		if err != nil {
			return nil, err
		}
	}
	handle, err := openAt(windows.Handle(parent.Fd()), parts[len(parts)-1], access, disposition, windows.FILE_NON_DIRECTORY_FILE, sd)
	if err != nil {
		return nil, pathError("open", path, err)
	}
	file := os.NewFile(uintptr(handle), path)
	if _, err = inspect(handle, false); err != nil {
		file.Close()
		return nil, err
	}
	if err = checkSecurity(handle, id, private, false); err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}

// OpenFile refuses unsafe parents, reparse points, extra links, unsafe owners,
// and effective ACL grants that permit another unprivileged account to write.
func OpenFile(path string, flags int) (*os.File, error) { return openFile(path, flags, false) }

// ReadPrivate reads a bounded single-link private file through its checked
// handle. It also rejects read access granted to unrelated unprivileged SIDs.
func ReadPrivate(path string, limit int64) ([]byte, error) {
	f, err := openFile(path, os.O_RDONLY, true)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if info.Size() < 1 || info.Size() > limit {
		return nil, errors.New("private file exceeds size bounds")
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) != info.Size() {
		return nil, errors.New("private file changed while reading")
	}
	return data, nil
}

// LockFile obtains a nonblocking exclusive byte-range lock. The protected lock
// handle must stay open until the returned unlock operation has completed.
func LockFile(file *os.File) (func() error, error) {
	var overlapped windows.Overlapped
	if err := windows.LockFileEx(windows.Handle(file.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlapped); err != nil {
		return nil, err
	}
	return func() error { return windows.UnlockFileEx(windows.Handle(file.Fd()), 0, 1, 0, &overlapped) }, nil
}

// SyncFile flushes the same checked inode through a write-capable handle.
func SyncFile(file *os.File) error {
	writer, err := OpenFile(file.Name(), os.O_RDWR)
	if err != nil {
		return err
	}
	before, err := file.Stat()
	if err != nil {
		writer.Close()
		return err
	}
	after, err := writer.Stat()
	if err != nil {
		writer.Close()
		return err
	}
	if !os.SameFile(before, after) {
		writer.Close()
		return errors.New("file identity changed before flush")
	}
	return errors.Join(writer.Sync(), writer.Close())
}

// SyncDirectory performs real flushes of the caller's fixed committed files.
// Windows supplies no non-administrator directory-fsync equivalent. This is
// not a promise of power-loss durability for directory entries or deletions.
func SyncDirectory(directory *Directory, names []string) error {
	id, err := currentIdentity()
	if err != nil {
		return err
	}
	if _, err = inspect(windows.Handle(directory.Fd()), true); err != nil {
		return err
	}
	if err = checkSecurity(windows.Handle(directory.Fd()), id, true, true); err != nil {
		return err
	}
	for _, name := range names {
		if !filepath.IsLocal(name) || strings.ContainsAny(name, `\/`) {
			return errors.New("invalid fixed metadata name")
		}
		f, err := OpenFile(filepath.Join(directory.Name(), name), os.O_RDWR)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		if err = errors.Join(f.Sync(), f.Close()); err != nil {
			return err
		}
	}
	return nil
}

// AtomicWrite flushes an exclusive protected temporary file before a checked
// same-volume replacement. The final move is the last fallible commit step.
// No COPY_ALLOWED fallback is used. A failed pre-commit check preserves the
// previous destination. Multi-file and power-loss durability are not claimed.
func AtomicWrite(path string, data []byte) error {
	parent, err := OpenDirectory(filepath.Dir(path), false, false)
	if err != nil {
		return err
	}
	defer parent.Close()
	_, parts, err := cleanPath(path)
	if err != nil {
		return err
	}
	if len(parts) == 0 {
		return errors.New("a file destination is required")
	}
	existing, err := OpenFile(path, os.O_RDONLY)
	if err == nil {
		if err = existing.Close(); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	var file *os.File
	for i := 0; i < 8; i++ {
		var nonce [16]byte
		if _, err = rand.Read(nonce[:]); err != nil {
			return err
		}
		name := filepath.Join(parent.Name(), ".trust-"+hex.EncodeToString(nonce[:]))
		file, err = OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL)
		if os.IsExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		break
	}
	if file == nil {
		return errors.New("temporary file collision limit reached")
	}
	defer os.Remove(file.Name()) // Only the invocation's exclusive stage name.
	written, writeErr := file.Write(data)
	if writeErr == nil && written != len(data) {
		writeErr = io.ErrShortWrite
	}
	if writeErr == nil {
		writeErr = file.Sync()
	}
	writeErr = errors.Join(writeErr, file.Close())
	if writeErr != nil {
		return writeErr
	}
	from, err := windows.UTF16PtrFromString(file.Name())
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	if err = windows.MoveFileEx(from, to, windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH); err != nil {
		return fmt.Errorf("atomic metadata replacement: %w", err)
	}
	return nil
}
