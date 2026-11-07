# Asm download and discovery data

This document specifies the implemented local `asm-deliveries-v1` profile.
Popular uses Asm-owned transfer events, independently of the artifact storage provider.
GitHub download counters never enter that ranking or its fallback path.
The native v1 release records remain immutable.

## Intent and boundary

People need real package activity with an explanation of its scope.
Dependable reuse and evidence guide this change.
Search, authenticated publication, exact lookup, and artifact delivery remain separate responsibilities.
A measurement failure must not prevent a known file from being delivered.

The local registry tool uses Python and SQLite for delivery orchestration and observation tests.
It does not replace the proposed assembly application server with a Python production backend.
The architecture still requires qualified assembly application, storage, edge, and recovery implementations before deployment.
No public deployment or global capacity is established here.

## Artifact selection and storage

The read route is:

```text
/downloads/v1/{owner}/{package}/{version}/{target}/{kind}/{sha256}
```

Selection binds an exact accepted package version, target, format, and digest.
Yanked releases cannot begin new transfers through this route.
Unknown identities, extra fields, arbitrary URLs, and changed bytes are rejected.
Two packages can share identical bytes without sharing their download attribution.
Physical storage can deduplicate those bytes by digest.

The local adapter obtains missing objects through an injected storage reader.
Its default reader can retrieve the current registered legacy URLs.
It checks the declared byte length, SHA-256, and artifact structure before delivery.
The private cache uses digest keys and refuses unsafe file paths.
Package bytes are served as attachments with `nosniff` and never executed.
The storage reader cannot select ranking counters.

Existing version-one manifests retain their original URLs and integrity checks.
Legacy CLI requests that go directly to those origins are outside the observed Asm delivery scope.
A production client migration requires the authenticated delivery protocol and its acceptance gates.
Changing published URLs or weakening the native HTTPS validator is not part of this change.

## Event contract

A trusted delivery adapter records:

```text
schema, event_id, occurred_at, name, version, target, kind,
sha256, bytes, event_type, traffic
```

`event_id` is an opaque bounded identifier for one transfer attempt.
`occurred_at` is a validated UTC timestamp.
The exact artifact identity and byte length must match an accepted record.
Event types distinguish `completed`, `range`, `redirect`, and `failed` transfers.
Traffic classes are `public`, `bot`, and `internal`.

A repeated identifier with identical fields is an idempotent replay.
Different fields under the same identifier fail atomically.
A completed event requires the full declared byte length.
Only completed public events contribute to Popular.
Reports enter through trusted local tooling; there is no public counter-increment endpoint.
Future edge adapters must authenticate their own reporting boundary.

## Counting policy

A full HTTP200 response counts after the sender writes and flushes all bytes without an error.
This measures server transfer completion, not client receipt, installation, or digest verification.
HEAD, redirects, failed or interrupted responses, conditional304 responses, and range206 responses do not contribute.
A range response cannot establish that the entire artifact was received.

Each repeated complete GET is another transfer attempt.
Replaying the same delivery event does not add another count.
Known bot and internal validation classifications are excluded.
The local adapter recognizes bounded bot markers and the explicit `AsmValidation/` client marker.
It stores the classification without retaining the user-agent string.
Unidentified or misleading automation can still contribute.
No unique-person, adoption, quality, or safety claim follows from these counts.

Package totals include registered versions retained after a yank.
Packages without an active release leave discovery.
Popular sorts positive observed totals from high to low, then canonical package identity.
Zero observed activity does not manufacture a Popular list.
Exact version pages use the same event source and window.
Sponsorship cannot influence the ranking.

## Time, coverage, and durability

### Package activity projection

The website exposes bounded read-only activity sidecars:

```text
/registry/v1/activity/{owner}/{package}.json
/registry/v1/activity/{owner}/{package}/{version}.json
```

Schema 1 uses the same `asm-deliveries-v1` policy and `asm-delivery-events` source.
The payload binds `name` and nullable `version` to accepted records.
It contains `observed_at`, `collection_started_at`, `stale`, `window`, `total`, `complete`, and `days`.
The package route counts all retained versions; the version route counts only that exact version.
Unknown identities return a missing-page response; they cannot borrow another identity's counts.

Each daily entry contains `date`, clipped `start` and `end`, `count`, `coverage`, and `observed_seconds`.
UTC calendar dates partition the same open-left, closed-right rolling window as the aggregate.
A 30-day window can intersect 31 calendar dates, including a zero-duration final midnight bin.
Daily counts reconcile with the total at the same durable cutoff.
Coverage merges all retained healthy intervals, rather than extending the latest interval backward.

`unavailable` coverage has a null count.
`partial` coverage supplies an observed minimum, including a measured zero within limited coverage.
`complete` coverage applies to the clipped bin, not necessarily the whole calendar date.
A retained positive event can remain a partial minimum even outside a healthy interval.
Missing history never becomes a historical zero.

The builder writes package-specific sidecars without adding every daily series to the global discovery payload.
The local server refreshes sidecars and native package HTML from its cached event projection.
HTTP reads do not query the ledger or write counter events.
The native daily table, scope, cutoff, and missing-data explanation remain available without JavaScript.
This local adapter does not establish production capacity or authenticated edge reporting.

### Aggregate reporting

The window is 30 days ending at the durable source heartbeat watermark.
Public `observed_at` and `window.end` identify that same cutoff.
Collection time is not a release publication date.

The store retains delivery events and healthy reporting intervals.
A new session starts a new coverage interval.
An interruption, restart, or heartbeat gap over 60 seconds cannot extend a previous healthy interval.
Complete coverage requires a continuous interval across the entire requested window.
An incomplete window supplies an observed minimum, displayed with **≥**.
Unknown history is not zero.
New collection displays its start date and incomplete history.

The local service writes a heartbeat and refreshes its projection every 5 seconds by default.
A failed event write interrupts coverage.
A failed snapshot read retains the last projection as stale.
A recovery starts or records a new coverage segment instead of bridging the gap.
The persistent store survives process restart and rejects unsafe or corrupt state without replacing it.
The module enforces explicit database, row, timestamp, and integer bounds.

The browser reads cached discovery every minute while visible.
Updates wait while a feed control has focus.
Native sorted pages use the same projection without requiring JavaScript.
Search remains available while download reporting is unavailable.

Scope is configured Asm delivery sources only.
Missing mirror reports and direct legacy-origin requests do not establish total global volume.
Production edge collection needs durable reporting, authenticated ingestion, and tested replay and coverage guarantees.
Local socket completion and a green fixture do not qualify those operational guarantees.

## Privacy

The event record has no IP address, visitor identifier, cookie, fingerprint, user-agent string, or search term.
The local HTTP service does not log request URLs.
Traffic classes describe counting rules and do not identify people.

## Extended exploration and statistics

The existing Popular route retains its thirty-day contract and now displays **Most downloaded**.
Do not duplicate that ranking as a separate list of “most recent downloads.”
The Explore page adds cumulative downloads, categories, keywords, and direct dependents.

Architecture discovery uses the explicit accepted version-one target profiles.
`aarch64-linux`, `aarch64-macos`, and `aarch64-windows` group under `aarch64`.
`x86_64-linux` and `x86_64-windows` group under `x86_64`; `riscv64-linux` groups under `riscv64`.
Other target names have no inferred architecture.
Native directories are `/browse/architectures/` and `/browse/architectures/{architecture}/`.
Only groups with current active packages receive a detail page.
Membership counts distinct package identities in their latest active release, across that release's matching artifacts.
Historical-only support and yanked releases do not enter current membership.
These routes do not depend on download observations and do not change published release records.
The matching targets remain visible; architecture alone does not establish operating system, ABI, CPU features, or host support.
Search stores its architecture selection in the local URL fragment and preserves it through package return navigation.
Format, architecture, and exact target must match one active artifact, rather than separate files within a package.

Cumulative totals include retained completed public events through the same reporting watermark.
Their window starts at `collection_started_at`, including a completed event at that boundary.
Coverage must span the entire collection period before the total is exact.
An older gap can leave cumulative counts incomplete while the latest thirty-day window is complete.
Unknown earlier activity and transfers outside configured Asm delivery sources remain outside the metric.
The event retention limits and exclusion rules above still apply.

`registry/v1/discovery-metadata.json` is a reviewed, rebuildable schema-one sidecar.
It contains package keywords and optional direct-dependency declarations by version and exact source commit.
The sidecar permits up to thirty-two keywords per package and 4,096 distinct active keywords overall.
It does not change published manifests or grant authority to install a package.
Missing declarations differ from an explicit empty dependency list.
Keyword and category rankings count each active member package once.
Direct-dependent rankings count distinct other packages with declarations for their latest active release.
The declaration covers package-level direct dependencies across its targets, without inferring target compatibility or transitive dependencies.
Incomplete declaration coverage supplies positive observed minima; it does not establish unknown zeroes.

`registry/v1/stats.json` contains exact catalog totals, cumulative observed transfers, and a separate registry-wide thirty-day activity series.
The daily series uses the same UTC bins, cutoff, and gap semantics as package activity.
The local Stats and Explore routes use cached observations from one reporting generation.
HTTP reads do not query the ledger or create download events.

The Blog generator reads released changelog sections for accepted Asm versions during the ordinary site build.
The historical adapter can supply exact release availability only when all registered asset bindings match retained evidence.
Missing dates remain unknown; package-wide dates never substitute for a version’s date.
Unreleased changes do not become posts. Undated posts remain outside the Atom release feed.
This is local generation, not a new publication or authentication service.

The blog also accepts authored Markdown articles from `blog/posts/`, outside the public `site/` tree.
Each file has a bounded TOML header with its title, summary, author, draft state, and editorial dates.
Published articles require a declared UTC calendar date; revisions can supply a later `updated` date.
The combined Blog and Atom feed distinguish authored articles from generated release entries.
Article dates never replace source-bound release dates.
The normal build omits draft content and source files.
The explicit `--include-blog-drafts` option creates a labelled local preview with `noindex` metadata.
Draft detail pages remain outside the sitemap and feed, including during preview.
Article bodies reuse the safe Markdown renderer and cannot execute HTML, scripts, or templates.
The [authoring guide](../../blog/README.md) defines the source format and repository publication workflow.

## Historical publication metadata

New packages uses retained GitHub release availability dates for the legacy catalog.
The visible label remains **First GitHub release**.
The later public release or declared asset creation timestamp establishes that release’s availability.
Yanking does not reset the package’s first date.
A later maintenance publication can have a lower semantic version.

This metadata adapter is separate from the first-party delivery ledger.
Its `publication_observed_at` timestamp does not depend on download collection or its reporting watermark.
Its upstream counters are not imported into Asm activity.
Authenticated Asm publication events remain required for the future publication service.
Historical imports must not be presented as new Asm publication events.

## Local use

Build checked package pages with the Asm delivery route:

```sh
python3 tools/build_site.py --output build/site-own-downloads --verify-artifacts --artifact-delivery --discovery-state build/download-data/events.sqlite3 --publication-state build/discovery-state/history.sqlite3
```

Start the local web app:

```sh
python3 tools/serve_site.py --site build/site-own-downloads --state build/download-data/events.sqlite3 --artifact-cache build/artifact-cache --port 8765
```

Open `http://127.0.0.1:8765/`.
The first-party ledger begins without imported GitHub download activity.
Keep the server running to collect coverage and transfers.
Use a separate store for tests and validation.
Rebuild and restart after accepted records or category metadata change.

Static builds without a first-party ledger show unavailable activity.
They must not fill Popular from upstream counters or generated fixture events.
The existing Pages job can still refresh historical publication metadata.
Publishing a live delivery service requires a separate deployment decision and the architecture gates.

## Verification

Run `make site-test`.
The gate covers ledger replay, identity, classification, coverage, restart, response completion, failures, rendering, and navigation.
Run the registry suite after artifact-format or delivery contract changes.
Use actual local file transfers and browser navigation to verify the complete path.
Fixture counts remain separate from real service evidence.
