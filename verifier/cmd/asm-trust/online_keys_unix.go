//go:build linux || darwin

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

func openOnlineKeyDirectory(path string) (*os.File, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	directory := os.NewFile(uintptr(fd), path)
	info, err := directory.Stat()
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		directory.Close()
		return nil, errors.New("use a private physical online signing directory")
	}
	return directory, nil
}
