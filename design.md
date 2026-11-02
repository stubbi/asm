# Asm design guide

This guide covers the website, registry pages, documentation, and CLI output. Use it when you add or change a user-facing surface. The implementation is in [`site/`](site/). The [registry specification](docs/specs/registry.md) and [security model](docs/specs/security.md) define the technical claims that the interface can make.

## Purpose

Help a developer complete a task and understand the result. A new user must be able to identify a supported system, build or download the CLI, create a project, and run it. A package consumer must be able to inspect a release before using it.

The website must earn trust through accurate information. Do not manufacture signs of adoption or assurance. A small working catalog is more useful than a large fictional one.

## Reference and original direction

The requested reference is [Entire](https://entire.com/). Its [official brand guide](https://entire.com/brand) emphasizes clear space, monochrome logo use, and sufficient contrast. The homepage connects product explanations to concrete development tasks. These are useful principles for Asm.

Asm uses its own wordmark, colors, layout, code examples, and writing. Do not reuse Entire's logo, illustrations, brand assets, copy, or product claims. The reference does not grant rights to its assets. The observations above come from the public homepage and brand guide; they are not an audit of Entire's underlying CSS.

The Asm direction is a technical field guide: light paper, dark ink, visible rules, and precise labels. Use one restrained accent. Let code and package records carry the detail. Avoid glow, ornamental gradients, glass effects, decorative terminal windows, and collections of interchangeable feature cards.

## Information comes before decoration

The main page has this order:

1. State the product and its current host support.
2. Show a real first-project workflow.
3. Give build prerequisites and exact commands.
4. Let the reader search and inspect real package records.
5. Explain the target and interface model.
6. Explain the meaning and limits of evidence.
7. State what is implemented and what remains planned.

Link to full specifications from concise explanations. Keep installation instructions, the source, the registry, and the issue tracker easy to find. Avoid sign-up forms until an actual account service exists.

## Visual tokens

These values are defined in `site/styles.css`. Add tokens there before adding repeated hard-coded colors.

| Token | Value | Use |
| --- | --- | --- |
| `--paper` | `#f5f5f0` | Main page background |
| `--surface` | `#edeee7` | A grouped record or section |
| `--ink` | `#232820` | Primary text and code surface |
| `--muted` | `#62695c` | Secondary text |
| `--rule` | `#d4d8cd` | Nonessential separators |
| `--rule-strong` | `#adb6a2` | Record and column separators |
| `--accent` | `#3f5633` | Primary action and selected state |
| `--accent-hover` | `#2e4224` | Primary action hover |

Text contrast must be checked for the actual foreground and background. Decorative rules may be quiet. Essential control boundaries need sufficient contrast; the search controls use a stronger border. Color alone must never explain status.

Use the system sans-serif stack for prose and headings. Use the system monospace stack for commands, symbols, targets, versions, and checksums. The site has no external font dependency. Do not use monospaced type for long prose.

Use one main heading per page. Desktop display text can be large, but it must wrap without clipping. Body copy should normally be 14–16 pixels. Use smaller type only for short supporting metadata. Avoid long passages of uppercase text. Use sentence case for navigation, buttons, headings, and messages; small section labels can be uppercase.

The main content has a maximum width of 1200 pixels. Use 48-pixel side margins on large screens and 20-pixel margins on small screens. Use a consistent spacing scale: 4, 8, 12, 16, 24, 32, 48, 64, and 96 pixels. Adjust by a few pixels when alignment requires it. A border can group related data without making every item a card. Use square or nearly square controls. Avoid cosmetic shadows.

## Writing

Apply the useful principles of ASD-STE100: use consistent terms, short sentences, active verbs, explicit conditions, and one instruction per step. This is an STE-inspired writing policy, not a claim of formal ASD-STE100 conformance. Follow the current project instructions for any stricter vocabulary or review requirement.

Write for the person who has not used the tool before. State where to run a command. State which tools it requires. Show the expected result only after it has been observed. Explain a technical term at its first meaningful use, then use the same term consistently.

| Prefer | Avoid |
| --- | --- |
| “Build the CLI.” | “Unlock your low-level potential.” |
| “Requires Linux x86_64 and GNU binutils.” | “Works everywhere.” |
| “The checksum does not match. Download the file again.” | “Something went wrong.” |
| “Formal proof: not run.” | A green badge for an absent check |
| “GitHub asset downloads, observed on [date].” | “Developers” inferred from asset requests |
| “Support for this target is planned.” | A target logo that implies current support |

Use words such as “safe,” “verified,” “secure,” “fastest,” and “production-ready” only when a specific, defensible scope is stated. Prefer the exact check and result. Do not use arbitrary percentages for package confidence.

The motivation may include working assumptions about AI-assisted assembly, resource use, and porting cost. Label those assumptions. Performance claims need a source, a workload, a baseline, conditions, and results. Include negative and inconclusive results. Do not turn one routine's result into a claim about assembly in general.

## Registry truth

`registry/v1/index.json` is generated from accepted package records. The website reads that data. Do not maintain a second list of packages, versions, targets, sizes, or digests in JavaScript.

Render package descriptions as text. Do not insert registry strings through `innerHTML`. Validate download URL schemes and origins before making links. The first registry uses HTTPS GitHub release assets. An invalid record must not become a download action.

Derive search counts from the records currently displayed. Search runs locally. No search query is sent to analytics or a third-party search service.

`registry/v1/downloads.json` contains optional GitHub asset counters and their observation time. Describe them as GitHub asset downloads, not installs, unique people, or active users. A missing or null count means unavailable. A measured zero is a zero. Preserve that distinction.

Do not label package targets as CLI host support. A package may have a target declaration that the current host cannot build or run. The CLI download area must use real executable artifacts and name the matching host.

## Evidence display

Keep these claims separate:

- Integrity: the downloaded bytes match the selected digest.
- Provenance: an expected identity and process produced the artifact.
- Scanning: a named tool inspected a defined scope.
- Testing: defined cases passed in a recorded environment.
- Formal proof: a stated property follows under explicit assumptions.
- Agent review: an advisory analysis that still needs accountable validation.

Display `not-run`, `unsupported`, `error`, and `fail` as distinct from a successful result. Show the artifact digest and applicable target. Link to the report when one exists. Do not imply that a valid archive or a passing test establishes that a package is harmless.

Keep planned verification services separate from current package evidence. Future architecture must not appear as a live service, a fabricated report, or a reassuring badge.

## Interaction and accessibility

Use semantic HTML before custom widgets. Navigation uses links. Actions use buttons. Package records use native disclosure elements. Search fields have visible labels. Do not make a whole card clickable when it contains separate actions.

All actions must work with a keyboard. Focus must remain visible. A copy action must announce success or failure through a status region. A clipboard failure must leave the command available to select. Search results must announce their count without moving focus.

The page must remain useful without JavaScript. Build instructions, source links, specifications, and the registry JSON link remain available. JavaScript adds catalog search and record rendering. A network error must explain the problem and leave a useful route to the source.

At a 320-pixel viewport, content must not cause page-level horizontal scrolling. Long code can scroll within its own container. Digests wrap. Layout must tolerate text zoom and long package names. Touch controls should be at least 44 pixels high when practical.

Do not depend on hover to expose required information. Honor `prefers-reduced-motion`. Do not add autoplay, carousels, parallax, or ornamental animation. Icons beside text are decorative and must be hidden from assistive technology.

## Verification before publication

Check the claims against the current executable, `cli/commands.json`, release records, and specifications. Test the documented command sequence on the supported host. Do not carry forward an old success message after the implementation changes.

Check the desktop and small-screen layout in a browser. Check keyboard navigation, search, filtering, disclosure controls, empty results, unavailable registry data, copy feedback, and download links. Record a blocked check accurately. Static checks do not establish that a page was visually reviewed.

Use targeted automated checks for risky behavior: untrusted descriptions, invalid URLs, unsupported index versions, missing counters, and mismatched digests. Do not add a large UI test framework solely to assert static marketing copy.

Keep the site small. No framework, font service, analytics tracker, or third-party script is required for this release. Measure page weight before adding one. The site should serve the user's task even on a slow connection.
