// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"path/filepath"

	"github.com/stubbi/asm/verifier/internal/securefs"
)

func readPrivateKey(path string) ([]byte, error) {
	path, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	return securefs.ReadPrivate(path, 16384)
}
