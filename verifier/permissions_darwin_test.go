// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestDarwinHeldDescriptorACL(t *testing.T) {
	for _, directory := range []bool{false, true} {
		kind := "file"
		if directory {
			kind = "directory"
		}
		for _, tc := range []struct {
			name    string
			entries []string
			reject  bool
		}{
			{name: "no ACL"},
			{name: "deny only", entries: []string{"everyone deny execute"}},
			{name: "read allow", entries: []string{"everyone allow readsecurity"}, reject: true},
			{name: "write allow", entries: []string{"everyone allow writesecurity"}, reject: true},
			{name: "deny and allow", entries: []string{"everyone deny execute", "everyone allow readsecurity"}, reject: true},
		} {
			t.Run(kind+"/"+tc.name, func(t *testing.T) {
				path := filepath.Join(t.TempDir(), "held")
				if directory {
					must(t, os.Mkdir(path, 0700))
				} else {
					must(t, os.WriteFile(path, []byte("fixture"), 0600))
				}
				t.Cleanup(func() { _ = exec.Command("/bin/chmod", "-N", path).Run() })
				for _, entry := range tc.entries {
					must(t, exec.Command("/bin/chmod", "+a", entry, path).Run())
				}
				file, err := os.Open(path)
				must(t, err)
				defer file.Close()
				// Replacing the original pathname must not change the object checked.
				moved := path + "-moved"
				must(t, os.Rename(path, moved))
				t.Cleanup(func() { _ = exec.Command("/bin/chmod", "-N", moved).Run() })
				must(t, os.WriteFile(path, []byte("replacement"), 0600))
				if err := platformPermissions(file); (err != nil) != tc.reject {
					t.Fatalf("platformPermissions error = %v; rejection wanted = %v", err, tc.reject)
				}
			})
		}
	}
}
