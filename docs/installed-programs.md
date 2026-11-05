# Installed programs

Asm 0.5.0 adds installed-program inventory, upgrades, and uninstall on all three supported CLI hosts.
Published 0.4.0 binaries do not include them.

Asm records executable installations so people can inspect and maintain the programs they deliberately installed.
This follows the brand principles of dependable reuse, inspectable evidence, and keeping people in control.

## Commands

Install a program for the CLI host:

```sh
asm install owner/name@1.0.0
```

The default destination is `$HOME/.local/bin/name`.
Use `--output PATH` to select another destination.
Asm records both default and explicit destinations.
It records a relative output path as an absolute path.
The destination must be a new file.
Use an existing directory with no symlink or `..` path components.
The standard `$HOME/.local/bin/asm` destination is reserved for Asm's installer and self-update command.
Case variants of `asm` are also reserved in that directory.
The inventory directory and the command's download workspace cannot contain managed executables.
Installation checks the artifact size, SHA-256 digest, and host executable format.
It does not run the program.

List recorded installations:

```sh
asm installed
asm installed --json
```

The inventory describes recorded installations.
It does not establish that their current files still match the records.
Programs installed before this feature have no record and remain unmanaged.
Updating Asm does not adopt them.
Asm does not infer ownership from a file name.

Upgrade a recorded program:

```sh
asm upgrade owner/name
asm upgrade owner/name@1.1.0
```

Without an exact version, upgrade selects the highest available numeric version for the host.
Upgrade retains the recorded destination.
It refuses an older version or a different registry origin.
An equal version must retain its recorded digest and size.
If those values match, upgrade leaves the installation unchanged.
HTTPS installations reuse their recorded index URL unless an explicit matching origin is supplied.
For a local-index installation, supply `--index PATH` again.

Uninstall a recorded program:

```sh
asm uninstall owner/name
```

Uninstall removes the recorded executable and its inventory entry.
It does not remove the destination directory or other package data.
The commands `update` and `remove` continue to manage project source dependencies.
Use `self update` to update Asm itself.
Successful install, upgrade, and uninstall commands are quiet unless `--json` is supplied.

## Inventory contract

The inventory file is `$HOME/.local/state/asm/installed.tsv`.
Its first line is `# asm-installed-v1`.
Each remaining line has seven tab-separated fields:

| Field | Meaning |
| --- | --- |
| Package | The complete `owner/name` identity. |
| Version | The selected numeric release version. |
| Target | The CLI host target. |
| SHA-256 | The selected executable digest. |
| Bytes | The executable size in decimal bytes. |
| Path | The absolute executable destination. |
| Registry | The HTTPS index URL, or `local` for a local index. |

The format permits at most 128 records and 1 MiB of input.
One package identity has at most one managed installation.
Paths and registry origins cannot contain tabs, newlines, or other control characters.
Paths use valid UTF-8, with no empty, `.` or `..` components.

`installed --json` returns an `installed` array.
Each object contains `package`, `version`, `target`, `sha256`, `bytes`, `path`, and `registry`.
An empty inventory returns `{"installed":[]}`.

## File protection and recovery

Upgrade and uninstall check the installed file before mutation.
The file must retain its recorded size and digest.
It must remain a user-owned, single-link regular executable with protected permissions.
Asm refuses changed files, symlinks, malformed records, and unmanaged destinations.

If a file has changed, retain it for inspection.
Restore the exact recorded executable before retrying the management command.
Do not delete an inventory record to make Asm overwrite an unrelated file.

Installation checks filename aliases with the destination filesystem before committing a new executable.
A temporary, empty file at the new destination has mode `000`.
Asm removes this file before normal finalization.
Cleanup removes this file only when it still matches the owned probe.
Interruption or a cleanup failure can leave this file behind.
Preserve unfamiliar or modified files during manual recovery.

Private staging and an advisory inventory lock coordinate Asm operations.
Descriptor-relative file operations protect checked directory boundaries.
The lock does not constrain another process that runs under the same account.

An executable and its inventory record occupy separate filesystem entries.
Their updates are not one atomic filesystem transaction.
Ordinary commit failures restore the prior executable and retain the prior inventory.
A process interruption or power failure can leave staged files or a mismatched record.
Retain those files and inspect their bytes before recovery.
The commands must report mismatches instead of adopting or deleting changed files.
Automatic crash recovery is not provided.
Manual recovery must preserve the recorded executable bytes and inventory together.

Package checks establish integrity relative to the selected index.
They do not establish publisher identity, registry freshness, or that a program is harmless.
See the [security model](specs/security.md) for those boundaries.
