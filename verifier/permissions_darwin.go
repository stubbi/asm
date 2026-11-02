// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"encoding/binary"
	"errors"
	"os"
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Darwin ACLs can grant access beyond the Unix mode bits. fgetattrlist reads
// the held descriptor; /dev/fd aliases do not expose the target's ACL to ls.
// Request no returned-attribute mask, so unsupported attributes cause an error.
// The assembly caller separately qualifies the installation's APFS volume.
func platformPermissions(file *os.File) error {
	// Darwin's getattrlist(2) ABI returns a length and an attrreference_t.
	// The security data uses kauth_filesec and kauth_ace from sys/kauth.h.
	// Layout source: Apple xnu-11417.140.69, reviewed 2 November 2026.
	const (
		attributeHeaderSize = 12
		fileSecuritySize    = 44
		entrySize           = 24
		maxEntries          = 128
		fileSecurityMagic   = 0x012cc16d
		noACL               = 0xffffffff
		entryKindMask       = 0xf
		entryDeny           = 2
	)
	attributes := unix.Attrlist{Bitmapcount: unix.ATTR_BIT_MAP_COUNT, Commonattr: unix.ATTR_CMN_EXTENDED_SECURITY}
	var buffer [attributeHeaderSize + fileSecuritySize + maxEntries*entrySize]byte
	for {
		_, _, errno := syscall.Syscall6(unix.SYS_FGETATTRLIST, file.Fd(),
			uintptr(unsafe.Pointer(&attributes)), uintptr(unsafe.Pointer(&buffer[0])),
			uintptr(len(buffer)), unix.FSOPT_REPORT_FULLSIZE, 0)
		runtime.KeepAlive(file)
		if errno == syscall.EINTR {
			continue
		}
		if errno != 0 {
			return errno
		}
		break
	}
	length := int(binary.NativeEndian.Uint32(buffer[:4]))
	if length < attributeHeaderSize || length > len(buffer) {
		return errors.New("invalid ACL attribute length")
	}
	// The reference starts at byte 4. Its offset is signed and relative to it.
	offset := int(int32(binary.NativeEndian.Uint32(buffer[4:8]))) + 4
	size := int(binary.NativeEndian.Uint32(buffer[8:12]))
	if offset < attributeHeaderSize || offset > length || size != length-offset {
		return errors.New("invalid ACL attribute reference")
	}
	if size == 0 {
		return nil // The descriptor has no extended ACL.
	}
	security := buffer[offset:length]
	if len(security) < fileSecuritySize || binary.NativeEndian.Uint32(security[:4]) != fileSecurityMagic {
		return errors.New("invalid ACL security data")
	}
	count := binary.NativeEndian.Uint32(security[36:40])
	if count == noACL && len(security) == fileSecuritySize {
		return nil
	}
	if count > maxEntries || len(security) != fileSecuritySize+int(count)*entrySize {
		return errors.New("invalid ACL entry count")
	}
	for start := fileSecuritySize; start < len(security); start += entrySize {
		flags := binary.NativeEndian.Uint32(security[start+16 : start+20])
		if flags&entryKindMask != entryDeny {
			return errors.New("ACL allow entries are not supported for trust files")
		}
	}
	return nil
}
