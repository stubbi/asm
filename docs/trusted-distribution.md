# Provision Asm distribution trust

Status: gated implementation; production trust is not provisioned.
Published CLI installers still require GitHub CLI.
The default release and Pages workflows retain that path during migration.

## Intended result and activation conditions

The intended result is installation and manual updates without a separately installed provenance verifier.

Acceptance requires these results:

- Install on each supported host without GitHub CLI.
- Authenticate the verifier before its first execution.
- Preserve the existing publisher, workflow, source, format, ownership, and replacement checks.
- Reject expired metadata, replay, mixed snapshots, incorrect keys, and altered artifacts.
- Retain verified metadata versions across failures and process restarts.
- Qualify root rotation and recovery before activation.
- Publish a new immutable release and verify the deployed first-project flow.

The disabled implementation can merge after native tests, failure-path checks, and history and security review pass.
Production activation requires the offline root ceremony, metadata renewal operations, independent human security review, and a recovery rehearsal.
Keep the release flag disabled until all activation conditions hold.

## Implementation boundary

The assembly CLI selects packages, parses release manifests, checks executable formats, and commits replacements.
It carries the verifier bytes in its own executable.
During an update, it writes those bytes into its protected staging directory.
It executes that copy with fixed arguments and the existing child deadline.
It never executes the downloaded candidate to verify itself.

`verifier/` uses Sigstore's Go library and go-tuf/v2 for transport and cryptography.
Go is a build dependency.
Users retain the existing operating-system tools for transport, hashing, and project builds.
The Linux x86-64 adapter measured approximately 19 MB in this development build.
That size is the trade-off for removing a separate verifier installation while retaining established implementations.

The bootstrap pins a verifier's URL, byte size, and SHA-256.
It checks those bytes before execution.
It then requires current Asm authorization and the existing release-provenance policy.
The initial installer still depends on its HTTPS delivery and the origin's integrity.
A modified installer cannot authenticate itself.

## Two separate trust systems

Sigstore authenticates release provenance.
The fixed policy retains repository ID `1441332955`, the release workflow, main source ref, hosted runner, and exact source/signer commit.
The adapter requires certificate-transparency and artifact-transparency evidence.
It uses Sigstore's authenticated root distribution, with explicit HTTPS transport bounds.

Asm's separate TUF repository authorizes current update metadata and artifacts.
It uses root, targets, snapshot, and timestamp roles with distinct Ed25519 keys.
The offline root requires two of three keys.
Consistent snapshots bind metadata versions, lengths, and hashes.

Clients retain state in `$HOME/.local/bin/.asm-trust`.
The directory must be private and user-owned.
Updates refresh metadata even when the requested version equals the installed version.
An equal version remains a no-op after that refresh.
Removing a target blocks new selection of that artifact through this profile.
It does not remove or stop an existing installation.

Trusted state is not a disposable download cache.
Deleting it discards previously observed versions.
Same-account mutation, administrator compromise, and a compromised system clock remain outside the protection boundary.
The client detects a backward clock change exceeding five minutes relative to its retained observation.

The client retains `rotation-root.json` as a recovery checkpoint before refreshing metadata.
After a verified timestamp or snapshot key change, it removes obsolete timestamp and snapshot history.
Interrupted cleanup resumes on the next update.
Root renewal with unchanged keys retains replay protection.

## Create the root offline

Choose the root-key custodians and recovery locations before creating keys.
Keep the three root private keys on separate offline devices or protected offline storage.
Do not create production root keys in CI or an agent workspace.
Do not send private keys through chat or commit them to Git.

The following commands use OpenSSL and the maintainer tool on trusted machines.
The key files require encrypted storage and protected backups.
Prepare the tools and verified dependencies before disconnecting the root-signing devices.
Keep root-key creation and signing offline.

1. Build the maintainer tools from a reviewed commit:

   ```sh
   cd verifier
   go build -trimpath -o ../build/asm-trust ./cmd/asm-trust
   go build -trimpath -o ../build/asm-verify .
   cd ..
   ```

2. On each root custodian's device, create one key:

   ```sh
   umask 077
   openssl genpkey -algorithm ED25519 -out root.pem
   openssl pkey -in root.pem -pubout -out root.pub
   ```

3. Create separate targets, snapshot, and timestamp keys in their selected signing environment.
4. Transfer only the six public keys to the root-preparation device.
5. Prepare the unsigned root:

   ```sh
   build/asm-trust prepare-root unsigned.json root1.pub root2.pub root3.pub targets.pub snapshot.pub timestamp.pub
   ```

6. Have the first custodian inspect every public key and role.
7. Have that custodian sign the root:

   ```sh
   build/asm-trust sign-root unsigned.json root.pem first-signature.json
   ```

8. Transfer the signed public document to the second custodian.
9. Have that custodian inspect and sign the same root:

   ```sh
   build/asm-trust sign-root first-signature.json root.pem asm-root.json
   build/asm-verify check-root asm-root.json
   ```

10. Record the public-root digest, custodians, backup locations, and recovery exercise outside the repository's public documentation.
11. Submit the public root as `verifier/trust/asm-root.json` through a reviewed pull request.

The checked-in root is deliberately empty until this ceremony is complete.
`make trusted-cli` fails closed while it is empty.
Test keys exist only inside test fixtures and must never supply this root.

## Build and publish a release

Use a new version.
Previously published binaries remain unchanged.

Run `make verifier-test` and the existing release gates.
Review the native results on all three hosts.
Enable the Release workflow's `trusted_distribution` input for the new release.
The release builder compares two builds of each verifier.
It includes their hashes in the signed release manifest and checksums.
It also publishes the pinned installer as `install.sh`.

For a local build, use:

```sh
make trusted-cli
```

The normal source build retains the existing external-verifier route during migration.
The release builder accepts `--trusted-distribution` for both native qualification and the final release.

Keep the dependency versions and checksums in `verifier/go.mod` and `verifier/go.sum`.
Review dependency changes and retain their license notices with distributed source.
The helper uses Apache-2.0 and other compatible third-party components; Asm's adapter remains AGPL-3.0-or-later.

## Publish update metadata

Store executable assets, the source archive, checksums, the manifest, and provenance on GitHub Releases.
Serve the installer and TUF publication through asm.build.
The publication contains `metadata/` and hash-prefixed index files under `targets/`.
Binary target records authorize the corresponding immutable GitHub assets.

Prepare a JSON map from target names to qualified local files:

```json
{
  "index.tsv": "/release/index.tsv",
  "index-macos.tsv": "/release/index-macos.tsv",
  "asm-0.5.0-x86_64-linux": "/release/asm-0.5.0-x86_64-linux",
  "asm-0.5.0-aarch64-linux": "/release/asm-0.5.0-aarch64-linux",
  "asm-0.5.0-aarch64-macos": "/release/asm-0.5.0-aarch64-macos"
}
```

The version is illustrative.
Include every artifact that the current policy authorizes.
Use the exact generated indexes for the site deployment.

The signing directory contains only `targets.pem`, `snapshot.pem`, and `timestamp.pem`.
Each private file must have mode 0600 or stricter.
Publish the first metadata set with:

```sh
build/asm-trust publish verifier/trust/asm-root.json /protected/signers - target-map.json publication
build/asm-trust inspect verifier/trust/asm-root.json publication target-map.json
```

For later publications, replace `-` with the previous complete publication directory.
The tool increments versions and retains immutable metadata and target files.
It requires a new output directory.
It exposes that directory only after signing succeeds.

Timestamp metadata expires after 24 hours.
Snapshot metadata expires after seven days; targets expire after 30 days.
Refresh publication at least every 12 hours, using a durable, serialized record of the previous publication.
Do not restart version numbering or derive it solely from a possibly stale public mirror.
Select and provision the online signing environment before enabling this schedule.
No production keys or schedule are configured by this change.

After publishing the release assets, build the site with:

```sh
python3 tools/build_site.py --output .pages --verify-artifacts \
  --trust-publication publication \
  --trust-verifier build/asm-verify \
  --trust-inspector build/asm-trust
```

The site builder checks signed provenance for the release manifest.
It checks the installer's manifest binding and the TUF bindings for the generated indexes and selected executables.
Deploy the complete staged site as one publication.
Retain every published versioned root, snapshot, targets document, and hash-prefixed index.

The existing scheduled Pages workflow needs the selected signing environment and durable publication state before this mode can be enabled.
Do not enable it with a one-off timestamp that will expire without renewal.

## Recovery and migration

Keep sequential versioned roots available for clients that missed releases.
A rotated root needs the old threshold and the new threshold.
Review its keys and role separation before publication.
Use the offline root to replace compromised online keys.
Complete a recovery rehearsal before public activation.

Older clients retain their current provenance checks when upgrading to the first bundled-verifier release.
They cannot gain Asm freshness protection before that upgrade.
Preserve the Linux-compatible index and the separate macOS index during migration.

## Evidence and remaining gates

Local development checks exercised genuine signatures from Asm 0.4.0's published release bundle.
They also exercised changed artifacts, wrong source commits, and invalid signatures.
Generated TUF fixtures exercised expiry, replay across restarts, mixed snapshots, root thresholds, rotation, and failed-refresh state retention.
Bootstrap tests exercised an absent GitHub CLI, corrupted verifier bytes, rejected authorization, network failure, and an existing destination.
Recovery tests exercise process exits after root persistence and restart after partial cleanup.
These tests do not simulate hardware power loss.

The initial workspace could not run native updater suites because `/tmp` was unavailable.
The same limitation affected the unchanged baseline.
The pull request records subsequent native qualification and regression results.
Native CI results are required before activation.
An independent human security review has not been performed.
A production recovery rehearsal remains an activation gate.
These tests do not establish an external security audit.

Protocol sources, reviewed 2 November 2026:

- [TUF specification](https://theupdateframework.github.io/specification/latest/).
- [go-tuf v2.4.2](https://github.com/theupdateframework/go-tuf/releases/tag/v2.4.2).
- [sigstore-go v1.4.0](https://github.com/sigstore/sigstore-go/releases/tag/v1.4.0).
- [Sigstore verification API](https://github.com/sigstore/sigstore-go/blob/v1.4.0/docs/verification.md).
