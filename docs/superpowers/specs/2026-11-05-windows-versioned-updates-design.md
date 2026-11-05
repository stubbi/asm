# Proposed Windows versioned installation

Status: proposed design. User approval and implementation are pending.

## Intent and evidence

The user wants the CLI and server to work across the selected major architectures.
Windows x64 and ARM64 currently pass 45 of 46 native runtime methods.
The remaining failure is successful self-update replacement.
The 125-second ordinary-application case passes on both targets.

[Native run 42042014143](https://github.com/stubbi/asm/actions/runs/42042014143) tested source `e147917ef5906ba92c8ab0715286bb7c25e0e409`.
On both hosts, replacement failed with `STATUS_ACCESS_DENIED` while the original process remained alive.
Unmapping its primary image succeeded but did not permit replacement.
The identical rename succeeded after the process exited.
Every diagnostic child was an owned, never-resumed copy and was reaped.
These observations cover the recorded Windows configurations, not all Windows releases.

The [existing update contract](../../self-update.md#replacement-and-recovery) requires one final atomic rename and preserves the existing executable before that commit.
A backup, publication, and rollback sequence cannot give that same guarantee.
Rollback is another fallible filesystem mutation.

The proposed layout preserves atomic activation while changing what the final rename selects.
The governing principles are dependable reuse, evidence, and keeping people in control.

## User outcome

Keep `asm new`, `build`, `run`, `test`, package commands, and `asm self update` as the normal interfaces.
After a successful update, the next `asm` invocation uses the verified new CLI payload.
Existing invocations continue using their old payload.
An error before activation preserves the selected version and its bytes.
The update does not execute the downloaded candidate.

Adapt the existing Python bootstrap front end for Windows verification, private staging, and layout publication.
Installation and updating must never execute the candidate, including after verification.
There is no new candidate-executed installation command.
Reuse the existing explicit source-install boundary for a deliberately source-built artifact.
Python remains an installer prerequisite, not a CLI runtime or package backend.
Use the existing fixed GitHub verifier and its required identity and source bindings.
The native installed CLI requires no Python or shell backend.
Refuse an existing unrelated command unless the user supplies an explicit replacement option.
Source builds outside the managed installation continue to execute their own checkout bytes.

## Proposed layout

Use the existing checked Windows HOME value, with the existing USERPROFILE fallback.

```text
HOME/.local/bin/asm.exe
HOME/.local/bin/.asm-cli/current.tsv
HOME/.local/bin/.asm-cli/versions/<sha256>/asm.exe
```

The root `asm.exe` acts as an assembly launcher in this managed layout.
The versioned `asm.exe` contains the native CLI implementation.
Both roles can initially use the same built PE artifact, installed as separate single-link copies.
The launcher delegates ordinary commands to the selected payload and propagates its actual exit code and streams.
It must not impose a tool deadline on a deliberately invoked CLI payload.

The launcher remains installed during ordinary payload updates.
Updating the launcher requires running the bootstrap installer after other Asm processes exit.
This bootstrap lifecycle is a material limit, not automatic full-binary replacement.

Commit to launcher protocol version 1 for compatible payload updates.
Put the required launcher protocol and minimum launcher version in a unique, bounded, read-only PE metadata section.
The exact artifact provenance covers those bytes; copy validated requirements into the selection record.
Do not change legacy release manifests or make existing POSIX readers accept new fields.
Reject an incompatible candidate before activation, with a useful installer instruction.
A payload must not infer compatibility from its PE machine alone.
An installer must also check that a replacement launcher can start the existing selected payload before repairing it.

Keep old payloads for active processes and recovery.
Do not add automatic version cleanup in this change.
Document their disk use and the safe manual removal procedure.
Do not enumerate or delete unrelated files.

## Selection record

Define a new canonical, bounded selection record with an explicit schema version.
Store one canonical version, exact target, decimal byte size, and lowercase SHA-256 digest.
Reuse the existing version, target, digest, and size validators and their bounds.
Reject duplicate or additional fields, truncation, NUL bytes, and ambiguous encodings.
The digest selects a fixed derived path; the record cannot supply an executable path or arguments.

The builder may choose the exact record encoding and routine boundaries.
The specification must fix those details before implementation.
Record limits and failure values must remain explicit in the assembly contracts.
Keep the layout marker, bootstrap version, and required protocol in that canonical bounded format.

## Installation and launch

For a published installation, bind the source descriptor to the verified artifact digest, target, and provenance result.
For explicit source installation, retain the source-build boundary without claiming publisher authentication.
Validate target, size, file type, ownership, link count, and parent identities.
Create protected private state and an initial versioned payload before publishing the root command.
Use exclusive private staging, exact copied-byte checks, file flushing, and no-replace publication.
Preserve existing files after every failed setup operation.
Refuse an unfamiliar existing `.asm-cli` directory instead of adopting or deleting it.

On a managed launch, read one complete selection snapshot through a checked descriptor.
Bind the launcher's held descriptor to its executing image before dispatch.
A displaced launcher must fail before starting a payload.
Open the derived payload without following reparse points.
Check its exact digest, size, PE target, single-link identity, owner, and access rules.
Create the child suspended and bind its creation image to the same held payload handle before resuming it.
An invalid record or substituted payload must fail with a useful recovery step.
Do not fall back silently to an older embedded version after managed-state corruption.

The installer must establish an unambiguous managed-layout marker and initial record together before root publication.
The fixed managed command path requires valid managed state, including its marker.
A downloaded or source-built executable outside that path remains standalone.
Missing or invalid managed state must produce an error, not an older-version fallback.
An explicit launcher repair preserves the existing active payload record.
Package installation and inventory operations must reject destinations inside the managed CLI store, including aliases.

Determine the managed role from the actual executing image and checked installation path, not HOME alone.
Changing HOME must not turn an installed launcher into a standalone older CLI.
An environment/path disagreement fails with a clear recovery step.
Reserve the fixed `.local/bin/asm.exe` role even when HOME disagrees; require its valid managed state.
Direct invocation of an inactive retained payload may inspect that version but must not update the active installation.

Use a dedicated launcher wait path that preserves the payload's complete Windows exit status.
Do not reuse the general x64 wait normalization for statuses above 255.
Keep the normal console process group and inherited streams.
The launcher handles its own Ctrl+C and Ctrl+Break notifications while waiting for the payload's resulting status.
Do not set an inheritable global ignore state that suppresses the payload's normal control events.
Add native owned-console control-event tests before claiming transparent cancellation.
Do not silently add a job policy that kills deliberately detached application descendants.
Use a separate suspended-child image-binding adapter; the current self-only mapping helper cannot verify a different process.

## Payload update

Acquire the existing installation lock and validate the launcher, active selection, current payload, and held ancestors.
Require the running payload to match the selected identity.
Preserve existing downgrade refusal, fixed tools, private verifier environment, provenance checks, and deadlines.
Retain all three exact manifest and candidate provenance bindings.

Stage and verify the candidate below the protected CLI store.
Publish it at the digest-derived version path without replacing existing different bytes.
If that digest path already exists, require the complete expected artifact and access contract before reuse.
Finish candidate protection and flushing before creating the next selection record.

Repeat active selection and path identity checks immediately before activation.
Flush the new record, then atomically rename it over `current.tsv` within the same checked directory.
That rename is the sole activation commit point.
Before it, all invocations still select the old payload.
After it, new invocations select the new payload.
Postcommit cleanup errors must not turn a completed update into a claimed failure.

The descriptor snapshot is the launch selection point.
A launcher that opened the old record before activation may start that old payload after commit.
A new invocation whose record open follows commit must select the new payload.
Test this ordering with held-old-record and newly-opened-record cases on both native hosts.

The existing same-user adversary and power-loss durability limits remain explicit.
The design does not add a claim of general filesystem race freedom or transactional directory durability.

## Acceptance and regression evidence

Retain every prior failed Windows result and the current native kernel counterexamples.
Retain all existing runtime behaviors and the long-running application check.
Replace the unsupported direct-file update assertion with stronger managed-layout activation checks, not a skipped update case.

Require actual installed-path `doctor`, `new`, `run`, and `test` flows on both native Windows ISAs.
Require successful update, next-command version and behavior, exact selected payload digest, and unchanged launcher bytes.
Exercise download, provenance, write, flush, activation, state corruption, concurrent update, and destination-substitution failures.
Before commit, assert the exact old selection bytes and usable old command remain.
After commit, assert the exact new selection and usable new command.
Test missing records, hard links, reparse points, unsafe access rules, reserved paths, and writes into the CLI store.
Test explicit replacement and preservation of an unrelated installed command.

No native support claim follows until those gates pass with exact source and artifact bindings.
Keep temporary-import cross-builds, API shims, native execution, and release admission separate.

## Scope and trade-offs

This proposal changes Windows installation and update layout only.
Linux and macOS retain their qualified direct replacement protocol.
Published 0.6.0 bytes, host admission, trust roots, and deployed services remain unchanged.
New released Windows hosts require a new version and separate installer and release qualification.

The trade-offs are an extra process for managed invocation, retained payload files, and separate launcher maintenance.
Measure the invocation cost before making a performance claim.
The alternative is explicit manual Windows updates with a documented feature limit.
That alternative does not meet full self-update parity.
