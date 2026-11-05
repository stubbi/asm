# Fixed deployment envelope implementation plan

Status: native preflight failed; the parser correction has not run natively.

The base is `3b583e444092f3a1a766b7c3a8a99153970b4fe4`.
Its tree is `47eda86d610c42034f8680d9dbf29f768526c0fc`.
The user outcome is inspectable evidence for one fixed resource envelope.
The governing principles are responsible resource use and evidence tied to exact bytes.

1. Add failing local contracts for fixed limits, cgroup evidence, provider logs, report bindings, and failed cleanup.
2. Preserve the ordinary PostgreSQL 18 gate at 2 CPU and 512 MiB.
3. Add the explicit `deployment-envelope` profile to its existing harness and Makefile.
4. Give the application qualifier 1 CPU, 256 MiB, no swap, and a private 64 MiB temporary filesystem.
5. Keep the database separate at 2 GiB and 2 CPU.
6. Run baseline, admission, and envelope modules separately against fresh owned PostgreSQL 18 clusters.
7. Record actual cgroup limits, current and peak memory, events, swap, and CPU counters at test boundaries and exit.
8. Require complete evidence, unchanged deadlines, no OOM events, exact artifact bindings, and successful owned cleanup.
9. Add a bounded log-bytes provider interface for the existing nine SQL cancellation assertions.
10. Add three explicitly selected cases for slow readers, incomplete headers, and in-flight termination.
11. Run bounded local contracts and inspect the complete diff before freezing the candidate.

The Python driver and runtime share the application cgroup.
This is conservative fixture evidence, not an application-only capacity measurement.
The temporary filesystem budget does not emulate Kubernetes ephemeral-storage accounting.
CPU throttling remains visible and does not excuse a missed deadline.
Every valid request refusal, reset, truncation, and timeout remains an availability failure.
Full HTTP saturation does not imply that an additional health request can be admitted.
Bounded termination does not establish graceful response draining.

The implementation changes only test helpers, fixture configuration, tests, and their documentation.
It preserves all sixteen baseline and twelve ordinary admission cases.
Metrics, startup integration, public traffic, and private deployment remain separate gates.
No Docker execution, downloads, publication, or cluster operation is authorized for this implementation step.

## Local evidence

The first eight new contract tests failed before the implementation existed.
Later rejection checks exposed missing raw failure output and permissive report types.
Those checks failed before their fixes and passed after their fixes.
The final local gates passed 45 PostgreSQL fixture contracts, 17 admission image contracts, and three operator image contracts.
The fixture entrypoint passed Bash syntax validation.
These local results do not establish native container or database behavior.

The review follow-up rejects expected failures and unexpected successes in both PostgreSQL 18 execution profiles.
The [raw failing contract output](deployment-envelope-expected-failure-red.txt) records the expected-failure defect before its fix.
It used `python3 -m unittest discover -s tests/postgres18 -p test_harness.py -k required_assertions -v`.
The complete PostgreSQL contract gate passed 47 tests after this fix.
No native execution accompanied the follow-up.

The first native preflight later tested `7b0e18b2aedf5054b9a0b1cc49d847cdd6a1681e` and failed in cgroup evidence parsing.
Only the sixteen constrained baseline cases executed; admission and envelope cases did not run.
The [profile record](deployment-envelope.md#first-native-preflight) retains the failed receipt, all 34 samples, and the original small artifact.
A local regression failed on the retained dotted kernel key before the parser correction.
The correction preserves all resource and assertion checks.
The local contract gate passed 49 tests after the correction.
This local result does not change the failed native receipt.
