// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"github.com/stubbi/asm/verifier/internal/securefs"
	"os"
)

func platformPermissions(file *os.File) error { return securefs.CheckPermissions(file) }
