# Evidence from assembly software

Asm needs performance claims that a reader can inspect.
This page records one published experiment and its limits.
The [six working assumptions](why-asm.md) remain the project's motivation.
This experiment does not establish all six assumptions.

## asmwc: an assembly implementation of ripwc

[asmwc][project] implements the behavior of the Rust word counter ripwc in handwritten assembly.
Its application logic includes argument parsing, file traversal, counting, aggregation, and output formatting.
System libraries provide allocation, input, output, and scheduling.

**Status: published experiment; measurements not reproduced by the Asm build.**
The records describe an experiment from 31 October 2026.
The source publication reviewed here is commit `13ddc7effea46f3f2aad3f5b69635817e6fd6541`.
That commit identifies the published records, not a new benchmark run.

The experiment predates the project's rename from `ripwc-asm` to `asmwc`.
The records retain their original program names.
The [build record][build] identifies the measured assembly source files and executables by SHA-256 digests.
The Rust reference uses unchanged upstream source at commit [`de1a12e8e2d7c031404370773e5099b23ef01e95`][upstream].

## Environment and method

The [benchmark report][report] documents the following conditions.

| Item | Recorded value |
| --- | --- |
| Host | Apple M3; eight cores; 16 GiB memory |
| Operating system | macOS 15.6.1 |
| Rust compiler | Rust 1.97.1; LLVM 22.1.6 |
| Rust optimization | Native CPU; level 3; fat link-time optimization; one code-generation unit; aborting panics |
| Assembly compiler | Apple clang 17.0.0; `-arch arm64 -mcpu=apple-m3 -O3 -g` |
| Large inputs | Separate deterministic text and binary files; 128 MiB each |
| Implementations | Native Rust; first assembly version; optimized assembly version |
| Warmups | Two rounds after output comparison |
| Samples | 24 measured invocations per implementation and workload |
| Execution order | Six possible orders; four rounds per order; shuffle with a fixed seed |
| Summary | Median elapsed time; speedup is a ratio of medians |

The measured interval covers process startup, traversal, reading, counting, output capture, and shutdown.
The file cache is warm from the preliminary checks and warmups.
The experiment does not measure cold storage.

Each workload first passes a comparison of standard output, standard error, and exit status.
Each measured invocation also records output digests and its exit status.
The [raw samples][samples] preserve execution order and elapsed time.

## Selected results

The following four workloads use the 128 MiB files.
Default counting reports lines, words, and bytes.
All-field counting also reports characters and maximum line length under ripwc's documented counting rules.

| Workload | Native Rust | First assembly | Optimized assembly | Rust / optimized assembly |
| --- | ---: | ---: | ---: | ---: |
| Text, default | 68.468 ms | 17.903 ms | 15.234 ms | 4.49× |
| Binary, default | 60.061 ms | 16.535 ms | 12.906 ms | 4.65× |
| Text, all fields | 122.720 ms | 22.353 ms | 13.307 ms | 9.22× |
| Binary, all fields | 123.094 ms | 23.267 ms | 13.470 ms | 9.14× |

The [complete results][results] include 18 workloads, including startup, metadata, and directory cases.
They retain unchanged and slower results.
For binary character counting, optimized assembly had a median time 6.7% higher than the first assembly version.
Its paired 95% speedup interval was 0.900–1.006×, which includes equal performance.
These intervals compare the two assembly versions.

## What the result establishes

The recorded assembly executable completed these four workloads faster than the recorded, natively optimized Rust executable on this host.
The comparison includes differences in algorithms, scheduling, and startup.
For eligible large files, the macOS assembly implementation overlaps reading and scanning.
The Rust reference initializes a Rayon thread pool on each invocation.
Instruction selection alone does not explain the measured difference.

These measurements apply to the recorded macOS implementation and host.
The Linux ports use different input and scheduling paths.
The publication contains no Linux performance measurements.
The figures do not establish a general performance ranking between languages.

Passing differential tests covers the tested inputs and failure cases.
It does not prove equivalence for every input or operating-system failure.
This experiment also does not measure development effort, maintenance cost, energy use, or proof performance.

## Record checks

On 1 November 2026, we checked three published files against the [publication manifest][publication]:

- `build-info.json`
- `benchmark.csv`
- `benchmark-samples.csv`

All three SHA-256 digests matched.
We recomputed the four selected medians and speedup ratios from the raw samples.
Each selected implementation had 24 samples per workload.
The results matched the published values before rounding.

These checks establish consistency within the published records.
They do not reproduce the experiment or authenticate the benchmark host.
The publication retains compiler settings, corpus digests, source digests, executable digests, and raw measurements.
It does not claim that rebuilt executables have identical bytes.

## What this means for Asm

A useful package record must connect an artifact to its target, source, build, and applicable evidence.
Separate target artifacts prevent a result for one platform from becoming a claim about every platform.
Performance records need the measured workload, comparison implementation, raw samples, and known limits.
They also need slower and inconclusive results.

This experiment supports those design requirements.
It is not a benchmark of the `asm` CLI or a performance certificate for an Asm package.

[project]: https://github.com/stubbi/asmwc/tree/13ddc7effea46f3f2aad3f5b69635817e6fd6541
[upstream]: https://github.com/LuminousToaster/ripwc/tree/de1a12e8e2d7c031404370773e5099b23ef01e95
[report]: https://github.com/stubbi/asmwc/blob/13ddc7effea46f3f2aad3f5b69635817e6fd6541/docs/BENCHMARKS.md
[build]: https://github.com/stubbi/asmwc/blob/13ddc7effea46f3f2aad3f5b69635817e6fd6541/benchmarks/results/apple-m3-2026-10-31/build-info.json
[results]: https://github.com/stubbi/asmwc/blob/13ddc7effea46f3f2aad3f5b69635817e6fd6541/benchmarks/results/apple-m3-2026-10-31/benchmark.csv
[samples]: https://github.com/stubbi/asmwc/blob/13ddc7effea46f3f2aad3f5b69635817e6fd6541/benchmarks/results/apple-m3-2026-10-31/benchmark-samples.csv
[publication]: https://github.com/stubbi/asmwc/blob/13ddc7effea46f3f2aad3f5b69635817e6fd6541/benchmarks/results/apple-m3-2026-10-31/PUBLICATION.json
