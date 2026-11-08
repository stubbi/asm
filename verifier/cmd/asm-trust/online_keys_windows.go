// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"path/filepath"

	"github.com/stubbi/asm/verifier/internal/securefs"
)

func openOnlineKeyDirectory(path string) (*securefs.Directory, error) {
	path, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	return securefs.OpenDirectory(path, true, false)
}
