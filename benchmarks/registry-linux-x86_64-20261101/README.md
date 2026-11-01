# Registry measurements: Linux x86-64

Read the [experiment report](../../docs/performance-registry.md) before using these results.
It defines the workload, host, executable identities, method, regressions, and limits.

`paired-results.json` contains the first randomized comparison.
`small-results.json` contains the focused comparison with unchanged command controls and child CPU counters.
The source manifest, original harness, and system-call traces identify their inputs and checks.
The exploratory run is retained but excluded from the reported comparison.

## Public edition

The JSON reports remove local identifiers from the recorded environment.
Exact copies were preserved outside the public repository before this redaction.
Local absolute paths became logical labels under `artifacts/`, `fixtures/`, or `traces/exploratory/`.
These labels identify file roles; they do not mean that the files are bundled here.
The EINTR command uses the relative name of its included trace.
The exploratory hostname was already omitted before this edition.

All numeric samples, complete sample objects, CPU model, kernel and toolchain descriptions, recorded digests, system-call counts, failures, and regressions are retained.
All 11 trace files were inspected and contain no local identifiers; their bytes are unchanged.
The original benchmark harness and assembly source manifest are also unchanged.

[`public-redaction.json`](public-redaction.json) lists changed JSON fields, generic redaction types, and original/public file hashes.
It contains no removed identifiers.
Documentation and publication notes now describe this public edition.

`registry-comment-correction.json` records a later comment correction with identical object and executable bytes.
Its preserved-evidence hashes and equality flag describe the originals checked at that time.
Use `public-redaction.json` for the hashes of the current public copies.

These measurements cover local catalog commands on one x86-64 host.
They do not measure ARM64, network installation, or hosted service capacity.
