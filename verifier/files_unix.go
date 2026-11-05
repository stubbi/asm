//go:build linux || darwin

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

type stateDirectory struct{ *os.File }

func acquireStateLock(file *os.File) (func() error, error) {
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return nil, err
	}
	return func() error { return unix.Flock(int(file.Fd()), unix.LOCK_UN) }, nil
}

func syncOpenedFile(file *os.File) error { return file.Sync() }

// openState walks each component without following symlinks. Root-owned sticky
// /tmp (or /private/tmp) is allowed only above a protected user-owned child.
// Same-account mutation and an administrator remain outside this boundary.
func openState(path string) (*stateDirectory, error) {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path || path == "/" {
		return nil, errors.New("trust state requires a clean absolute path")
	}
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	directory := os.NewFile(uintptr(fd), "/")
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	prefix := ""
	needOwned := false
	for i, part := range parts {
		prefix += "/" + part
		next, err := unix.Openat(int(directory.Fd()), part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if err == unix.ENOENT && i == len(parts)-1 {
			if err = unix.Mkdirat(int(directory.Fd()), part, 0700); err == nil {
				next, err = unix.Openat(int(directory.Fd()), part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
			}
		}
		directory.Close()
		if err != nil {
			return nil, err
		}
		directory = os.NewFile(uintptr(next), prefix)
		var st unix.Stat_t
		if err = unix.Fstat(next, &st); err != nil {
			directory.Close()
			return nil, err
		}
		owned := st.Uid == uint32(os.Getuid())
		sticky := st.Uid == 0 && st.Mode&unix.S_ISVTX != 0 && (prefix == "/tmp" || prefix == "/private/tmp")
		if (!owned && st.Uid != 0) || (needOwned && (!owned || st.Mode&0022 != 0)) ||
			(st.Mode&0022 != 0 && !sticky) || (i == len(parts)-1 && (!owned || st.Mode&0077 != 0)) {
			directory.Close()
			return nil, errors.New("trust state has unsafe ownership or directory permissions")
		}
		if err := platformPermissions(directory); err != nil {
			directory.Close()
			return nil, err
		}
		needOwned = sticky
	}
	return &stateDirectory{File: directory}, nil
}

func openFile(path string, flags int, mode uint32) (*os.File, error) {
	fd, err := unix.Open(path, flags|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, mode)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path)
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	st := info.Sys().(*syscall.Stat_t)
	if !info.Mode().IsRegular() || st.Nlink != 1 || st.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0022 != 0 {
		f.Close()
		return nil, errors.New("expected an owned regular file with one link and protected permissions")
	}
	if err := platformPermissions(f); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

func atomicWrite(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".trust-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	err = errors.Join(err, f.Close())
	if err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
