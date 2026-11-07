# Native target distribution

This document records feed compatibility and the 0.5.0 integration baseline from 5 November 2026.
The [README](../README.md#status) states current release support.
The [Intel source-port guide](intel-macos-port.md) records its later qualification and release limits.

People must receive a compatible artifact without losing access through an older client.
A catalog target does not declare a CLI host, a native runtime result, or a deployed server.

## Published 0.5.0 baseline

[Asm 0.5.0](https://github.com/stubbi/asm/releases/tag/v0.5.0) uses source commit `1f1530db38eb7326ba149addf3f0b45f2f3ac026`.
The [release workflow](https://github.com/stubbi/asm/actions/runs/41935096978) qualified the three current CLI hosts.
Its manifest records repeatable builds and exact asset digests.
Independent postpublication checks covered all 14 assets and 13 provenance subjects.
The separate package integrity policy does not inherit Asm's release-provenance result.

| CLI target | Source | Assembly/build result | Runtime result | Released | Installer/catalog |
| --- | --- | --- | --- | --- | --- |
| `x86_64-linux` | Exact 0.5.0 commit above | Two identical clean builds | Native Linux CI passed | 0.5.0 | Published |
| `aarch64-linux` | Exact 0.5.0 commit above | Two identical clean builds | Native Linux CI passed; final cross-built version checked under QEMU | 0.5.0 | Published |
| `aarch64-macos` | Exact 0.5.0 commit above | Two identical clean native builds | Native macOS CI and public installation/lifecycle passed | 0.5.0 | Published |
| `riscv64-linux` | Port not integrated | Not qualified here | Not qualified here | None | None |
| `x86_64-macos` | Port not integrated | Not qualified here | Not qualified here | None | None |
| `x86_64-windows` | External draft; not integrated | Draft PE container check passed | Not run here | None | None |
| `aarch64-windows` | External draft; not integrated | Draft PE container check passed | Not run here | None | None |

The table records source status at the 0.5.0 baseline, before later port integration.
Assembly, emulation, native execution, release publication, and deployment establish separate results.

| Published CLI artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `asm-0.5.0-x86_64-linux` | 117824 | `66a732e25f190b1a03b3177a32f25eb52316712bae9101ed64f8f291da6ef5cf` |
| `asm-0.5.0-aarch64-linux` | 152680 | `5a86a567beb390e891842be4b6bbd31ce23c990e932bc5b03c4913868aae7dba` |
| `asm-0.5.0-aarch64-macos` | 273248 | `ec02655548108f59df9656687482483817a516ca3fd1ee25167f9d47c210e776` |

The [release notes](releases/0.5.0.md) declare ISA, operating system, ABI, and CPU requirements separately.
Linux CI uses Ubuntu 24.04; a separate minimum kernel version remains unqualified.
Apple Silicon support requires macOS 15 or later.
The README identifies the latest release and its supported hosts.
Later host additions require a new version after independent qualification.

## Feed compatibility

Released clients reject a complete TSV index when it contains an unfamiliar target.
The existing feed vocabularies must remain fixed:

- `index.tsv`: `x86_64-linux`, `aarch64-linux`, and `riscv64-linux`.
- `index-macos.tsv`: those Linux targets and `aarch64-macos`.

The expanded feed is `index-all.tsv`.
It retains the v1 header, row syntax, 1 MiB limit, and 4,096-row limit.
Its current records still use only qualified, validated artifact targets.
New ports must recognize the expanded vocabulary before selecting this route.
A recognized catalog label does not permit native execution on another host.

The JSON catalog continues to describe all accepted release records.
Native host declarations, installer eligibility, and format checks remain separate boundaries.
The bundled trust profile remains disabled.
New authenticated-feed routing requires the verifier and publication allowlists to change together.

## Draft Windows inputs

The validator checked two uncommitted external draft artifacts on 5 November 2026.
These results cover PE headers, sections, and directory bounds only.
Neither artifact has a release-source binding or native runtime qualification in this integration branch.

| Draft input | Bytes | SHA-256 | Runtime |
| --- | ---: | --- | --- |
| x86-64 PE image | 88064 | `73181a8b597c1e0dec0b366e9a3e8122ca9119dcf5f58e80389bc65c1c0fa7c2` | Not run |
| ARM64 PE image | 116736 | `bbbc0d34556009aeff7c00bd2398c1b2d24b57fe8af682f9875ebc1dbde71b48` | Not run |

The POSIX installer filters catalog executables through its separate existing three-host profile.
Windows catalog artifacts cannot add an unsupported shell installation route.
The current installer bytes remain unchanged for the published records.

## Qualification before expansion

Each imported port needs a coherent source revision and artifact digest.
Its target contract must declare ISA, OS, ABI, minimum runtime, and required CPU features.
Native installation, first-project output, package lifecycle, update recovery, and hostile-input checks must pass.
Windows also requires native permission, reparse-point, and running-image replacement checks.
Cross-assembly alone cannot qualify these boundaries.

Keep existing release records and published assets unchanged.
Add qualified artifacts under a new version after the required gates pass.
The [historical implementation record](https://github.com/stubbi/asm/blob/d5ab7d954f752018e4496171c5885397bc25339b/docs/superpowers/plans/2026-11-05-target-distribution.md) retains intermediate checks and rejected attempts.
