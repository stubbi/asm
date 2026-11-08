//go:build linux || darwin

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"errors"
	"io"
	"os"
	"syscall"

	"github.com/stubbi/asm/verifier/internal/securefs"
	"golang.org/x/sys/unix"
)

func readPrivateKey(path string) ([]byte, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	st := info.Sys().(*syscall.Stat_t)
	if !info.Mode().IsRegular() || st.Nlink != 1 || st.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 || info.Size() < 1 || info.Size() > 16384 {
		return nil, errors.New("private key must be an owned single-link regular file with mode 0600 or stricter")
	}
	if err := securefs.CheckPermissions(file); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(file, 16385))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) != info.Size() {
		return nil, errors.New("private key changed while reading")
	}
	return data, nil
}
