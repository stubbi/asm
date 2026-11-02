// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Darwin ACLs can grant access beyond the Unix mode bits. Inspect the held
// descriptor through the system ls, with a clean environment, a byte cap, and
// a deadline. -L follows /dev/fd/3, not an attacker-controlled pathname. The
// assembly caller separately qualifies the installation's APFS volume.
func platformPermissions(file *os.File) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/ls", "-Llde", "/dev/fd/3")
	cmd.Env = []string{"PATH=/usr/bin:/bin", "LC_ALL=C"}
	cmd.ExtraFiles = []*os.File{file}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	data, readErr := io.ReadAll(io.LimitReader(stdout, 65537))
	if readErr != nil || len(data) > 65536 {
		cancel()
	}
	err = errors.Join(readErr, cmd.Wait())
	if err != nil {
		return err
	}
	if len(data) > 65536 {
		return errors.New("ACL listing exceeds limit")
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) == 0 || len(lines[0]) == 0 {
		return errors.New("missing ACL listing")
	}
	for _, line := range lines[1:] {
		if !strings.Contains(line, " deny ") || strings.Contains(line, " allow ") {
			return errors.New("ACL allow entries are not supported for trust files")
		}
	}
	return nil
}
