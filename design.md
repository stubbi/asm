# Asm design guide

This guide covers the website, registry pages, documentation, and CLI output. Use it when you add or change a user-facing surface. The implementation is in [`site/`](site/). The [registry specification](docs/specs/registry.md) and [security model](docs/specs/security.md) define the technical claims that the interface can make.

## Purpose

Help a developer complete a task and understand the result. A new user must be able to identify a supported system, build or download the CLI, create a project, and run it. A package consumer must be able to inspect a release before using it.

The website must earn trust through accurate information. Do not manufacture signs of adoption or assurance. A small working catalog is more useful than a large fictional one.

## Reference and direction

The homepage is a package search page.
Search is its primary action; package discovery follows directly below it.
Installation, documentation, project information, and support links remain available from the navigation and footer.
The separate [guide](site/guide.html) retains the package walkthrough and detailed explanations.

The reference study dated 6 November 2026 uses [PyPI](https://pypi.org/), [npm](https://www.npmjs.com/), [crates.io](https://crates.io/), and [Google](https://www.google.com/).
Their shared search pattern informs the task order: identify the service, enter a query, and inspect results.
The registry references also inform the supporting package lists and footer links.
Google informs the clear emphasis on one action and the use of open space.
These observations do not establish why any service succeeded.
Asm does not reuse their names, logos, artwork, copy, or adoption claims.

[NN/g's minimalism guidance](https://www.nngroup.com/articles/aesthetic-minimalist-design/) supports removing noise while retaining task information.
Its [search guidance](https://www.nngroup.com/articles/search-visible-and-simple/) supports a visible field, a clear action, and an initial scope of all content.
[NN/g's hierarchy guidance](https://www.nngroup.com/articles/principles-visual-design/) supports using relative size to show task priority.
[Krug's sample chapter](https://sensible.com/downloads/DMMT-Revisited-sample-chapter.pdf) from *Don't Make Me Think, Revisited* (2014) emphasizes clear choices over minimum click counts.
[Google's identity study](https://design.google/library/evolving-google-identity) supports a recognizable mark that remains legible at small sizes.
These sources were reviewed on 7 November 2026.

Google's [1998 paper](https://research.google/pubs/the-anatomy-of-a-large-scale-hypertextual-web-search-engine/) describes retrieval quality and scalable indexing.
The [2000 Yahoo agreement](https://googlepress.blogspot.com/2000/06/yahoo-selects-google-as-its-default.html) placed its search engine behind Yahoo's interface.
Node's [2011 account](https://nodejs.org/en/blog/uncategorized/growing-up) records npm bundling and a growing module ecosystem before its website redesign.
The [2014 Cargo launch](https://blog.rust-lang.org/2014/11/20/Cargo/) describes integrated dependencies, reproducible versions, and retained releases.
These historical sources were reviewed on 7 November 2026.
They do not establish that minimal homepages caused platform success.

The user outcome is finding a compatible package with less visual competition around search, while keeping package browsing available.
This follows the brand principles: serve the person, respect resources, and earn trust with evidence.
The trade-off is an additional action to open full release information from compact discovery groups.
The guide retains the detailed walkthrough and its recorded evidence.
Local search, format and target filtering, discovery actions, empty-result recovery, and accessible navigation provide the acceptance evidence.
Browser checks establish observed behavior, not measured user preference or comparative usability.

The visual direction uses white content, soft neutral framing, charcoal actions, readable gray metadata, and quiet rules.
The lowercase wordmark is `>asm`.
Use optical spacing between the prompt and letters, without a full word space.
Keep the letter height consistent when the mark becomes narrower.
The prompt character connects the identity to assembly tools without adding a simulated terminal window.
Use the same mark in the header, footer, icon, and shared previews where space permits.
Preserve the typeface source and license notice in [`site/brand/NOTICE.txt`](site/brand/NOTICE.txt).

Use the native system sans-serif face for prose, headings, navigation, and actions.
Use the self-hosted JetBrains Mono 2.304 face for code and compact technical information.
Keep its license and source notice in [`site/fonts/`](site/fonts/).
The outlined wordmark does not require a font download.
Do not use monospaced type for long prose.
Avoid ornamental gradients, glow, glass effects, decorative terminal windows, and interchangeable feature cards.

## Brand fit and story

The brand review dated 7 November 2026 keeps the current identity and strengthens its connection to the product.
The outcome is a clear assembly package workflow with an understandable purpose.
This is a reasoned design decision, not measured brand recognition or user preference.

Minimalism serves the person who must find, inspect, and use software.
It does not mean that assembly always needs fewer instructions, runs faster, or costs less.
Required target information, evidence limits, and recovery actions remain part of the interface.

The identity has three levels:

| Level | Expression | Where it belongs |
| --- | --- | --- |
| Task | Find assembly packages | Homepage search |
| Product | A package registry and command-line tool for assembly projects | Guide, installation, and introductions |
| Purpose | Software should serve people well and use resources with care | Project story and motivation |

The deeper story connects AI, assembly, reuse, and human judgment.
AI may reduce the work of creating assembly; useful reuse still needs explicit targets and inspectable evidence.
People set the intent and decide what to trust.
Keep this explanation in the guide and motivation documents, where readers choose to learn more.
The shared About Asm footer link opens the project page, which retains a link to the guide's story section.

### Identity decisions

| Choice | Connection to the story | Limit |
| --- | --- | --- |
| Small `>asm` wordmark | Names the command and suggests a tool ready for deliberate use | The prompt is a familiar command-line cue, not an assembly instruction or proof symbol |
| System sans-serif prose | Gives instructions and explanations a readable, ordinary voice | Familiar typography alone does not make the brand distinctive |
| JetBrains Mono for code, technical values, and the mark | Connects identity with the material people inspect and build upon | Keep long explanations in the prose face |
| Neutral framing, white content, charcoal actions | Keeps search dominant while machine metadata carries the product identity | A palette does not establish publisher identity or software safety |
| Real source, versions, targets, and evidence | Makes the assembly focus visible through useful information | Current capabilities and missing checks must remain distinct |

Use the complete wordmark when space permits.
Use asm.build with it in external introductions where the product's identity needs context.
The compact prompt icon supports constrained spaces; it does not carry the complete story alone.
Keep the prompt out of copyable commands.
Do not invent an assembly origin or a technical guarantee for the symbol.

The intended distinctive pattern is a package identity, exact version, explicit target, and inspectable result.
The four-instruction example demonstrates that pattern with actual source and recorded behavior.
Decorative assembly backgrounds would add category imagery without helping someone inspect a package.
The existing palette and typefaces are category conventions; their use does not establish exclusive recognition.

Use concrete headings for machine requirements, calling interfaces, and build records.
Show concepts in prose unless they are literal fields or identifiers.
Do not style conceptual labels as invented manifest keys.
Remove numbers from parallel concepts that have no required order.
Give equal release states equal visual treatment.

### Research basis

[Cargo's introduction](https://doc.rust-lang.org/cargo/) and [npm's product explanation](https://docs.npmjs.com/about-npm/) distinguish the command-line tool, registry, and website.
They support concrete product language and separate responsibilities.
[Krug's sample chapter](https://sensible.com/downloads/DMMT-Revisited-sample-chapter.pdf) supports clear choices rather than an arbitrary minimum number of clicks.

[NN/g's minimalist-site study](https://www.nngroup.com/articles/characteristics-minimalism/) distinguishes visual conventions from meeting users' needs.
It does not establish that minimal appearance causes commercial success.
[Rams's principles at Vitsœ](https://www.vitsoe.com/eu/about/good-design) connect restraint with usefulness, honesty, resource care, and attention to detail.
Those principles fit the foundation's intent; they are not an Asm usability measurement.

[Google's identity account](https://design.google/library/evolving-google-identity) describes consistent assets and testing at small sizes.
[Go's brand account](https://go.dev/blog/go-brand) connects identity with values, users, and simplicity.
[JetBrains' typeface explanation](https://www.jetbrains.com/lp/mono/) describes code-specific letterforms and distinguishable symbols.
These sources inform the system, not a claim that their brands or success transfer to Asm.

[Ritchie's Unix history](https://www.nokia.com/bell-labs/about/dennis-m-ritchie/hist.html) describes communication and a community working together as part of the system's purpose.
It supports the compatibility of technical tools and a human purpose.
[PyPI's documentation](https://docs.pypi.org/) separates integrity, provenance, and source-security assessment.
Asm retains those distinctions rather than presenting one general assurance badge.
All sources in this section were checked on 7 November 2026.

The trade-off is familiarity in the interface and fewer ornamental brand cues.
The product's specific content carries more of its identity.
Assess that choice with recognition, finding a compatible package, understanding missing evidence, and completing the first project.
The local checks establish implementation behavior; recognition and comparative usability still require people using the product.

### Interface refinement

The package-browser review identified a document-like appearance in the first implementation.
The refinement keeps the wordmark while strengthening the product interface.
Use stronger sans-serif headings, compact metadata, and grouped navigation with a visible current location.
Use the prose typeface for package names in headings and navigation.
Keep targets, versions, digests, and code in the technical typeface.
Keep permanent underlines for links within prose.
Use hover, focus, grouping, and selected surfaces for navigation and standalone actions.
Separate main content sections with space instead of repeated horizontal rules.
Use one quiet source panel beside the release content on wide screens.
Keep file identity, evidence, and complete digests readable at every layout size.

This direction follows the owner's visual feedback and the principle of serving the person.
The trade-off is less decorative framing around the same package information.
Native links, clear grouping, pointer feedback, keyboard focus, and current-location states retain the interaction cues.
Browser checks cover navigation, narrow layouts, enlarged text, and the existing fallback states.

## Search homepage

Use one small header wordmark, 20 pixels high at the default text size.
Group the header and search in one quiet, solid surface band.
Use the shared `--surface` token for this band and the primary footer navigation.
Use the same color for the root canvas revealed beyond the page during native overscroll.
Keep the body background white so content retains its existing surface.
This follows the [CSS canvas background rules](https://www.w3.org/TR/css-backgrounds-3/#special-backgrounds), checked on 7 November 2026.
Keep the search area free of duplicate logos and suggested-search clutter.
Use one short product description and one native catalog link below the field.
Do not place decorative assembly code behind the header or search.
This choice follows the hierarchy and noise principles above; it is not a measured Asm usability result.

Use "Find assembly packages" as the main heading and visible input label.
Use a 32–44-pixel heading at the default text size, with a wide, high-contrast search field.
Make the search field the most prominent control.
Keep it wider than the surrounding actions.
A placeholder cannot replace its label.
Use a clear Search button.
Let enlarged search controls wrap before the input becomes too narrow to use.
The current static search keeps terms on the user's device.
A future first-party search service can receive the query needed to return results.
Do not send queries to analytics or a third-party service.
Do not retain raw search terms in request logs.

### Search across pages and navigation motion

Keep one active search field on each page.
The homepage field starts in the hero and moves into the shared header during scrolling.
Inner pages use a compact field in the shared header.
Give the compact field a visible Search label and an accessible submit button.
Let the field occupy a full row when the navigation needs more space.
Start a fresh global search from the header, without carrying hidden filters from another package.
Use the existing local URL fragment format, including for an empty search.
Reveal the field only after its submit handler is ready; retain a native Browse packages link if enhancement fails.

Use a short native transition to connect the homepage search area with the inner-page header.
The shared gray surface changes height; the search field changes size and position.
Keep the wordmark and navigation stable while the remaining content fades.
Give the gray surface and search field 480 milliseconds with gentle acceleration and deceleration.
Let the gray surface and search snapshots fill the interpolated height so their edges move together.
Cross-fade the search contents within 160 milliseconds to limit overlapping text during the longer movement.
Keep the homepage introduction above the surface; reveal it after the moving field passes its text.
Keep other shared elements at 220 milliseconds and the page content fade within 280 milliseconds.
This timing follows the owner's request for more perceptible header movement; it is not a measured usability optimum.
Do not intercept ordinary links, replace browser history, or wait for an animation before navigating.
Disable navigation motion for reduced-motion preferences.
Skip the transition when the outgoing search area has scrolled above the viewport.
Skip incoming search motion if its layout script is not ready; do not wait for a script or registry request.
Browsers without cross-document view transitions retain ordinary navigation.

The user outcome is continued access to package search and a clear relationship between page layouts.
This follows serving the person, preserving control, and respecting resources.
The trade-off is a small cached head script so the incoming surface can be measured before its transition snapshot.
[Chrome's cross-document documentation](https://developer.chrome.com/docs/web-platform/view-transitions/cross-document) defines the early page-reveal listener requirement.
The [CSS View Transitions specification](https://drafts.csswg.org/css-view-transitions-2/) defines native navigation participation.
These sources were checked on 7 November 2026.
URL, fallback, keyboard, responsive, motion-preference, and browser-navigation checks establish the implementation evidence.
They do not establish a measured preference for motion or comparative search usability.

### Sticky navigation and search

Keep the shared navigation pinned to the viewport while the page scrolls.
Use the existing neutral surface and a quiet bottom rule above page content.
Keep the page-top masthead canvas outside the sticky header, so its background cannot travel over the content.
Measure the actual header content height for section, focus, and skip-link offsets.
Keep navigation in normal flow when scripts are unavailable.

As the homepage field approaches the header, move the same search control into the compact header layout.
Reverse the movement when its reserved hero position becomes visible below the header.
Use separate entry and return boundaries to prevent oscillation near the threshold.
Reserve both the hero field space and the header's original document height.
The movement must not move the content below them.
Keep the query, selection, input identity, and native form owner unchanged.
Restore an existing focus with `preventScroll`; do not focus an inactive control.
Defer movement until an active text composition ends.
Keep one connected query control; the unused header placeholder has no query name.
Scrolling must not change the URL, history, or search results, or start a network request.

Reuse the existing 480-millisecond search movement and easing.
Exclude the page content, hero introduction, and page-top canvas from this local snapshot.
Keep that content live and scrollable while the search field moves.
Cancel obsolete snapshots when the scroll direction changes; apply the latest requested state.
Handle rejected snapshot promises when optional animation is skipped.
Use immediate movement for reduced motion, restored scroll, and browsers without the transition API.
On narrow screens shorter than 24 rem, keep navigation in normal document flow to preserve reading space.
Also use normal flow when the measured header exceeds half the viewport height, including with enlarged text.
Retain that decision until the viewport changes, so expansion cannot make the state oscillate.

This serves continued package search while reading and follows serving the person and preserving control.
The trade-off is a small scroll enhancement and a reserved placeholder, with normal-flow navigation on short narrow viewports.
[W3C focus guidance](https://www.w3.org/WAI/WCAG22/Understanding/focus-not-obscured-minimum.html) explains the sticky-header obstruction risk.
[Native form ownership](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Attributes/form) preserves submission after the control moves.
The [transition specification](https://drafts.csswg.org/css-view-transitions-1/#dom-viewtransition-ready) defines skipped snapshot promise behavior.
[Chrome's element-transition guidance](https://developer.chrome.com/docs/modern-web-guidance/guides/ui-behaviors/group-element-transitions) explains how to exclude the full-page snapshot.
These references were checked on 7 November 2026.
Verify scrolling, reversal, composition, keyboard use, section links, saved results, text enlargement, and reduced-motion behavior.
These checks establish implementation behavior, not comparative usability or an optimal timing.

### Intended discovery

Design the finished homepage around discovery needs, independently of the present catalog and available fields.
Keep search first.
Follow the hero with factual catalog statistics and three package activity lists.
Link Install Asm to the GitHub README installation section.
Link Getting started to the README quick start.
Show **New packages**, **Most downloaded**, and **Recently updated** in three compact columns on wide screens.
Use two columns below 860 pixels and one below 620 pixels.
Keep purpose and architecture browsing on Explore, reached from the shared navigation.
Show up to five packages in each list, with a link to its complete results.
Do not duplicate the complete catalog on the homepage.

| Element | User need | Definition |
| --- | --- | --- |
| Search | Find a known package or describe a task | Relevant matches, with exact package identity preferred |
| Functional categories | Explore a problem without knowing package names | Browse by purpose, rather than artifact format |
| Most downloaded | Inspect packages receiving current download activity | Downloads during a declared 30-day observation window |
| New packages | Discover recently published packages | First public release under the declared source profile, newest first |
| Recently updated | Inspect releases of existing packages | Latest active publication time, separately from the highest numeric version |
| Format, architecture, and target | Refine candidates for a workflow and machine | Search and Browse filters, with explicit targets visible in package previews |

Use **Last 30 days** as the visible explanation beneath Most downloaded.
Define the download event, coverage, and observation cutoff in the linked metric explanation.
Thirty days is a product starting choice, not a measured optimum for Asm.
It gives Popular a current-activity scope; evaluate another window if relevance and stability checks justify a change.
Avoid lifetime download totals as the main discovery ranking.
Keep lifetime totals available as an explicit secondary sort if needed.
Keep **Trending** out of the primary layout unless a separate growth definition earns that space through task testing.

New refers to a package's first publication, not its newest version, import time, rename, or ownership change.
Recently updated refers to a new public release of an existing package, not an edit to descriptive metadata.
Sort that feed by publication time, not the numerically highest version.
A newly published maintenance release can have a lower version than another retained release.

Each list entry shows a linked package name, a short purpose, and a compact target summary.
Popular entries show the applicable download count; New entries show the first-publication date.
Keep full evidence and artifact information on the package page.
Do not imply that popularity establishes suitability, maintenance, publisher identity, or safety.
Sponsorship must never influence discovery ranking.

Candidate category labels include Text, Math, Compression, Cryptography, System, and Developer tools.
These are proposed task categories, not claims about today's package metadata.
Validate their meaning with package-finding tasks before fixing the taxonomy.
Do not infer a library or program role from a source archive.
Keep target selection explicit; do not silently infer a visitor's intended machine from their browser.

Open a package page when the reader selects a package.
Open the complete applicable results when the reader selects a list's View all action.
Keep relevance as the default for a typed search; a popular package must not displace an exact identity match.
Show format, architecture, and exact target filters only in the results state.
Require one active artifact to match all selected filters.
Show matching formats and targets in result previews, so other artifacts cannot imply availability for the selected architecture.
Keep All packages and Back to browse actions available in their applicable states.
Keep complete artifact details and evidence on package and exact-version pages.
Retain an index link and a source route when the registry cannot load.
Explain empty results and provide a useful next action.
Announce the result count without moving focus.

Use real links for package names and exact release versions.
The current static search stores terms and filters in URL fragments, avoiding transmission to the static host.
Future server-rendered search must retain shareable state, browser navigation, and the same first-party privacy boundary.
Restore the query, format, architecture, target, and results state on reload and browser Back.
Typing replaces the current history entry; committed filter changes can create a new entry.
Keep a plain HTML catalog available when scripts or the index request are unavailable.

### Evidence and implementation

The research review dated 7 November 2026 supports changing the intended homepage emphasis.
[NN/g's format-navigation guidance](https://www.nngroup.com/articles/format-based-navigation/) favors task and topic context over format silos.
Its [search and navigation guidance](https://www.nngroup.com/articles/search-not-enough/) explains why browsing remains useful alongside search.
Applying those findings to package discovery is a reasoned inference.
[Krug's sample chapter](https://sensible.com/downloads/DMMT-Revisited-sample-chapter.pdf) favors understandable choices over arbitrary limits on clicks.
These sources support clear discovery routes; they do not establish an optimal number of homepage lists.

[Crates.io's summary implementation](https://github.com/rust-lang/crates.io/blob/b15395183ac408fee9cf1340c53def3b994b214e/src/controllers/summary.rs) separates new, updated, lifetime-download, and recent-download lists.
That revision uses a 90-day recent-download window.
[Rust RFC 1824](https://rust-lang.github.io/rfcs/1824-crates.io-default-ranking.html) explains the trade-offs behind recent downloads as a starting point for further evaluation.
Asm's 30-day window is a design choice, not a copied claim of measured superiority.
The owner's later reference pass adds Recently updated as a third compact homepage route.
The additional scanning choice is an intentional trade-off for a broader catalog view.
A stable assembly component may not need frequent releases; update recency is not a quality claim.
Functional categories provide a different route for people who know their problem but do not know package names.

[PyPI's official feeds](https://docs.pypi.org/api/feeds/) distinguish newly created projects from newly created releases.
Its [current homepage](https://pypi.org/) emphasizes search, browsing, statistics, and an introduction instead of the same activity lists.
The npm homepage could not be inspected through the research fetch because it returned HTTP 403.
Its [official search documentation](https://docs.npmjs.com/searching-for-and-choosing-packages-to-download/) supports relevance and explicit alternative sorts.

[A library-selection study](https://arxiv.org/abs/2005.12574) interviewed 16 developers and surveyed 115 developers about technical, human, and economic factors.
[A study of 175,000 npm packages](https://arxiv.org/abs/1901.04217) found that different popularity measures can describe different things.
These studies support preserving purpose, compatibility, documentation, and evidence beside discovery signals.
Neither study tests this homepage layout or establishes preferences among Asm users.

The implementation uses New packages, Popular, and Recently updated, with purpose categories from explicit maintainer metadata.
Format and target remain search refinements.
Native browse pages provide the complete Popular, New, and Recently updated lists without JavaScript.

The implemented `asm-deliveries-v1` profile ranks Asm-owned delivery events.
The artifact storage provider does not supply Popular's counter.
Changing from GitHub assets to another object store must not change measurement identity or ranking policy.

Popular shows **Downloads · Last 30 days**.
A completed full transfer contributes after the delivery service writes and flushes all declared bytes.
The event binds package, version, target, format, byte length, and digest.
Physical object deduplication must not credit unrelated packages with identical bytes.
HEAD requests, redirects, partial transfers, conditional responses, known bots, and internal checks do not contribute.
Repeated complete requests remain separate transfers; duplicate event reports count once.
Unknown automation can contribute, so counts do not establish people, installations, quality, or safety.

The rolling window ends at the durable reporting watermark.
Coverage includes only configured Asm delivery sources, not unreported mirrors or legacy direct-origin requests.
Collection starts, downtime, and reporting failures cannot fabricate prior zero activity.
An incomplete window shows **≥** for a positive observed minimum.
Zero observed activity stays outside Popular and displays a collecting state when history is incomplete.

The local delivery adapter stores checked bytes under digest keys and sends files as attachments.
It records anonymous events without visitor identities, cookies, fingerprints, IP addresses, user-agent strings, or search terms.
A persistent event ledger supports replay, deduplication, restart, exact version totals, and coverage gaps.
A loopback projection refreshes independently of search; browser updates preserve focused controls.
Failed measurement must not block exact artifact delivery or silently fall back to GitHub counters.

New still shows **First GitHub release** for the retained legacy catalog.
Those historical availability dates are a separate adapter and never supply Popular's counts.
Authenticated registry publication events remain a separate architecture gate.
Imports must not invent earlier Asm admission dates.

The [discovery contract](docs/specs/discovery.md) records implemented events, transfer policy, coverage, recovery, and local commands.
The assembly application and qualified CDN/mirror ingestion remain production acceptance work.
This local adapter does not establish global traffic capacity or complete mirror coverage.
The [architecture](docs/architecture.md#query-and-ranking-semantics) and [acceptance gates](docs/architecture-gates.md) govern those qualifications.

Before shipping, test first-publication versus import dates.
Test lower-version maintenance releases, yanks, and window boundaries.
Test missing coverage and counter resets.
Test internal-traffic classification, deterministic ties, stale rebuilds, and recovery from retained events.
Check whether developers can find known packages, explore a task category, and distinguish Popular, New, and Updated.
Measure completed tasks and understanding rather than clicks or forced engagement.

Only name a sponsor when a real sponsorship record supports the claim.
A support link must describe the available route without implying a sponsorship relationship.

Give the footer a clear project column and four task groups: Learn, Registry, Project, and Help.
Use the shared neutral surface and a separate light support row.
Keep the left column to the wordmark and “A home for assembly.”
Omit the former “Open source. In alpha.” line.
Use twenty-four-pixel vertical padding and a four-pixel gap below navigation headings.
Use thirty-two-pixel footer link rows on desktop.
Retain forty-four-pixel link targets on narrow screens and devices with coarse pointers.
Use sixteen-pixel row gaps between stacked navigation groups.
Keep each link tied to an existing route or document.
Do not invent sponsors, authentication controls, legal pages, or service-status assurances.
Keep installation instructions in the GitHub README, reached directly from Install Asm.
Do not repeat the full installation and first-project section on the website.
Keep installation and quick-start links in the footer and documentation; omit the homepage setup strip.
Omit the closed installation strip and the slogan/license row below the footer.
Keep source and license information available through the project source and README.
Show supported hosts and prerequisites before installation commands and executable downloads.
Keep checked installer artifact generation independent of homepage markup.
Removing the installation section must not remove the checked `install.sh` artifact used by the README.
If a template supplies bootstrap markers, require one correctly ordered pair before inserting optional instructions.
Keep the source-build route and first-project workflow available without JavaScript.
Copy only the displayed commands, with no prompts or output.
Show observed output separately.

### Registry reference iteration, 7 November 2026

The owner supplied PyPI hero/statistics/footer screenshots and a crates.io discovery screenshot.
This pass initially adopted their clear full-width bands, compact discovery, start actions, and substantial grouped footer.
The later homepage simplification removes both the compact onboarding row and the full installation section.
It preserves Asm's compact prompt wordmark and explicit machine metadata.

The first reference pass used ink-blue framing and blue actions.
The neutral refinement below supersedes those palette choices.
The system sans-serif keeps prose readable; JetBrains Mono distinguishes versions, targets, dates, and code.
Controls use the existing six-pixel radius and 44-pixel minimum height.
The first pass used cards with six-pixel corners and quiet borders.
The later geometry refinement uses twelve-pixel discovery cards to match the search panel.

The statistics are registered packages, retained releases, release-file selections, and distinct package targets.
Derive them from the complete accepted catalog, independently of typed results or download reporting.
Published HTML supplies the values without JavaScript; accepted catalog refreshes update them.
Do not substitute physical digest-object totals for declared file selections or package targets for CLI host support.
At widths of 38.75 rem or less, show these four statistics in two equal columns and two rows.
Keep their order, left alignment, and shared row and column gaps; let labels wrap within each cell.

[PyPI's hero stylesheet](https://github.com/pypi/warehouse/blob/a7d67c06417ffeb18d6cb79b8c5caf9c69896b99/warehouse/static/sass/blocks/_homepage-banner.scss) and [statistics band](https://github.com/pypi/warehouse/blob/a7d67c06417ffeb18d6cb79b8c5caf9c69896b99/warehouse/static/sass/blocks/_statistics-bar.scss) inform the full-width composition.
[Crates.io's actions](https://github.com/rust-lang/crates.io/blob/35c0e8733f7be0dd031f670e3c139500e79a9e01/svelte/src/lib/components/frontpage/HeroButtons.svelte) and [discovery layout](https://github.com/rust-lang/crates.io/blob/35c0e8733f7be0dd031f670e3c139500e79a9e01/svelte/src/lib/components/frontpage/CrateLists.svelte) inform the useful middle.
[PyPI's footer](https://github.com/pypi/warehouse/blob/a7d67c06417ffeb18d6cb79b8c5caf9c69896b99/warehouse/static/sass/blocks/_footer.scss) informs grouped navigation and a distinct support area.
These references support an intentional layout; they do not establish measured Asm preference or comparative usability.

### Neutral refinement, 7 November 2026

The owner found the blue framing dated and requested a quieter assembly identity.
Use white content, `#f5f5f4` framing, `#181818` text and primary actions, and `#626262` secondary text.
Rules use `#e4e4e2`; essential control boundaries use `#858585`.
Keep red for explicit error states, with text that identifies the problem.
Code panels use charcoal and neutral highlights, without blue syntax accents.
The wordmark, icon, support badge, social preview, and browser theme follow this palette.

Search remains the focal control through width, placement, and contrast.
Keep the homepage heading at medium weight and give the search group more surrounding space.
Use a 70-rem maximum content width and the existing 48-rem search measure.
Use rounded discovery groups with quiet borders and compact package metadata.
Retain the factual stats band, three activity feeds, and grouped footer.
The package consumer still reaches complete metadata, targets, source, files, and evidence.

Retain six-pixel control corners, twelve-pixel panels, and the existing 4/8-pixel spacing basis.
Use 12/16 pixels within compact components and 24/32/48/64 pixels between larger groups.
Keep related labels and values closer than separate groups.
Do not force a golden ratio onto responsive columns or control dimensions.
[Carbon's spacing system](https://www.carbondesignsystem.com/building-blocks/foundations/spacing/overview) supports consistent tokens and grouping.
[NN/g's golden-ratio discussion](https://www.nngroup.com/articles/golden-ratio-ui-design/) treats the ratio as a reference with responsive constraints.
Neither source establishes an optimal ratio for Asm.

Monochrome must retain clear interaction cues before hover.
Underline package identities, version links, inline links, and standalone discovery actions.
Navigation remains grouped, with a visible current-page underline.
Buttons retain visible boundaries or a solid charcoal fill.
Keep neutral tap highlighting, pressed surfaces, and visible focus outlines on light and dark backgrounds.
Keep the existing minimum 44-pixel control height and text reflow rules.
[NN/g's interaction-cue experiment](https://www.nngroup.com/articles/flat-ui-less-attention-cause-uncertainty/) supports recognizable controls.
[WCAG contrast guidance](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html) distinguishes readable text from decorative separators.
These sources were reviewed on 7 November 2026.

This serves package consumers through clear tasks and inspectable information, following serve-the-person and dependable-reuse principles.
The trade-off is fewer color cues and no saturated brand surface.
Persistent link treatments, control shapes, hierarchy, and state feedback provide other cues.
The palette follows the owner's direction; it is not a measured usability improvement.
Browser checks must cover page families, search, focus, narrow screens, enlarged text, and unavailable data.
Keep comparative user preference and task testing separate from implementation checks.

### Discovery geometry refinement, 7 November 2026

The owner found the square discovery rows inconsistent with the rounded search panel.
Standalone package previews retain the shared twelve-pixel panel radius and quiet full border.
The homepage grouping refinement below supersedes the individual-card framing within activity groups.
Let target summaries wrap instead of hiding compatibility information.
Keep each target together when it fits; break a long target only when its own width requires it.
Stack the package name and activity signal when a preview is eighteen rem wide or narrower.
Use a soft hover surface and a stronger border on standalone previews.
Retain permanent package-name underlines, pressed feedback, and the shared keyboard focus outline.
Keep search visually dominant through its width and charcoal action.

This serves package consumers through coherent grouping and a clear selection area.
It follows the serve-the-person principle and preserves exact package identities and target metadata.
The trade-off is more framing and slightly less preview width than the open rows.
Check narrow screens, enlarged text, keyboard focus, and package navigation before accepting the change.

### Homepage hierarchy refinement, 7 November 2026

Keep the approved header, search hero, and catalog statistics.
Follow the statistics directly with New packages, Most downloaded, and Recently updated.
Omit the Build with Asm strip, purpose and architecture panels, Data and coverage disclosure, and More ways to explore row.
Keep installation and quick-start instructions in the footer and documentation.
Keep purpose, architecture, and methodology on the dedicated Explore and statistics pages.

Use a 24-pixel Browse packages heading, 16-pixel group headings, and the existing compact package type.
Give each activity list one twelve-pixel enclosing panel and a consistent header with its scope and View all link.
Use borderless package rows inside each panel, with rounded hover surfaces, underlined names, and visible keyboard focus.
Make each discovery heading the group's native destination link instead of adding a separate View all action.
Keep dates, exact targets, unavailable states, and incomplete-download explanations beside their data.
Do not add nested card borders or use explanatory text as a section separator.
Keep stale, failed, unavailable, and incomplete-data warnings visible.

This serves a package consumer who must identify the main action and distinguish the three discovery routes at a glance.
It follows serving the person and earning trust with evidence.
The trade-off is one navigation step to installation, additional browse routes, and detailed metric explanations.
[Krug's sample chapter](https://sensible.com/downloads/DMMT-Revisited-sample-chapter.pdf) supports clear choices.
NN/g's [proximity](https://www.nngroup.com/articles/gestalt-proximity/) and [common-region guidance](https://www.nngroup.com/articles/common-region/) support grouping related content.
These sources were checked on 7 November 2026.
The later removal follows owner feedback; it does not establish a measured usability improvement.
Check native links, search, keyboard use, narrow screens, enlarged text, and unavailable data.

### Public page addresses

Use `/` for home and extensionless page paths without trailing slashes, such as `/docs` and `/packages/stubbi/math`.
Keep generated directory routes internal to the build; export flat HTML aliases for the public addresses.
Resolve relative links against their original page before exporting root-relative page and asset links.
Update canonical metadata, sitemap locations, and clickable feed links.
Retain old page addresses as working aliases; preserve existing Atom entry identities.
Keep literal section fragments and private search/return fragments unchanged.
Use the human-readable architecture path `x86-64`, retaining underscore page addresses as aliases and `x86_64` in machine data.
JSON feeds, installer paths, source filenames, and artifact routes keep their existing addresses.
The local server must match the deployed host's flat-HTML lookup before directory redirects.
Verify exact-version paths containing dots and nested flat files beside same-name directories.

The user outcome is a consistent address after navigation without exposing implementation filenames.
This follows dependable reuse and serving the person.
The trade-off is retaining legacy HTML files alongside canonical exports for existing links.
[Jekyll 3.9.5's extensionless permalink documentation](https://raw.githubusercontent.com/jekyll/jekyll/v3.9.5/docs/_docs/permalinks.md) describes this GitHub Pages behavior.
Direct HTTP checks on 7 November 2026 confirmed flat HTML lookup before a same-name directory.
Verify the deployed addresses return HTML without a redirect; a cosmetic browser-history replacement is insufficient.

### Deeper discovery and maintained content, 7 November 2026

The owner added RubyGems to the reference set and requested richer exploration and automatic release news.
[RubyGems Explore](https://rubygems.org/explore) separates release, activity, and direct-dependency routes.
[RubyGems Stats](https://rubygems.org/stats) combines headline totals with a ranked download list.
[The crates.io summary implementation](https://github.com/rust-lang/crates.io/blob/35c0e8733f7be0dd031f670e3c139500e79a9e01/src/controllers/summary.rs) separates recent downloads, total downloads, keywords, and categories.
Its recent-download list ranks volume during a window, rather than showing individual transfer events.
These sources were checked on 7 November 2026; they inform the layout and definitions, not a usability claim.

Keep search first and use Explore for the additional routes.
Use explicit New, Most downloaded in the last thirty days, and Recently updated groups.
Rank categories and keywords by distinct active member packages.
Use only reviewed keyword metadata; do not extract popularity claims from prose.
Count direct dependents from distinct packages with declarations for their latest active release.
Bind each declaration to the exact release version and source commit.
Missing declarations remain unavailable; partial declarations establish only positive observed minima.
Neither download activity nor dependency count establishes quality or safety.

Stats uses registered packages, retained releases, and observed Asm transfers as its primary figures.
Keep file selections and explicit package targets available as secondary catalog facts.
Cumulative transfers start at the declared collection date; they do not include unknown earlier or external-host activity.
Keep cumulative coverage separate from the thirty-day window and show stale observations.
Use the existing daily chart and native data table for registry-wide activity.

Generate Blog entries from released changelog sections that match accepted Asm versions.
Exclude Unreleased text and keep exact release-specific dates separate from package-wide first and latest dates.
Use historical GitHub availability labels until authenticated Asm publication records supply the dates.
Authored articles live in `blog/posts/` as Markdown with a bounded TOML header.
Keep article sources outside `site/`, so drafts cannot leak through static asset copying.
The header supplies title, summary, author, draft state, and explicit publication and optional revision dates.
Use UTC calendar dates for authored articles; retain exact source-bound availability timestamps for releases.
Combine both types in the Blog, with separate Articles and Releases archives.
Distinguish Article and Release labels without creating a second visual system.
Show an article's title, summary, public author, and publication date before its body.
Keep long-form text within the existing reading measure and use the shared code and table treatments.
Generate one Atom feed from published, dated entries and keep undated releases readable in HTML.
Exclude drafts from the normal output, feed, and sitemap.
An explicit local preview flag can render labelled drafts with `noindex` metadata.
Do not turn local preview controls or authoring instructions into public reader flows.
The normal site build updates these pages without a separate content system.
Repository changes use the existing review and Pages workflow.
Reject unsafe or malformed sources before writing blog output; Markdown cannot execute templates or scripts.
Docs groups existing instructions by task and links their maintained source.

The user outcome is deeper package discovery and maintained project information without competing with the homepage search.
This follows serve-the-person, dependable-reuse, and evidence principles.
The trade-off is more secondary pages and explicit empty states when metadata is missing.
Validate rankings with real ledger fixtures, source-bound declarations, native navigation, narrow screens, and enlarged text.

Architecture is a separate discovery route and search filter.
Use ARM64 (aarch64), x86-64 (x86_64), and RISC-V64 (riscv64) for the accepted version-one target profiles.
Map only the explicit accepted target profiles; do not guess architecture from arbitrary target prefixes.
Count each package once per architecture in its latest active release.
Exclude historical-only and yanked releases from current architecture discovery.
Keep native architecture directories available without JavaScript or download measurements.
Show matching exact targets on architecture pages and retain the selected architecture when refining a search.
Keep architecture browsing on Explore and in the search and package-file filters.
Use the same Format, Architecture, Target order in search and package file filters.
Unknown or unavailable architecture selections need an empty state with a clear recovery action.
Architecture does not establish operating system, ABI, CPU feature, or CLI host compatibility.
Keep those requirements in the exact release record and its documentation.
The user outcome is finding relevant assembly packages without treating architecture alone as a compatibility guarantee.
This follows dependable reuse and evidence; validate mixed filters, return navigation, native routes, and mobile reflow.

### Counts and the GitHub link, 7 November 2026

Use one compact count convention across stars, downloads, catalog totals, and discovery lists.
Follow [GitHub's deployed counter](https://github.githubassets.com/assets/code-view-5d65cb0f8c6bfda9.js), reviewed on 7 November 2026: `1.2k`, `1.2M`, and `1.2B`.
Use one decimal below 100k and 100M; use whole units between 100k–1M and 100M–1B.
Select the unit before rounding, as GitHub does; trim a trailing decimal zero.
Extend the same convention with T and Q within the supported safe-integer range.
These extensions are Asm decisions, not observed GitHub repository counts.
Retain exact counts in titles, accessible text, and daily data tables.
Keep dates, versions, byte sizes, digests, and machine-readable values unchanged.
Round observed lower bounds downward and retain ≥, so a compact label cannot overstate the minimum.
Unknown counts remain unavailable; they never become zero.

Keep Star on GitHub separate from the four product navigation links.
Use the shared control border, corner radius, minimum height, and focus treatment.
The native link opens the repository; it does not star the project automatically.
Use GitHub's canonical repository response as the star-count source.
Keep observations for less than five minutes; accept decreases and a measured zero.
The server refreshes independently of visits and wakes when an existing observation expires.
Keep its private cache outside the published site.
HTML contains the repository link without a number, so cached markup cannot freeze an old count.
Every page loads the same small enhancement and first requests the first-party GitHub snapshot.
If that observation is unavailable or expired, request the fixed public GitHub repository API.
This browser fallback lets static Pages update independently of deployments.
Use no credentials, token, cookies, referrer, search terms, page paths, or application-added identifiers in that request.
GitHub receives the network address and standard browser metadata, including the site origin.
This request is for the displayed public count, not analytics.
Store the public observation and a bounded retry deadline in session storage; reuse both across page navigation.
Refresh visible pages when the observation expires; check again when the visitor returns or uses browser Back.
Do not poll hidden pages or overlap requests.
Bound response size and request time; preserve normal page use when requests fail.
Honor valid GitHub rate-limit deadlines up to twenty-four hours; use a five-minute delay for other failures.
Hide expired or unavailable numbers while retaining the Star on GitHub link.
Keep exact counts and observation times in accessible text and the link title.

Five minutes is the local freshness limit, not a promise of instant equality with GitHub's page.
Upstream caching, network errors, and API rate limits can prevent a current observation.
In those cases, show the link without a number rather than present an old value as current.
The [GitHub repository API](https://docs.github.com/en/rest/repos/repos#get-a-repository) supplies `stargazers_count`.
Its [rate-limit documentation](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api) defines the unauthenticated quota.
These sources were checked on 7 November 2026.

This serves readable discovery and consistent navigation through minimalism and evidence.
The trade-off is a short cache and a direct public API request on static hosting when no fresh first-party observation exists.
Validate count boundaries, freshness, decreases, expired caches, failed refreshes, native links, keyboard focus, and narrow screens.

## Package pages

The package browser provides these routes:

| Route | Purpose |
| --- | --- |
| `/packages` | Complete catalog with ordinary package links |
| `/packages/owner` | Packages in a declared namespace |
| `/packages/owner/name` | Latest active release and complete history |
| `/packages/owner/name/version` | Exact release and its recorded metadata |
| `/404` | Missing-page recovery |

Keep `404.html` as the static host's error-page file.
Generate these pages from validated release records during the atomic site build.
Keep the current registry schema and raw JSON routes.
Every page uses the shared header, footer, type, spacing, color, focus, and control tokens.
Package content remains available without JavaScript.
Scripts add artifact filtering, copying, and return links to a local search.

Show package identity, exact version, release summary, license, and active or yanked state first.
Use the exact release record for its summary, source, and license.
Package-level values can describe a later release and must not replace historical values.
Derive a selected release's targets and formats from its own artifacts.
Sort history by numeric version and link every retained release.
An all-yanked package has no active release; its overview still provides history.

Separate Use, Readme, Files, Evidence, Versions, and Downloads with ordinary section links.
Keep the readme, usage, and release content in the main column, with source facts beside it on wide screens.
Keep usage prerequisites before the files on every screen size.
Stack the content on narrow screens.
Let code and wide tables scroll inside their containers, with keyboard access.
Wrap long identities, filenames, digests, and source paths.

Each artifact shows its target, kind, filename, byte size, complete SHA-256 digest, and declared URL.
Provide a raw download link only when the site build checked that release's artifact bytes.
Keep unperformed checks explicit and distinct from successful checks.
Explain that a digest match establishes neither publisher identity nor general safety.
Optional download counters retain their scope, observation time, and unavailable state.
An exact-version page must not substitute a package-wide counter for its release counter.

Usage commands select an exact version, target, and artifact kind.
The initial command downloads and checks bytes without extracting, installing, or running package contents.
Show installation prerequisites before the command.
Do not imply that a declared package target is a native CLI host.
The Asm CLI package links to its official installation flow, which may install a different current version.
Yanked pages retain inspection metadata and the reason, but omit new CLI selection commands.

Show a readme only from the declared repository, source commit, and source directory.
Choose the first available root file in this order: `README.md`, `README`, and `README.txt`.
Retain release commit history in the deployment checkout so these source snapshots remain available.
Label this as a source snapshot, separately from artifact verification.
Never substitute the working tree or choose an arbitrary nested readme.
Give active package overviews native category, keyword, and architecture links in the existing source sidebar.
Label these as current package classification; omit them from exact historical release pages.
Keep structured source metadata bound to the selected record's version, license, repository, and exact source commit.
Keep target-specific dependency declarations with their checked source artifact rather than flattening them into package-wide requirements.
Missing commits, external repositories, absent files, invalid UTF-8, and oversized text produce useful documentation fallbacks.
The rest of the release page remains available.
Bound readme input and render only the supported Markdown subset.
Escape source HTML, reject executable link schemes, and avoid automatic remote images.
Only balanced, attribute-free details and summary syntax receives the tested native disclosure treatment.
Group README headings into labelled sections while preserving their text and anchor identities.
Use recorded-commit links for relative documentation references.

Namespace prefixes are not authenticated publisher profiles.
Do not invent maintainers, publication dates, dependencies, ABI declarations, CPU requirements, ratings, or evidence reports.
Link to package documentation where the current record lacks structured requirements.
Do not add account, ownership, or publication controls before their backend contracts exist.

Acceptance covers discovery, permanent links, exact historical metadata, target/format filtering, copying, history, and recovery.
Test malformed search links, unsafe readmes, unknown versions, missing documentation, no active releases, yanked releases, and unavailable counters.
Run `make site-test` and check the full flow through the browser.

### Package and results refinement, 7 November 2026

The consumer needs to compare compatibility, select exact bytes, and inspect supporting information.
Keep search rows compact: identity, active version, purpose, license, and valid format/target pairs.
Derive those pairs from the latest active release, not a union across historical releases.
An executable target must not imply that a source archive exists for the same target.
Format and target filters must match one artifact in that release.
Retain packages without active releases in unfiltered browsing, with their state explicit.
Do not infer a release publication date from package-wide activity dates.

Results use a compact search band without the homepage totals and onboarding row.
Keep the search field in place while the visitor types on the homepage.
Enter the compact layout after submission, filter selection, or restoration of a saved search.
Filters precede results and stack when their controls need more width.
Package identities and exact version links keep visible link cues.
Long descriptions, license names, and machine targets wrap within the result.

Package details lead with identity, state, purpose, version, license, formats, and declared release targets.
Place Use before the readme on every screen.
Show an exact fetch command when one artifact remains after explicit filtering.
With several artifacts, require selection before showing a quick command.
Keep individual file commands available without scripts.
Hide unnecessary filters for one file unless a return-state filter requires recovery.
Source and package publication facts remain secondary to the task.
Label first/latest GitHub availability as package-wide history, not the selected release's publication date.
Keep full file digests, exact source commits, yanked history, and evidence limits inspectable.

The [crates.io page implementation](https://github.com/rust-lang/crates.io/blob/35c0e8733f7be0dd031f670e3c139500e79a9e01/svelte/src/lib/components/CrateVersionPage.svelte) separates broad documentation from installation and metadata.
[PyPI's Requests page](https://pypi.org/project/requests/) supplies source, requirements, release history, and exact file facts.
[npm's version-count announcement](https://github.blog/changelog/2021-01-27-npmjs-com-displays-per-version-download-counts/) distinguishes version-level activity from package totals.
Reviewed on 7 November 2026, these references inform hierarchy without establishing an optimum for Asm.
Direct npm page fetching returned HTTP 403; its indexed page and official documentation supplied the comparison.

Download activity is secondary, with package-wide and exact-version views kept distinct.
Use daily columns for the same rolling 30-day window as Popular.
Keep the zero baseline and integer scale; never join gaps with an interpolated line.
Clip UTC date bins at both window boundaries; a rolling 30-day period can intersect 31 dates.
Show a collecting state when history is too limited for a meaningful chart.
Preserve unknown, partial observed minimum, fully observed zero, and stale states.
Supply a visible summary, reporting cutoff, coverage explanation, and native daily values table.
Keep chart axis labels outside the scaled graphic so they remain legible on mobile.
[ONS chart guidance](https://service-manual.ons.gov.uk/data-visualisation/chart-types/line-chart) supports visible missing-data gaps.
[W3C complex-image guidance](https://www.w3.org/WAI/tutorials/images/complex/) supports text and detailed data alternatives.
These sources were reviewed on 7 November 2026.

This applies serve-the-person, evidence, and dependable-reuse principles.
The trade-off is additional selection controls for genuinely different artifacts and a secondary activity section.
It avoids treating sparse history as adoption evidence or making metadata compete with use.
Validate exact commands, unsupported combinations, historical releases, mobile reflow, keyboard use, and no-script fallback.
Chart checks must reconcile totals, clipped periods, gaps, true zero, and exact-version scope.
Implementation checks do not establish comparative user preference or universal usability.

## Companion guide

[`site/guide.html`](site/guide.html) contains the detailed package walkthrough, target model, evidence model, motivation, and roadmap.
It links to the homepage for installation and catalog search.
Keep the homepage focused while preserving the instructions and evidence that help a reader assess a package.

The walkthrough has three selectable stages: Find, Inspect, and Use.
Keep the package identity, version, and target visible beside horizontal tabs.
Use standard tab semantics, arrow keys, Home, End, and visible keyboard focus.
Keep tab labels short; omit numbered labels and descriptive subtitles.

Keep the controls visible when the reader switches tabs.
Let the stage grow when enlarged text requires space.
Do not clip content or add a scrolling stage.
On narrow screens, stack the stage contents and allow longer content to grow.
Long commands can scroll within their own containers.
The page must not scroll horizontally.
Hide the optional source excerpt in narrow Use panels.
Keep the complete program available below the walkthrough.

The example uses the published `stubbi/math@0.4.0` source package for Linux x86-64.
Four instructions let a visitor understand the complete function before using it.
The package record shows one selected release, not literal CLI output.
State the function contract directly.
Do not add slogans or unsupported safety claims around the example.
Keep the recorded sample values in Use and the editable instruction model.
Do not repeat the calculation in Find.

[`site/package-demo.js`](site/package-demo.js) supplies tabs and an unsigned 64-bit instruction model.
The model uses exact integer arithmetic, validates input, and clears stale register values after errors.
Show the current instruction, registers, and explanation without a duplicate result card.
Keep the step action label stable until the function returns.
Label it as a model; it does not run native assembly in the browser.
The Use stage shows a separate recorded command sequence with fixed inputs of 12 and 37.
Show the required source replacement before the run commands.
Make the full source available to copy and download, with its complete MIT notice.
Keep the full source disclosure below the walkthrough, so opening it does not resize the tab stage.

[`site/demo/README.md`](site/demo/README.md) explains the recording and its limits.
The recording binds the published CLI, source archive, source commit, and consumer source to exact digests.
It includes successful execution, source-tamper rejection, and unsupported-target rejection in an isolated Linux guest.
Keep the failed harness attempt and metadata annotation beside the final recording.
Do not treat the recording as a benchmark, proof, or claim of universal host support.
Tests bind the copied source and package identity to this evidence.

Without JavaScript, show the Find stage, source links, and recording link.
Hide controls that cannot work.
Use a short stage transition and honor reduced-motion preferences.
Do not add autoplay, typewriter effects, decorative animation, or pointer parallax.

## Visual tokens

[`site/styles.css`](site/styles.css) is the source for palette, spacing, and layout values.
Add tokens there before adding repeated hard-coded colors.
Use `--paper` and `--surface` for page and grouped surfaces.
Use `--ink` and `--muted` for primary and secondary text.
Use `--rule` and `--rule-strong` for separators and control boundaries.
Use `--accent` and `--accent-hover` for actions and selected states.

Use one global system font for prose and JetBrains Mono for technical values.
Do not redefine the palette or font families inside page sections.
Use 6-pixel control corners and 12-pixel panel corners at the default text size.
The search panel has a 6-pixel inset, so its inner button follows the same corner geometry.
Use the 4, 8, 12, 16, 24, 32, 48, 64, and 96-pixel spacing scale.
Use relative units so spacing and controls grow with the text size.
Use the same container, header, navigation, control borders, and focus treatment on every page.
This includes the homepage, package browser, guide, sponsorship page, and generated CLI source reference.
Keep Explore, Stats, Blog, and Docs in the same navigation order.
The wordmark returns to search; installation remains in the footer and documentation.
Mark the current page with a selected surface, stronger text, and `aria-current`.
Keep the same Learn, Registry, Project, and Help link groups and support row in every footer.
Keep four Help rows: issue reporting, security, contact, and privacy.
Contribution remains in the support row; supported hosts remain in Docs and the installation instructions.
The Source code footer link retains the GitHub route while Packages provides explicit return navigation.

Use the shared type tokens for metadata, body text, controls, titles, and page and section headings.
Technical metadata uses 13-pixel text; ordinary controls and supporting text use 14-pixel text.
Body text uses 16-pixel text at the default text size.
The homepage heading establishes the task; the wide light search control remains the focal action.
Funding figures describe data; they do not introduce a separate display typeface.

Let footer links, walkthrough tabs, form fields, and register values wrap when their content needs more space.
Keep footer navigation in its own grid so unused tracks can collapse.
Use inset focus outlines inside code panels with clipped corners.
Make scrollable code reachable by keyboard.
Keep unavailable actions visually stable on hover.
Use the same outlined wordmark and palette in social previews and the support badge.
Keep essential control borders distinct from decorative separators.
Use a minimum 44-pixel control height at the default text size.
Desktop footer text links use the compact rows defined above; narrow screens and coarse pointers retain 44-pixel targets.
Let navigation and footer links wrap instead of hiding them.
Let paragraphs follow document flow; never position separate paragraphs in the same grid cell.
Use bounded grid tracks and wrap long package metadata.
Reflow below 860, 700, 620, and 380 pixels as content requires.
Check both sides of each breakpoint, expanded content, and enlarged text.
These checks cover stated viewports and states; they cannot establish correctness for every possible screen.

Check text contrast for the actual foreground and background.
Decorative rules may be quiet.
Essential control boundaries need sufficient contrast.
Color alone must never explain status.

Use one main heading per page.
Display text must wrap without clipping.
Body copy should normally be 14–16 pixels.
Use smaller type only for short supporting metadata.
Avoid long passages of uppercase text.
Use sentence case for navigation, buttons, headings, and messages.
A border can group related data without making every item a card.
Avoid cosmetic shadows on interface elements.

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
Search includes the latest active license and reviewed current keywords and categories.
Optional topic data must not block base search or replace a focused control.
Identify incomplete topic coverage when a source fails.
Local search titles describe the current view without changing canonical or social metadata.

`registry/v1/downloads.json` contains Asm-owned delivery observations with their cutoff and coverage.
A missing count is unavailable; an observed zero applies only to its stated coverage.
Do not infer installations, unique people, or active users from completed transfers.
GitHub download counters never supply Popular or its fallback.

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

## Sponsorship

The sponsorship page uses the shared palette with a separate, scoped stylesheet.
It keeps tiers, prices, limits, agreement terms, and contact routes available without JavaScript.
Display the USD 100,000 monthly goal as a target, never as funds raised.
Confirm limited-tier availability before an agreement; do not infer it from public logos.
Show real payment links only after the corresponding provider listing is active.
Keep a visible email address beside the enquiry route.
Only confirmed sponsors with recognition consent can appear in sponsor placements.
Keep paid recognition separate from package ranking and release evidence.

## Verification before publication

Check the claims against the current executable, `cli/commands.json`, release records, and specifications. Test the documented command sequence on the supported host. Do not carry forward an old success message after the implementation changes.

Check every HTML page in a browser at desktop and small-screen widths. Check keyboard navigation, search, filtering, disclosure controls, empty results, unavailable registry data, copy feedback, and download links. Record a blocked check accurately. Static checks do not establish that a page was visually reviewed.

Include checked and trusted installer markup when those variants are affected.
Use isolated, labeled fixtures for unavailable services, denied clipboard access, maximum metadata, enlarged text, and script-free content.
Fixtures do not establish release integrity or cryptographic qualification.
Check rendered text contrast, control sizes, wrapping, and focus rather than relying only on page overflow.
Retain structural checks for shared navigation, local links, landmarks, labels, and copy targets.

Check discovery actions and unique package counts.
Check that combined format and target filters match the same artifact.
Check All packages and Back to browse with keyboard navigation.

Use targeted automated checks for risky behavior: untrusted descriptions, invalid URLs, unsupported index versions, missing counters, and mismatched digests. Do not add a large UI test framework solely to assert static marketing copy.

Keep the site small. No framework, font service, analytics tracker, or third-party script is required for this release. Measure page weight before adding one. The site should serve the user's task even on a slow connection.
