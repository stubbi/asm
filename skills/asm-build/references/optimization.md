# Bounded optimization and evidence

Optimize the person's completed task, with correctness and security as constraints.
An assembly implementation must earn its place against credible alternatives.

## Establish a comparison

1. Define the workload, input distribution, input digests, outputs, and acceptance cases.
2. Establish a correct assembly baseline before changing it for speed.
3. Select a credible compiler or existing-library baseline when applicable.
4. Use optimized release settings appropriate to the same target and allowed CPU features.
5. Record compiler, assembler, linker, libraries, flags, and source revisions.
6. Verify equal work and matching expected output digests before comparing measurements.

Avoid debug builds, deliberately weak compiler options, unequal algorithms, or extra baseline work that distorts the comparison.
When algorithms differ, explain their inputs, outputs, and work in the evidence.
When exact bytes cannot match, define the trusted semantic-equivalence check before measuring.
Do not use `asm_compare_candidates` for an output-digest comparison that cannot establish the required equivalence.
Report unavailable baselines instead of inventing results.

## Set the budget and protocol

1. Choose the primary user objective and hard resource limits.
2. Set time, candidate-count, or compute budgets appropriate to the task.
3. Define a plateau threshold and stopping rule before the search.
4. Record hardware, CPU features, OS, toolchains, environment, and measurement tools.
5. Define warmups, run order, sample count, and summary method before measurements.
6. Separate cold and warm caches when they affect the result.
7. Measure elapsed time, peak memory, and executable byte size independently.
8. Retain raw samples with units, spread, and the measurement overhead that matters.

Peak resident memory measures resident pages, not every memory cost.
State the measurement method and scope.
Tiny tasks can be dominated by launch overhead or measurement resolution.
Increase equal work or report the measurement limit when needed.
Emulator timings do not establish physical-target performance.
Energy and total-cost claims require their own measurements.

## Search without weakening checks

1. Profile the baseline to identify a relevant bottleneck.
2. Change a bounded implementation choice or algorithm justified by that bottleneck.
3. Run correctness and failure checks before accepting each candidate.
4. Measure candidates under the same declared protocol.
5. Retain failed checks, discarded candidates, and regressions with their artifact digests.
6. Stop at the budget, a declared plateau, or an unresolved correctness problem.

A faster candidate with failed tests is not a winner.
Missing checks are not passing checks.
Do not remove security checks or narrow acceptance cases to obtain a performance result.
An agent's review cannot establish measurement validity.

## Compare multiple objectives

Keep the Pareto frontier: candidates that no other comparable candidate improves in every measured objective.
For minimization, a candidate dominates another when it is no worse in every objective and better in at least one.
Apply hard limits before selecting a preferred candidate.
Use uncertainty when interpreting small differences or noisy measurements.
If speed, memory, and size conflict, show the trade-off against the user's priorities.
Do not silently collapse these metrics into a single score.

`asm_compare_candidates` checks supplied records; it does not run or authenticate the experiment.
Use it only after inspecting its schema and providing complete, comparable evidence.
Retain the underlying raw samples even when the adapter returns a summary.

## Report the bounded result

1. Name the workload, baselines, hardware, toolchain, source commits, and final artifact SHA-256 digests.
2. Give sample count, run order, warmups, raw-data location, summary method, spread, and regressions.
3. State the search budget, stopping reason, and alternatives evaluated.
4. Identify the best measured candidate or unresolved trade-offs within that scope.
5. State missing native measurements and other evidence limits.

Do not generalize one routine, workload, CPU, or emulator result to a complete application or another target.
Include development, verification, and maintenance effort when claiming lower total cost.
A finite search cannot establish an optimal implementation for all inputs or machines.
