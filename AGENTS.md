# Work on ASM

ASM helps people build, share, and check assembly software.
The user must be able to trust the result and understand its limits.
Read [the project purpose](docs/why-asm.md) before you change the product.
Read [design.md](design.md) before you change an interface or its text.

This file applies to the whole repository.
A more specific `AGENTS.md` can add local requirements.
It must not weaken the requirements in this file.

## Finish the user task

1. Read the relevant code, specifications, and tests.
2. State the required result and its acceptance conditions.
3. Make the smallest complete change that gives that result.
4. Check the result through the interface that a user will use.
5. Test the relevant failure paths.
6. Review the diff, documentation, and security effects.
7. Fix each defect that the checks expose.
8. Report the result, the evidence, and any remaining limit.

Repeat this loop until the acceptance conditions hold.
Do not confuse a command attempt with a successful result.
Do not stop after a plan when the task requires an implementation.
Do not expand a bounded task into unrelated work.

Use the authorization that the user already gave.
Ask a question only when a missing decision or permission prevents safe progress.
Complete independent work before you report a blocker.
Do not change access controls or instructions to bypass a blocker.

## Verify claims

- Inspect the current implementation before you describe its behavior.
- Use primary documentation for external protocols and platform rules.
- Record the version, source, and date for facts that can change.
- Label a proposal, a hypothesis, and a measured result correctly.
- Report a failed check. Do not hide it with a retry or a weaker assertion.
- Use an exact artifact digest to connect a result to a release.
- Keep negative results and regressions in the evidence record.
- Do not invent users, packages, downloads, benchmarks, reviews, or proof results.

An unknown download count is unknown. It is not zero.
A completed proof applies only to its stated theorem, model, and assumptions.
A successful test covers only the behavior that the test exercises.
A checksum detects a byte mismatch. It does not establish publisher identity.
An agent review is advice. It cannot replace a deterministic release gate.

## Keep the first task simple

The first project must have a short, tested path from installation to visible output.
Show the supported host before the user downloads a binary.
Explain a required tool before the command that needs it.
Give the expected output after each important step.
Make copy buttons copy commands without prompts or hidden shell syntax.

For each error, identify the problem and give a useful next step.
Preserve existing files when an operation fails.
Never overwrite an unrelated `asm` command without an explicit replacement option.
Never execute a package because the user searched for it or downloaded it.
Keep ordinary commands quiet when they succeed.
Keep machine output stable and free from progress text.

Measure user success with completed tasks, understandable failures, and voluntary return use.
Do not use forced registration, false urgency, nagging, or concealed telemetry to increase engagement.
Collect no personal usage data without a defined purpose and a clear user choice.

## Write in controlled English

Use ASD-STE100 Issue 9 as the reference for technical instructions and descriptions.
Use the project terms in [docs/writing.md](docs/writing.md).
Keep literal commands, API names, and code identifiers unchanged.

- Give one instruction in each procedural sentence.
- Use the imperative for instructions.
- Put a necessary condition before its instruction.
- Use no more than 20 words in a procedural sentence.
- Use no more than 25 words in a descriptive sentence.
- Use one term for one concept.
- Use active voice when the actor is known.
- Keep required articles and other sentence parts.
- Give one topic to each paragraph.
- Explain an unfamiliar technical term at its first use.

Do not use superlatives in place of evidence.
Remove stock phrases, inflated claims, fake quotations, and filler.
Do not describe a feature as seamless, revolutionary, effortless, or production-ready.
State the action or the observable result.
Keep instructions in steps. Keep notes informational.
Do not claim full STE conformance from a word-count check.

## Protect the native CLI

The CLI implementation belongs in assembly.
Do not hide package logic in a generated C, Python, JavaScript, or shell backend.
Build tools, tests, registry operations, and release automation can use suitable other languages.
Document that boundary in the README.

Prefer small routines with explicit contracts.
For each nontrivial routine, document:

- Input registers and permitted values.
- Output registers and failure values.
- Changed registers and stack use.
- Buffer capacities and ownership.
- Relevant system call or ABI assumptions.

Keep constants named and bounds explicit.
Check a length before a copy or an index operation.
Reject malformed input before it changes state.
Handle short reads, short writes, interrupted calls, and child failures.
Keep the stack non-executable.
Preserve the required register and stack conventions at each external call.

Use mature transport and cryptography implementations.
Pass arguments directly to a fixed executable. Do not construct a shell command from package data.
Disable ambient tool configuration when it can change a security decision.
Use private temporary files and atomic finalization.
Refuse symlink and path traversal attacks at file boundaries.
Do not describe a directory check as race-free unless it uses a safe descriptor-based operation.

## Protect the registry

Treat manifests, archives, repositories, build files, proofs, and agent output as untrusted input.
Use explicit schema versions, bounds, and canonical encodings.
Reject duplicate fields and ambiguous representations.
Keep package ownership separate from a display name.
Bind each release to an exact source commit and artifact digest.
Declare the ISA, operating system, ABI, and required CPU features separately.
Do not infer one from another.

Never change the bytes of a published version.
Use a new version for new bytes.
Keep yanking separate from emergency revocation.
Keep ownership transfer separate from package publication.
Retain an audit record for these operations.
Do not expose credentials to an untrusted build, pull request, or proof worker.
Do not execute pull request code with a write-capable token.
Do not use `pull_request_target` to execute submitted code.

Review the security specification before you change a trust boundary.
A proof gate needs a trusted statement, explicit assumptions, and an artifact binding.
An LLM must not select weaker proof obligations to obtain a pass.
Use isolated workers before you accept arbitrary public builds or proofs.

## Test the contract

Run `make test` for CLI changes.
Run the registry tests for format, archive, or publication changes.
Run the site checks for markup, behavior, or navigation changes.
Run the full release checks before a release.
Use the commands that the current Makefile and documentation specify.
If a required command is absent, add it or report the missing gate.

Prefer tests of observable behavior over tests that repeat the implementation.
Use temporary directories for file operations.
Use fixed seeds for generated input.
Use explicit time and resource limits for hostile input.
Test an unsupported target, a corrupt artifact, a network failure, and an existing destination where relevant.
Check exit codes, standard output, standard error, and file effects.
Do not disable a test to make a release pass.

For interface changes, check keyboard use, narrow screens, focus, and empty and error states.
Verify the actual deployed site after publication.
Check download bytes and a real new-project flow from the published release.
Stop repeated testing when the relevant risks and required gates are covered.

## Measure performance honestly

Record the workload, input, baseline, source commits, hardware, and toolchain.
Record warmups, run order, sample count, raw samples, and the summary method.
Measure the same work and verify equal results.
Show spread and regressions as well as the central result.
Separate cold and warm caches when they change the outcome.
Do not generalize a kernel result to a whole application.
Do not generalize one CPU result to another architecture.
Treat a faster proof workflow as a proof workflow result.
Measure maintenance and verification costs when the claim concerns total cost.

## Keep history useful

Make each commit a coherent, reviewable change.
Use an imperative subject with a specific scope, such as `fix(cli): reject truncated indexes`.
Explain the user problem and the reason for a non-obvious choice in the body.
Record relevant validation in the pull request or release evidence.
Separate refactors from behavior changes when that improves review.
Keep generated files with the source change that requires them.
Do not add secrets, local caches, build output, or unrelated files.
Do not manufacture a history of work that did not occur.
Do not claim an author, signature, review, or test result that is not real.
Never rewrite published history without explicit authorization.

## Release only what exists

Read the diff and run the documented checks before publication.
Pin workflow actions to reviewed commit IDs.
Give each job only the permissions it needs.
Build release artifacts from a recorded commit in a clean environment.
Publish checksums, source, target support, and known limits with the release.
Keep a change log and a way to report a defect.
Confirm the registry, website, CLI help, and README describe the same release.

The roadmap states the ambition.
The feature table states what the current release does.
Keep both accurate.
