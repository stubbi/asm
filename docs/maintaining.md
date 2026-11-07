# Maintain Asm

This guide defines the maintenance procedure.
It does not certify that every GitHub setting is enabled.
The repository owner must check the active settings and record material changes.

Read the [project purpose](why-asm.md), [contribution guide](../CONTRIBUTING.md), and [security model](specs/security.md) before a change to the release process.

## Ownership and repository controls

The current code owner is `@stubbi`.
The [CODEOWNERS file](../.github/CODEOWNERS) assigns that owner to every path.
GitHub uses code ownership for review requests.
A separate repository rule makes an approval mandatory, as [GitHub documents][code-owners].

One owner cannot provide an independent review of their own change.
Maintainer pull requests still provide a useful diff, check results, and decision record.
Label a review of your own work accurately.
Record the absence of an independent review for a change to a trust boundary.
An agent's review does not supply an independent human approval.

Before a release, check these controls:

1. Protect the maintainer account with strong authentication.
2. Keep recovery codes outside the repository.
3. Review collaborators, installed applications, and active credentials.
4. Require pull requests for changes to `main`.
5. Require the `Test the release contract` check from GitHub Actions.
6. Keep force pushes and branch deletion disabled for `main`.
7. Review any rule bypass permissions.
8. Enable private vulnerability reporting.
9. Check the [security reporting route](../SECURITY.md).
10. Check release immutability before publishing a new version.

[Branch protections][branch-protection] and [private vulnerability reporting][private-reporting] are GitHub settings.
Adding policy files does not enable them.
Required approval counts must match the available reviewers.
Do not configure a rule that normal releases depend on bypassing.
When another maintainer joins, review the approval requirements together.

## Review a change

1. State the user problem and expected result in the pull request.
2. Read the complete diff, including generated files and workflow changes.
3. Check the public behavior and relevant failure paths.
4. Run `make check` from the repository root.
5. Check the test result for the exact proposed commit.
6. Compare documentation and evidence with the implementation.
7. Record any unsupported target or untested condition.
8. Resolve review findings before merging.

The [project instructions](../AGENTS.md) define the detailed code and test requirements.
Assembly reviews include register preservation, bounds, system-call results, file ownership, and cleanup.
Registry reviews include namespace ownership, source commits, target declarations, artifact digests, and version immutability.

Workflow changes need a separate review of token permissions and code execution.
Pin third-party actions to reviewed commit IDs.
Keep untrusted pull request code outside jobs with publishing credentials.
Do not weaken a check to obtain a passing result.

## Prepare a release

1. Record the complete source commit ID.
2. Confirm that the release comes from reviewed `main` history.
3. Check the CLI version and its release notes.
4. Require a new, unused version tag. Never reuse an existing release version.
5. Confirm that required checks passed for that source.
6. Inspect the target list and required build tools.
7. Dispatch the [Release workflow][release-workflow] from `main`.
8. Record the workflow run URL and its source commit.
9. Wait for all release steps to finish.
10. Investigate each failed step before a retry.

The workflow checks out its triggering commit.
It runs the test suite and builds the release from that source.
It requests artifact attestations before it publishes the release.
A workflow attempt alone does not establish a successful publication.

The [release builder](../tools/release.py) compares two clean CLI builds and two clean builds for each requested hello target.
It also checks deterministic source archives and records the tools and observed execution results.
Native ARM64 Linux and Apple Silicon macOS jobs supply exact-commit executables and their runtime evidence.
The final builder consumes those bytes after it checks their source, target, version, digest, and native test results.
A missing or mismatched native input stops the build.

Linux ARM64 qualification runs the full CLI suite as root on a disposable, read-only runner.
The unchanged suite includes cross-user permission checks.
Private, root-owned source snapshots stay below `/tmp`.
This is a test-runner requirement.
The CLI installation contract still uses the caller's account.

`make test` runs every root-level CLI test module on Linux.
On macOS, it runs the native suite in `tests/macos`.
`make package-test` runs all reference-package tests.
`make check` runs both suites and the registry, release, and site checks.
Package skips identify unsupported hosts or unavailable tools.
They do not qualify a CLI host or package target.

The legacy `--native-input DIRECTORY` argument identifies macOS qualification output.
Use `--native-input-for aarch64-linux DIRECTORY` for the ARM64 Linux input.
Both directories must come from the same exact source commit.
Matching bytes in one build environment do not establish reproducibility across different toolchains or operating systems.

Published version bytes must remain unchanged.
[GitHub release immutability][immutable-releases] protects assets and their associated tag when that setting is enabled.
The workflow's step name does not enable that setting.
A correction to published artifact bytes requires a new version.

## Check the published release

1. Download each published artifact from its release URL.
2. Compare its size and digest with `release.json` and `SHA256SUMS`.
3. Verify the attestation for the exact downloaded digest.
4. Check the expected repository, workflow identity, and source commit.
5. Confirm the declared architecture and platform requirements.
6. Run the documented first-project flow in a fresh directory on a supported host.
7. Record the command, exit status, and expected output.
8. Review the generated registry manifests against the published bytes.
9. Retain the reviewed manifests in the compatibility snapshot.
10. Check the deployed registry and download links after the [Pages workflow][pages-workflow] finishes.

The Pages workflow downloads and validates declared artifacts before deployment.
General package commands check registry digests but do not verify GitHub attestations.
Asm's bootstrap installer and `asm self update` verify CLI release provenance before installation.
The registry specification defines the [publication and artifact checks](specs/registry.md).
This procedure records Asm's own release in the compatibility feeds.
It is separate from the planned [hosted publication service](hosted-registry.md#publication-boundary).

Keep the release record, checksums, source commit, target list, and workflow links available.
Do not describe a local build as a published release.
Do not describe a submitted registry manifest as an accepted package.

## Qualify the Windows verifier

The verifier workflow has separate native x86-64 and ARM64 Windows jobs.
These jobs do not qualify a released CLI host or activate production trust.
They use Go 1.27.3 and the complete verifier suite with JSON test events.

The runner selects the existing current-user `LOCALAPPDATA/Temp` directory.
This selection does not establish safe permissions or a supported volume.
Mandatory native secure-filesystem tests check the actual temporary ancestors, owner, ACL, and fixed local NTFS volume.
A failed or skipped mandatory case fails qualification.
The runner does not repair permissions.

The gate retains raw JSON, separate diagnostics, source and tree identities, input hashes, and the native Go tool digest.
Before and after execution, it compares the complete verifier file set and bytes with the original Git blobs.
It reuses the registry source collector and rejects links, junctions, extra files, and checkout transformations.
Go controls temporary test executables; their hashes remain unavailable in this gate.
A duplicate build cannot supply evidence for the executed test bytes.
Privilege-dependent skipped cases remain unqualified and appear in the result.

The capture assigns a waiting bootstrap to a noninherited Windows Job Object before Go starts.
Closing the job terminates its descendants before the runner finalizes output.
The output file has one writer, a byte limit, and a deadline.
An assignment or cleanup error fails the gate.
Native Windows execution remains required; portable capture tests exercise only their stated host.

The implementation uses [Microsoft's job inheritance and termination contract](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects).
The [assignment rules](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-assignprocesstojobobject) include nested-job limits.
The parser follows [Go 1.27.3 test-event documentation](https://pkg.go.dev/cmd/test2json).
These primary sources were checked on 5 November 2026.

## Interpret evidence

| Evidence | What it establishes | Required limit |
| --- | --- | --- |
| Digest match | The bytes match the selected digest. | It does not identify the publisher. |
| Build provenance | An expected workflow identity attested to specified bytes and source. | Verify the identity and digest. |
| Repeated build | The recorded builds produced equal bytes. | State the environment and inputs. |
| Tests | The recorded cases passed. | State the target and tested behavior. |
| Formal proof | A stated property follows within its model. | State assumptions and artifact binding. |
| Benchmark | A workload produced recorded measurements. | Retain the baseline, raw samples, and conditions. |
| Agent review | An automated reviewer supplied analysis. | Findings require validation and accountable review. |

[GitHub artifact attestations][attestations] establish provenance rather than general code safety.
Lean or Kraken results need an explicit theorem, trusted assumptions, and a connection to the relevant artifact.
No proof result applies to an unsupported target by implication.
Keep `not-run`, `unsupported`, `error`, and `fail` distinct from `pass`.
Use the [published experiment record](evidence.md) as an example of a bounded performance claim.

## Respond to an incident

1. Use the private route in [SECURITY.md](../SECURITY.md) for sensitive reports.
2. Record the affected versions, artifact digests, targets, and observed behavior.
3. Preserve relevant logs and timestamps before changing the affected service.
4. Restrict access to evidence that contains secrets or personal information.
5. Pause publication or deployment when its integrity is uncertain.
6. Revoke exposed credentials through the issuing service.
7. Assess whether repository access or artifact publication was compromised.
8. Mark affected versions as yanked when new resolution must stop.
9. Publish an advisory with affected versions, impact, and practical mitigation.
10. Restore trusted source through a reviewed commit.
11. Publish corrected artifact bytes under a new version.
12. Repeat the release and deployed-site checks before restoring normal publication.
13. Record the cause, corrective actions, and remaining uncertainty.

A yank excludes a version from new selection.
It does not remove existing installations or revoke their trust.
The current registry has no automatic emergency revocation service.
An advisory must explain any action that users need to take.

Keep published history and the incident record intact.
Follow the [code of conduct](../CODE_OF_CONDUCT.md) during investigation and disclosure.
The [security policy](../SECURITY.md) states the current support scope and response limits.

[code-owners]: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners
[branch-protection]: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
[private-reporting]: https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository
[immutable-releases]: https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases
[attestations]: https://docs.github.com/en/actions/concepts/security/artifact-attestations
[release-workflow]: https://github.com/stubbi/asm/actions/workflows/release.yml
[pages-workflow]: https://github.com/stubbi/asm/actions/workflows/pages.yml
