# Why ASM exists

Assembly needs a shared way to build, publish, install, and check software.
ASM is that project.

We expect AI to reduce the cost of writing and revising assembly.
More code will make reliable reuse more valuable.
A useful implementation needs a clear interface, a supported target, a repeatable build, and evidence that its behavior is correct.
ASM brings those parts into one workflow.

These are our working assumptions.
They guide experiments and product decisions.
We will change them when the evidence requires it.

## 1. User outcomes determine value

People need software that works, responds quickly, and costs less to use.
The language is a means to those results.
We count development, verification, maintenance, energy, and hardware costs.

For ASM, this means a short path to the first working project.
It also means clear errors, stable interfaces, and releases that users can inspect.

## 2. AI can change the cost of assembly development

We expect AI systems to produce and revise useful assembly on a larger scale.
The result still needs tests, review, and a clear specification.
We will measure the work required to make generated code dependable.

For ASM, this means a common package format and a repeatable release process.
People and agents should use the same commands and face the same checks.

## 3. Machine control can improve selected workloads

Assembly gives direct control over instructions, data layout, and CPU features.
That control can help when the measured bottleneck requires it.
Algorithms and data structures remain part of the work.

For ASM, this means explicit target requirements and performance records beside each applicable artifact.
An efficient compiler baseline belongs in those records.

## 4. Portability has a cost that we can measure

Cheaper code generation may reduce the effort required to support more architectures.
Each target still needs an ABI contract, tests, build tools, and applicable proofs.
Evidence for one target does not establish the result for another target.

For ASM, this means one package identity with separate target artifacts.
The user must see which artifact fits their machine before installation.

## 5. Code generation requires verification

People and agents make mistakes.
We check implementations against explicit behavior.
Formal proofs establish stated properties within a model and its assumptions.
Tests and integration checks cover other parts of the system.

For ASM, this means evidence with a defined scope and a link to the exact artifact.
Lean and Kraken can supply part of that evidence.
An agent's opinion cannot grant a security status.

## 6. Performance claims require reproducible results

A useful result identifies the workload, baseline, hardware, toolchain, and source commits.
It includes raw measurements, failed experiments, and regressions.
A faster small function does not establish a faster application.

For ASM, this means a place to publish and inspect performance evidence.
We will not use a speed claim before the supporting experiment exists.

## The product that follows

ASM must make good assembly software easy to find and use.
It must also make the evidence easy to inspect.
That requires more than an index of download links.

The full product needs version resolution, locked dependencies, target selection, immutable releases, ownership, recovery, and reliable operations.
It needs a clear route from source code to a released artifact.
It needs documentation that a new user can follow without help.

We build those capabilities in tested steps.
[The roadmap](roadmap.md) records the work that remains.
[The security model](specs/security.md) states the trust boundaries.

This motivation adapts the working assumptions from LeAm, with the project owner's permission.
It is a research position, not a claim that assembly always improves performance or cost.
