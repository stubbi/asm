# Assembly server image qualification

Status: build and qualification implementation, 5 November 2026.

This path builds the assembly runtime foundation for Linux AMD64, ARM64, and RISC-V64.
An entry in the build matrix is not a supported-target claim.
Each architecture must compile its actual port and pass the complete runtime suite.
The [completed prior-image checks](#completed-prior-image-checks) cover one recorded source revision.
Each later source revision requires its own completed qualification.

The operator outcome is an immutable image connected to its source, executable, target, and observed checks.
The governing principles are dependable reuse and trust earned through evidence.
An assembly image check does not qualify the separate MCP adapter or native CLI.

## Architecture and execution

| Image platform | Runner | Required execution |
| --- | --- | --- |
| `linux/amd64` | `ubuntu-24.04` | Native x86-64 |
| `linux/arm64` | `ubuntu-24.04-arm` | Native AArch64 |
| `linux/riscv64` | `ubuntu-24.04` with pinned QEMU user emulation | Emulated RISC-V64 |

RISC-V emulation uses the runner's Linux kernel.
It does not establish behavior on RISC-V hardware or another kernel.
The executable's ELF machine field must match its declared architecture.
The architecture-specific assembly ABI checks and runtime tests must also pass.
Image metadata alone cannot establish an instruction-set port.

Each executable report separates the declared ISA, operating system, ABI, and CPU profile.

| ISA | Operating system | ABI | Declared application CPU profile |
| --- | --- | --- | --- |
| `x86_64` | Linux | System V AMD64 LP64 | x86-64 baseline |
| `aarch64` | Linux | AAPCS64 LP64 | ARMv8-A |
| `riscv64` | Linux | RISC-V LP64D | RV64GC |

These are application declarations, not measured minimum requirements for Debian packages or every linked library.
ELF identity and flag checks do not audit every instruction or establish hardware compatibility.
The report retains that limit beside `binary.declared_target`.

For RISC-V, the floating-point ABI flag must identify double-precision LP64D: `(e_flags & 0x6) == 0x4`.
The compressed-instruction flag `0x1` is permitted.
All other flag bits are rejected for this declared profile.
This rejects soft, single, and quad floating-point ABIs, RVE, TSO, experimental pointer ABIs, and reserved or nonstandard flags.
The check does not prove that every instruction belongs to RV64GC.
The port's compiler flags, ABI assertions, library requirements, and executed tests remain separate evidence.

Assembly port implementation belongs to the coordinated server source workstream.
The image build invokes `make -C server all` on the target platform.
An unavailable port fails the build.
There is no successful fallback, skipped architecture, or alternate application backend.

The fixture and two-second database deadlines remain unchanged under emulation.
The complete runtime suite has the same 180-second outer watchdog for every architecture.
Dependency compilation has bounded jobs: 45 minutes natively and 90 minutes for the emulated job.
A slow or failed RISC-V result remains a failed result.
It must not be converted into a pass by weakening a runtime assertion.

## Image contents and trust boundary

`containers/server.Dockerfile` has separate build, runtime, and qualification stages.
The default final stage contains the runtime image.
Application behavior remains in assembly.
GNU libmicrohttpd handles HTTP framing, and libpq handles PostgreSQL protocol and TLS.

The runtime contains the executable, required shared libraries, license notices, and Debian runtime packages.
It uses UID/GID 65532 and starts `/usr/local/bin/asm-hub serve` directly.
Packaging sets the root-owned executable to mode `0555`, independent of the build's private umask.
The harness checks that mode and executes the exact runtime image as UID/GID 65532 before database tests.
Missing configuration must produce exit 78, rather than a permission or loader failure.
It includes no Python application backend, compiler, test fixture, or PostgreSQL server tools.
HTTP ingress TLS remains a separate deployment requirement.

The qualification stage extends the exact runtime filesystem with Python, OpenSSL tools, PostgreSQL tools, and the owned fixture.
The harness compares the runtime layer prefix and executable hashes.
It also compares hashes for every shared library reported by the runtime loader.
The added test layer cannot silently substitute a different executable dependency.

The container runs with a read-only root filesystem, no Linux capabilities, and no new privileges.
Its network has loopback only.
Its private temporary filesystem has a 256 MiB limit and forbids executable files.
The container also has 512 MiB memory, two CPUs, and a 128-process limit.
The harness observes UID, GID, effective capabilities, privilege state, and the root mount before tests start.

The existing runtime suite creates its own PostgreSQL cluster, CA, credentials, and records.
It accepts no existing database or production credential.
All current tests must execute, at least eleven tests must exist, and no test may skip.
The result identifies source, image ID, ELF target, executable digest, library digests, execution mode, and test count.
These are foundation checks, not a complete registry qualification.

## Completed prior-image checks

[Run 41947880132](https://github.com/stubbi/asm/actions/runs/41947880132) passed all 11 runtime cases for each architecture, without skips.
It tested PR merge revision `09a5a2fb63185fedb9dd9b58d26199a0ea1f884f`, containing source head `4fe2c25277ed40a163b48b727ab814225d227cf8`.

| Image platform | Execution | Executable SHA-256 |
| --- | --- | --- |
| [Linux AMD64](https://github.com/stubbi/asm/actions/runs/41947880132/job/126984484580) | Native | `ad1f6cff7a36a9171af6928b3667ba73cf24f6412cdd63f831ba35d06bc95b45` |
| [Linux ARM64](https://github.com/stubbi/asm/actions/runs/41947880132/job/126984485001) | Native | `456da6cd1ee4c0532e44b7e009cf712d79709ad7c2e591c5ae17219a64c58288` |
| [Linux RISC-V64](https://github.com/stubbi/asm/actions/runs/41947880132/job/126984484813) | QEMU user emulation | `03efff97e1f1f86255d50d142a3b695c8656fd36253db0303495a6605af0b218` |

These results do not qualify head `7d684055fc972fd511e450b77f6f0dda331cd06c` or later source changes.
Current-head qualification remains a separate gate.
Native instruction execution does not qualify a physical hardware range.
RISC-V emulation supplies no native RISC-V hardware or performance evidence.
Canonical HTTP integration, capacity, recovery, publication, and deployment remain separate gates.

## Verified inputs

The following registry metadata was observed on 5 November 2026 in Europe/Paris.
The observation time was `2026-11-04T23:43:57Z`.
Anonymous Docker Registry API responses supplied the manifests and image configurations.
Downloaded metadata hashes matched the index, child, and configuration descriptors.
No image layer or local virtual machine was used for that inspection.

| Input | Pinned digest or revision |
| --- | --- |
| Debian `trixie-20261027-slim` multi-architecture index | `sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4` |
| Debian AMD64 child | `sha256:1e1a22175fbf1b32157ddaf0219e1db4e5401fab2b94ed285add64d18587cd2d` |
| Debian ARM64/v8 child | `sha256:1470991b497d26788dc4d6f438bf5690c6ba0d499235d237e55f4b43caea7a75` |
| Debian RISC-V64 child | `sha256:d2603372b44ea7e55fcc4b2f5fd667024d6f298af5af7c7474f639321570c5cc` |
| Ubuntu Noble QEMU package version | `1:8.2.2+ds-0ubuntu1.18` |
| QEMU AMD64 `.deb` SHA-256 | `5bb397f66063efa349f6fd5cb3b68cd96f29edd0994e4ba5115cf0859a716bf0` |
| Installed `qemu-riscv64-static` SHA-256 | `be89e201dc6112ef101617ab575c95119ad123f80ca2b51b6c36ef218ac9df65` |
| GNU libmicrohttpd 1.0.3 source SHA-256 | `7816b57aae199cf5c3645e8770e1be5f0a4dfafbcb24b3772173dc4ee634126a` |
| PostgreSQL 16.15 source SHA-256 | `c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed` |

The source archives retain the existing reference build's checked pins.
The Docker build downloads them from GNU and PostgreSQL over HTTPS.
It checks their SHA-256 values before extraction.
PostgreSQL is configured with `--with-openssl`.
No dependency signature verification is claimed by those digest checks.

Debian package installation uses Debian's signed repositories at build time.
Those package versions are not fixed by the source archive pins.
The resulting image digest identifies their actual bytes.
This recipe does not claim byte-for-byte reproducible images across repository updates.

Primary sources:

- [Official Debian image definition](https://github.com/docker-library/official-images/blob/master/library/debian).
- [Docker Registry API](https://distribution.github.io/distribution/spec/api/).
- [Ubuntu Noble updates package metadata](https://archive.ubuntu.com/ubuntu/dists/noble-updates/universe/binary-amd64/Packages.xz).
- [Pinned Ubuntu QEMU package](https://archive.ubuntu.com/ubuntu/pool/universe/q/qemu/qemu-user-static_8.2.2+ds-0ubuntu1.18_amd64.deb).
- [Systemd registration implementation](https://github.com/systemd/systemd/blob/v255/src/binfmt/binfmt.c).
- [GNU source archive](https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.3.tar.gz).
- [PostgreSQL source checksum](https://ftp.postgresql.org/pub/source/v16.15/postgresql-16.15.tar.bz2.sha256).
- [RISC-V psABI, section 10.1](https://riscv-non-isa.github.io/riscv-elf-psabi-doc/#_file_header), version 2.0-rc0 dated 4 November 2026; checked 5 November 2026.

## Run and retain evidence

Use a healthy Linux Docker host with enough space for two source builds and PostgreSQL tools.
Use a native host for AMD64 or ARM64 qualification.
Install the pinned RISC-V binfmt registration before emulated builds.
The workflow checks its `F` flag, which permits execution across container filesystem boundaries.
The project workflow installs the checked Ubuntu package and registers only its RISC-V configuration through systemd.
It checks the package version, package digest, emulator digest, and interpreter path.
The runner's systemd version is recorded with the emulator version.
The repository permits only project-owned and GitHub-owned actions.
The initial external QEMU action failed that policy before any image job started; the policy remains unchanged.
It also records the pinned QEMU executable's actual version output.

Run the harness's small rejection checks without Docker:

```sh
python3 tools/test_server_image.py --self-test
```

Build both stages with the same source revision and target platform:

```sh
docker build --platform linux/amd64 --file containers/server.Dockerfile --target runtime --build-arg ASM_SOURCE_REVISION=FULL_COMMIT_ID --tag asm-server:runtime-amd64 .
docker build --platform linux/amd64 --file containers/server.Dockerfile --target qualification --build-arg ASM_SOURCE_REVISION=FULL_COMMIT_ID --tag asm-server:qualification-amd64 .
python3 tools/test_server_image.py --arch amd64 --execution native --revision FULL_COMMIT_ID --image asm-server:runtime-amd64 --qualification-image asm-server:qualification-amd64 --output qualification.json
```

Replace `FULL_COMMIT_ID` with the exact reviewed 40-character commit ID.
Use the matching platform, tags, and execution mode for another architecture.
The Docker context must include the server and its three retained experiment fixture inputs.
It must also include this harness and the root license.

The workflow retains build logs and runtime logs after successful or failed checks.
Successful jobs also retain the exact runtime image archive, its checksum, and qualification JSON.
Evidence retention is three days; release evidence needs durable retention before production use.

## Publication and limits

Pull requests and manual runs have read-only repository permissions and publish nothing.
After a main-branch push, publication waits for every architecture qualification job to pass.
The publication job loads the tested archive and compares its image ID with the qualification report.
It publishes an architecture-specific source-and-run tag and records the registry digest.
Each run attempt has a distinct tag, so a later dependency rebuild does not replace an earlier tag.
Deployment configuration must use the recorded digest.
It also creates build provenance for that exact digest.
The qualification image is never published.

The combined-index job waits for all three child publications and their provenance steps.
It reads each child back from the registry through its digest.
It compares its image configuration digest with the tested image ID.
It also checks the child's Linux architecture and source revision.
Only then does it create an index from those three exact child digests.
The resulting index must contain exactly those platforms and digests.
The job reads the index again through its immutable digest and records that result.
The combined index also receives provenance.

These images still contain the incomplete registry foundation.
Canonical exports, operator commands, service discovery, metrics, and recovery remain unqualified.
Passing these jobs cannot remove a deployment hold or establish a running registry.
No cluster, DNS, credential, release, or live service changes follow from this image workflow.
