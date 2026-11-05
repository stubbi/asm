//go:build linux || darwin

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import "testing"

func privateFixtureDirectory(t *testing.T) string { t.Helper(); return t.TempDir() }
