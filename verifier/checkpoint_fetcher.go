// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 ASM contributors
package main

import (
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata/fetcher"
)

// The pinned client persists each verified role directly into retained state
// before requesting the next role. Flush completed writes before transport can
// block or terminate the process. Final Refresh errors use the same checked
// flush path. No metadata is deferred in a separate working cache.
type checkpointFetcher struct {
	fetcher.Fetcher
	checkpoint func() error
}

func (f *checkpointFetcher) DownloadFile(address string, limit int64, timeout time.Duration) ([]byte, error) {
	if err := f.checkpoint(); err != nil {
		return nil, err
	}
	return f.Fetcher.DownloadFile(address, limit, timeout)
}
