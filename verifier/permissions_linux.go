// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import "os"

// Linux access ACL permissions are constrained by the group-class mode mask.
// The common checks reject writable masks, and state directories require 0700.
func platformPermissions(_ *os.File) error { return nil }
