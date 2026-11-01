# Update ASM

Use the bootstrap installer for the first installation.
Then use the installed ASM command:

    asm self update

To select an exact newer version, use:

    asm self update X.Y.Z

Replace X.Y.Z with the required version.
Use `asm self --help` for the command contract.
This operation is manual.
ASM does not start an update in the background.

## Supported installation

Self-update supports the direct `$HOME/.local/bin/asm` file on Linux x86-64.
Use the package manager for an installation that it owns.
Self-update does not run `sudo` or change `PATH`.

The executable must be a regular file with one hard link.
It must belong to the calling user.
The user ID and effective user ID must match.
The group ID and effective group ID must also match.
The file must have owner execute permission, without set-ID or group or other write bits.

`HOME` must be an absolute path without empty, dot, or parent components.
No installation path component can be a symbolic link.
Every directory from `/` through the installation path must belong to root or the calling user.
These directories cannot allow group or other writes.
The home, local, and bin directories must belong to the calling user.
The only writable ancestor exception is exact root-owned `/tmp` with its sticky bit set.
Its immediate child must belong to the calling user and deny group or other writes.
The sticky bit protects that child from removal or renaming by another user.
An arbitrary sticky directory does not qualify for this exception.
ASM rejects an installation that does not meet these conditions.

The supported local filesystems are ext4, XFS, Btrfs, tmpfs, OverlayFS, and F2FS.
Other filesystems require a manual installation or a package manager.
The command preserves the installed executable's permission bits.

## Required tools

The command uses fixed executable paths:

| Tool | Path | Purpose |
| --- | --- | --- |
| curl | `/usr/bin/curl` | HTTPS downloads |
| GNU sha256sum | `/usr/bin/sha256sum` | Artifact integrity |
| GitHub CLI, version 2.93.0 or later | `/usr/bin/gh` | Sigstore attestation verification |

Install GitHub CLI from its [official installation instructions](https://cli.github.com/).
No GitHub login is required for this bundle-based verification route.
A missing or unsupported verifier stops the update.
There is no checksum-only fallback.

## Verification contract

The package is fixed to `stubbi/asm`.
The index is fixed to `https://asm.build/registry/v1/index.tsv`.
No registry, local artifact, or installation path override is accepted.

ASM selects an executable for `x86_64-linux`.
Without an explicit version, it selects the highest numeric version in the index.
An older version is refused.
An equal version leaves the executable unchanged.
That result means no newer version was selected; it does not prove registry freshness.

The candidate URL must use this exact pattern:

    https://github.com/stubbi/asm/releases/download/vX.Y.Z/asm-X.Y.Z-x86_64-linux

The same release must contain `release.json` and `release-attestation.sigstore.json`.
Each file is limited to 1 MiB.
The bundle must be the action-produced single JSON object.
It is not a JSON-lines file.
Each curl child receives a kernel file-size limit for its requested download.
The limit is 1 MiB for metadata and the declared byte size for the candidate.
A stricter inherited limit remains in effect.
This download limit does not change the parent or verifier limits, including the verifier's cache writes.

Before replacement, ASM performs these checks:

1. Check the index format and selected target.
2. Check the candidate's exact size and SHA-256.
3. Check the host ELF format and segment bounds.
4. Verify the release manifest's attestation.
5. Parse the complete manifest with bounded native JSON validation.
6. Match the version, tag, repository, source commit, and selected asset.
7. Reverify the manifest and candidate against the same source and signer commit.

The verifier requires the following identity:

| Property | Required value |
| --- | --- |
| Repository | `stubbi/asm` |
| Numeric repository ID | `1441332955` |
| Workflow certificate identity | `https://github.com/stubbi/asm/.github/workflows/release.yml@refs/heads/main` |
| OIDC issuer | `https://token.actions.githubusercontent.com` |
| Source ref | `refs/heads/main` |
| Runner | GitHub-hosted |
| Predicate | `https://slsa.dev/provenance/v1` |

The source and signer digests must equal the manifest's full source commit.
Exactly one verified numeric repository ID must be returned.
Missing, multiple, or different IDs stop the update.
GitHub CLI uses its built-in trusted roots and root-refresh mechanism.
ASM never accepts a trusted root from the release.

The verifier receives a private home, configuration directory, and cache.
ASM does not forward GitHub tokens, host overrides, CA overrides, or general tool configuration.
Only the standard HTTP, HTTPS, ALL, and NO proxy variables are copied.
Each proxy entry is limited to 4096 bytes; duplicate names are rejected.
These settings change transport routing, not the required signer or trusted root.
Each verifier child has a 120-second deadline.
ASM resets the `SIGALRM` disposition and unblocks that signal before the verifier starts.
A failed signal setup stops the update before the verifier runs.

## Replacement and recovery

ASM opens the running executable through `/proc/self/exe`.
It checks that the destination is the same device and inode.
Before each verifier call, ASM checks every absolute path ancestor again.
It requires the absolute installation directory and executable to match the held descriptors.
An advisory directory lock coordinates concurrent ASM updates.
Another update fails promptly while that lock is held.

ASM stages the new file below the installation directory.
It finishes verification, applies the existing mode, and syncs the file before replacement.
It repeats the absolute path and identity checks immediately before replacement.
The final rename atomically replaces the directory entry.
Errors before this commit point preserve the existing executable.
The downloaded candidate is never executed during the update.

The lock does not constrain another program that runs as the same user.
The operation is not a sandbox against that account.
Atomic replacement also does not promise directory durability after power loss.

On a failed download or verification, correct the reported problem and retry the command.
If the installation changed during the operation, start the installed command again.
Do not remove an unrelated file to force an update.

## Limits of the result

An attestation binds bytes to the required release workflow.
It does not establish that the program is harmless.
The repository, reviewed workflow, GitHub identity service, verifier, and trusted roots remain trusted.

The index has no independently signed expiry or revocation record.
A stale index can hide a newer release.
The command does not claim TUF protection for ASM release metadata or an external security audit.
Unattended updates remain outside this protocol.

See the [GitHub verifier manual](https://cli.github.com/manual/gh_attestation_verify)
and Linux documentation for [rename](https://man7.org/linux/man-pages/man2/rename.2.html),
[flock](https://man7.org/linux/man-pages/man2/flock.2.html),
[signal masks](https://man7.org/linux/man-pages/man2/sigprocmask.2.html),
and [the running executable](https://man7.org/linux/man-pages/man5/proc_pid_exe.5.html).
