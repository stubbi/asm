// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"math"
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata"
)

// prepareNextRoot prepares an unsigned, sequential root on the offline ceremony
// device. It takes public keys only. Expiry of the authenticated previous root
// does not prevent recovery; clients still require a current final root and
// signatures meeting both old and new thresholds before accepting a rotation.
func prepareNextRoot(current, output string, publicFiles []string) error {
	if len(publicFiles) != 6 {
		return errors.New("provide three root and three distinct online public keys")
	}
	data, err := readJSON(current, 1<<20)
	if err != nil {
		return err
	}
	old, err := metadata.Root().FromBytes(data)
	if err != nil {
		return err
	}
	if old.Signed.Type != "root" || !old.Signed.ConsistentSnapshot ||
		old.Signed.Version < 1 || old.Signed.Version == math.MaxInt64 {
		return errors.New("previous root has an invalid profile or version")
	}
	if err := registryRootProfile(old.Signed); err != nil {
		return err
	}
	if err := old.VerifyDelegate("root", old); err != nil {
		return err
	}
	next := metadata.Root(time.Now().UTC().Add(365 * 24 * time.Hour))
	next.Signed.Version = old.Signed.Version + 1
	for index, role := range []string{"root", "root", "root", "targets", "snapshot", "timestamp"} {
		data, err := read(publicFiles[index], 16384)
		if err != nil {
			return err
		}
		block, rest := pem.Decode(data)
		if block == nil || block.Type != "PUBLIC KEY" || len(rest) != 0 {
			return errors.New("expected one Ed25519 public key")
		}
		public, err := x509.ParsePKIXPublicKey(block.Bytes)
		if err != nil {
			return err
		}
		if _, ok := public.(ed25519.PublicKey); !ok {
			return errors.New("expected Ed25519 public key")
		}
		key, err := metadata.KeyFromPublicKey(public)
		if err != nil {
			return err
		}
		if err := next.Signed.AddKey(key, role); err != nil {
			return err
		}
	}
	next.Signed.Roles["root"].Threshold = 2
	if err := registryRootProfile(next.Signed); err != nil {
		return err
	}
	data, err = next.ToBytes(true)
	if err != nil {
		return err
	}
	return exclusive(output, data)
}
