# Local registry performance

ASM validates the complete local catalog before it returns a search result.
The previous implementation compared each artifact identity with every preceding record.
It also wrote each output field, separator, and JSON key with a separate system call.

This experiment replaces those two costs in the native Linux x86-64 CLI.
At 4,096 records, median local search latency decreased by approximately 19–21 times on the measured host.
Small-catalog wall-time results were inconclusive, and some tail latencies increased.
The full results, including those increases, are linked below.

These measurements apply to local catalog commands.
They do not measure network installation, signature verification, service capacity, or another architecture.

## Implementation and contract

Identity validation now sorts a separate array of record pointers with heap sort.
It then compares adjacent identities exactly.
The identity remains the package, version, target, and artifact kind.
A different digest or URL cannot hide a duplicate identity.

Heap sort has bounded O(n log n) work for every input order.
It uses no recursion or hash table.
The pointer array requires 32 KiB at the current 4,096-record limit.
The original records remain in their input order.

Registry listing now uses a 64 KiB output buffer.
It flushes the buffer when full and before the command finishes.
The existing write routine handles interrupted calls and short writes.
A returned output-write error causes registry cleanup and a nonzero exit status.
With the default SIGPIPE disposition, a closed pipe can terminate the process before the write returns.
That signal path does not run registry cleanup.

The catalog size limit, record limit, field validation, URL rules, and artifact verification remain in place.
No result is emitted before the complete catalog passes validation.

## Public evidence

The linked reports are public copies with local identifiers removed.
Exact copies were preserved outside the public repository before this redaction.
Local executable paths use `artifacts/` labels, fixture paths use `fixtures/` labels, and exploratory trace paths use `traces/exploratory/` labels.
These labels identify the roles of files in the experiment; they do not mean that those files are bundled here.
The EINTR command now names its included trace with a relative path.
The exploratory hostname was already omitted before this edition.

All numeric samples, complete sample objects, CPU model, kernel and toolchain descriptions, recorded digests, system-call counts, failures, and regressions are retained.
All 11 trace files were inspected and required no redaction.
The original benchmark harness and assembly source manifest also remain byte for byte unchanged.
The [redaction manifest](../benchmarks/registry-linux-x86_64-20261101/public-redaction.json) identifies each changed JSON field and gives original and public file hashes.
It contains no removed local identifiers.

## Exact inputs

The baseline source is commit `eea8498f6d49c26c7112f6510f12528861886e87`.
Its Git tree is `4b8d3e5afbfa45fb8c129290360d7529c8b6144b`.
The comparison changes only `cli/registry.s` within that source snapshot.
It keeps version text and other CLI modules identical to isolate the registry change.

| Item | Baseline | Candidate |
| --- | --- | --- |
| Executable size | 96,880 bytes | 97,448 bytes |
| Executable SHA-256 | `a6352e9289e8869c5fce6bc01e5a54a45b13172a3f0e3c10af16214ad6af65bf` | `35ebf937e811791769a83b972e2e8ad891dd589feaf0b360c2fdbf5f0b839521` |
| Source-manifest SHA-256 | `cd6810051a7f12ba5dcc8dbc8f9b23a0484d140f3bc5adb05e662c60c1816109` | `8fed51a66ccc0e0a606c395024f0bbdc2f28cca4fd71d8367b80fedd5fb12782` |

The registry source used for the measurements has SHA-256 `e9de264490fe5d1558d541ab71fb76e09e72020d17237812464b10bb3dbeccbb`.
The [source manifest](../benchmarks/registry-linux-x86_64-20261101/source-manifest.json) records every assembly file, size, and digest.
These are experiment identities, not a relabeling of an existing release.

After measurement, the output-helper comment was corrected to limit its cleanup guarantee to a returned write error.
The corrected x86-64 registry source has SHA-256 `4fe271d95054828da7d1066edb141adfe22a8602fdcba69bd23bde763ad88225`.
Rebuilt within the original v0.2 source snapshot, its object and executable match the measured candidate byte for byte.
The [comment-correction record](../benchmarks/registry-linux-x86_64-20261101/registry-comment-correction.json) contains the source hashes, build commands, and equality checks.
No runtime code changed, and no new timing samples were collected.
The source manifest remains unchanged.
Hashes in the comment-correction record identify the original evidence checked at that time.
For the current public copies, use the hashes in the redaction manifest.

## Method

The experiment ran on 1 November 2026.
The host reported an Intel Xeon Platinum 8573C and Linux 6.18.57, with x86-64 execution.
Both executables used GNU binutils 2.42, Ubuntu package revision `2.42-4ubuntu2.10`.
The rebuilt baseline matched the existing release bytes exactly.

The harness pinned itself and its child processes to available CPU 0.
Other project workers paused builds and tests during each timing window.
This does not provide exclusive control over the physical host.

Each fixture contains 6, 256, or 4,096 valid records.
The fixture includes quoted strings and backslashes.
Every invocation must return the exact expected bytes, an empty standard-error stream, and a zero exit status.
The report records fixture and output digests.

Each round shuffles the workloads and selects the order of the two executables within each pair.
The fixed random seed is `918261`.
The first comparison uses 31 pairs per workload after three warmups per executable.

Elapsed time starts before process creation and ends after output collection.
It therefore includes process startup and pipe handling.
The filesystem cache is warm.
No network request is made.

System-call counts were collected separately after the timing samples.
Tracing overhead is excluded from the latency measurements.

## First comparison

The table gives median elapsed time in milliseconds.
A ratio below 1 indicates a slower candidate in that run.
The [public report](../benchmarks/registry-linux-x86_64-20261101/paired-results.json) includes every sample, minimum, maximum, and nearest-rank 95th percentile.

| Records | Output | Baseline | Candidate | Baseline / candidate |
| ---: | --- | ---: | ---: | ---: |
| 6 | Text | 0.450 | 0.551 | 0.82 |
| 6 | JSON | 0.505 | 1.319 | 0.38 |
| 6 | No match | 0.624 | 0.576 | 1.08 |
| 256 | Text | 2.448 | 1.707 | 1.43 |
| 256 | JSON | 4.805 | 1.939 | 2.48 |
| 256 | No match | 1.394 | 1.547 | 0.90 |
| 4,096 | Text | 168.496 | 8.844 | 19.05 |
| 4,096 | JSON | 213.789 | 10.049 | 21.28 |
| 4,096 | No match | 130.240 | 6.857 | 18.99 |

The no-match workload still validates the complete catalog.
Its improvement shows that the result does not depend only on output buffering.

| Workload | Previous write calls | Buffered write calls |
| --- | ---: | ---: |
| 6 records, text | 96 | 1 |
| 6 records, JSON | 157 | 1 |
| 4,096 records, text | 65,536 | 13 |
| 4,096 records, JSON | 106,497 | 19 |
| 4,096 records, no match | 1 | 1 |

## Small-catalog follow-up

The first comparison showed possible regressions for small catalogs.
Their sample ranges also overlapped widely.
One focused follow-up used 151 balanced pairs after five warmups.
It added unchanged `version` and `help` controls, plus child CPU and scheduling counters.

| Workload | Baseline median, ms | Candidate median, ms | Baseline child CPU, ms | Candidate child CPU, ms |
| --- | ---: | ---: | ---: | ---: |
| 6 records, text | 0.324 | 0.339 | 0.140 | 0.120 |
| 6 records, JSON | 0.366 | 0.342 | 0.157 | 0.121 |
| 6 records, no match | 0.333 | 0.344 | 0.118 | 0.117 |
| 256 records, no match | 1.178 | 0.854 | 0.760 | 0.401 |
| `version` control | 0.269 | 0.290 | 0.091 | 0.095 |
| `help` control | 0.287 | 0.304 | 0.095 | 0.090 |

The earlier six-record JSON slowdown did not recur in this follow-up.
However, candidate tail latency remained worse in some cases.
For six-record JSON output, the 95th percentile changed from 0.869 ms to 1.617 ms.
The unchanged controls also varied.

These observations do not establish a consistent small-catalog wall-time improvement.
The CPU counters and system-call counts support reduced work for output-heavy commands.
A further small-catalog optimization needs clearer evidence.
The [focused report](../benchmarks/registry-linux-x86_64-20261101/small-results.json) preserves all 1,812 timed observations and their counters.

## Correctness and failed attempts

The 17 existing registry CLI tests passed after both changes.
Eight additional contract tests cover:

- Empty, one-record, two-record, and maximum-size catalogs.
- Sorted, reversed, and shuffled inputs with unchanged output order.
- Each identity field and conflicting non-identity metadata.
- Independent set-oracle checks for mixed identity permutations.
- Exact JSON output at 65,535, 65,536, and 65,537 bytes.
- Closed output and a real partial write followed by a file-size-limit failure.

A separate test injected `EINTR` before the first output write.
The retry produced the complete expected 1,199,420-byte JSON result.
The [result](../benchmarks/registry-linux-x86_64-20261101/eintr-result.json) and trace preserve that check.

The first environment setup could not read `/proc/cpuinfo` in the restricted filesystem.
A separate build-metadata attempt could not read the system package database there.
Both failed before performance measurements or source compilation began.
The recorded experiment used the system environment with those read paths available.

An [exploratory baseline](../benchmarks/registry-linux-x86_64-20261101/exploratory-baseline.json) overlapped possible tool provisioning and was excluded from the comparison.
Its samples are retained; the public record omits the hostname and replaces local paths as described above.
The two comparison reports retain all measured regressions and outliers.

## Reproduce the comparison

Run this experiment on Linux x86-64 with GNU binutils and Python 3.
Use an unused directory for each result.
The harness refuses to overwrite existing evidence.

Create two copies of the baseline source:

```sh
git worktree add --detach ../asm-benchmark-before eea8498f6d49c26c7112f6510f12528861886e87
git worktree add --detach ../asm-benchmark-after eea8498f6d49c26c7112f6510f12528861886e87
cp cli/registry.s ../asm-benchmark-after/cli/registry.s
make -C ../asm-benchmark-before
make -C ../asm-benchmark-after
```

Record the candidate registry digest:

```sh
sha256sum ../asm-benchmark-after/cli/registry.s
```

Run the comparison with that digest as the candidate source label:

```sh
python3 tools/benchmark_registry.py \
  --baseline ../asm-benchmark-before/build/asm \
  --candidate ../asm-benchmark-after/build/asm \
  --baseline-source eea8498f6d49c26c7112f6510f12528861886e87 \
  --candidate-source "eea8498 plus registry $(sha256sum ../asm-benchmark-after/cli/registry.s)" \
  --output ../asm-registry-results \
  --samples 31 --warmups 3 --strace
```

The `--strace` option requires `strace` and permission to trace these child processes.
Omit that option to collect elapsed time without system-call counts.
Use `--small-only --samples 151 --warmups 5` and a different output directory for the focused comparison.
That mode requires identical `version` and `help` output from both executables.

The [original comparison harness](../benchmarks/registry-linux-x86_64-20261101/paired-benchmark.py) is preserved beside its report.
The current harness adds the focused controls and child CPU counters.
Each report records the digest of the harness that produced it.

## Remaining scope

The `versions` command still scans preceding records to suppress repeated versions.
Build commands still invoke the system assembler and linker.
Network commands still depend on transport and provenance-verification tools.
Those paths need their own workloads before they justify further changes.

No experiment can establish the fastest implementation for every CPU, input, operating system, and future workload.
This evidence establishes two specific improvements and records their current limits.
