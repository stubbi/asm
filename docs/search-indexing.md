# Search indexing

Asm publishes a [sitemap](https://asm.build/sitemap.xml) and [crawl rules](https://asm.build/robots.txt).
The sitemap contains 63 unique HTML page URLs after the 8 November 2026 audit changes.
It includes packages, exact versions, documentation, blog releases, Explore, statistics, browse directories, sponsorship, and the CLI source reference.
Each page declares its preferred URL with a canonical link.
Public page URLs have no extension or trailing slash; the homepage uses `/`.
Existing page addresses remain working aliases.

These files help search engines discover the site.
They do not confirm submission, crawling, or indexing.
Search engines decide which pages to index.
See the [Google technical requirements](https://developers.google.com/search/docs/essentials/technical).

## Audit findings and useful fixes

The 8 November review uses Squirrelscan 0.0.172 with a fresh, full, offline crawl.
Keep the original report and failed checks beside subsequent results.
Its warning count includes repeated checks across pages, rather than distinct defects.
Do not disable checks or change the crawl scope to imply an improvement.

Give titles useful package, version, and task context.
Keep descriptions concise without removing exact release facts from the page or its structured data.
Use destination-specific link names and native links in discovery headings.
Keep informational project, contact, and privacy pages separate from the search task.
The footer links to them without adding navigation rows.

Render only the explicitly supported, attribute-free README disclosure syntax.
Other source HTML remains escaped.
Group recorded README sections by their headings without editing published source bytes.
Describe actual technical documentation with article metadata while retaining each package's separate source identity.
Do not invent publication dates or authors for these source snapshots.

The build minifies first-party scripts with the pinned, vendored Terser browser bundle and Node.js.
Readable sources, upstream notices, and its license remain available in the repository.
Node.js 18 or later is already required by the site gate and is also required for standalone site builds.
No npm installation or build-time network request is needed.
The site gate exercises the shipped minified scripts through the existing behavior tests.

Short directories and technical identifiers do not become defects solely through word-count or keyword-density thresholds.
Google specifies no preferred word count, fixed title maximum, or fixed description maximum.
Keep useful content instead of adding filler for those thresholds.
See [people-first content](https://developers.google.com/search/docs/fundamentals/creating-helpful-content),
[title links](https://developers.google.com/search/docs/appearance/title-link), and
[snippets](https://developers.google.com/search/docs/appearance/snippet), reviewed on 8 November 2026.

The public architecture page uses `/browse/architectures/x86-64`.
Its earlier underscore addresses remain working aliases.
Registry identifiers, targets, filters, and private search fragments retain literal `x86_64` values.

### Schema review, 8 November 2026

Squirrelscan reports eight failed page checks, with ten underlying complaints.
Seven expect article metadata on `/docs`, `/reference`, and `stubbi/hello` versions `0.1.0` through `0.5.0`.
One guide check groups missing `author`, `datePublished`, and `image` fields.

Docs and the source-file index are collections, not articles.
Their `ItemList` metadata describes the same links, names, and order as the visible pages.
The source index records its exact commit and each file's actual URL and SHA-256 digest.
It uses `MediaObject`, which supports `contentUrl` and `sha256`, without inferring file authorship or license.
The guide keeps its `TechArticle` type and a stable entity identifier.

The five historical Hello source paths contain no root README.
Keep their exact source metadata and unavailable-documentation state instead of substituting newer or nested documentation.
Git commit authors and timestamps do not establish a guide's byline or public publication date.
The shared social image represents package search, not the guide's technical walkthrough.

Google's Article guidance specifies no required properties and recommends applicable facts.
Keep unsupported values absent and preserve the raw scanner findings.
See [Article guidance](https://developers.google.com/search/docs/appearance/structured-data/article),
[CollectionPage](https://schema.org/CollectionPage), [ItemList](https://schema.org/ItemList), and
[sha256](https://schema.org/sha256), reviewed on 8 November 2026.

## Page intent and keyword hypotheses

These phrases describe existing registry and CLI tasks.
They are hypotheses about search intent, not measured keyword demand or ranking targets.
No keyword volume estimates or Search Console performance data were available for this review.

| Search intent or phrase | Existing destination | Reason |
| --- | --- | --- |
| assembly packages; assembly package registry; assembly package manager | [Homepage](https://asm.build/) | Find assembly packages and identify the registry and CLI. |
| browse assembly packages; assembly package catalog | [All packages](https://asm.build/packages), [Explore](https://asm.build/explore) | Inspect the catalog through native package links and declared metadata. |
| Asm documentation; install Asm; assembly CLI installation | [Documentation](https://asm.build/docs#docs-start) | Reach maintained installation instructions, prerequisites, and current host support. |
| use an assembly package; Asm package targets and evidence | [Guide](https://asm.build/guide) | Follow the package walkthrough and inspect the scope of its evidence. |
| ARM64 assembly packages; x86-64 assembly packages; RISC-V64 assembly packages | [Architectures](https://asm.build/browse/architectures) and its existing architecture pages | Select active artifacts through explicit target mappings. Architecture alone does not establish operating system or ABI compatibility. |
| stubbi/math; stubbi/math 0.6.0 | [Package](https://asm.build/packages/stubbi/math), [exact version](https://asm.build/packages/stubbi/math/0.6.0) | Inspect a known package or one immutable release. |
| Asm releases; Asm 0.6.0 release notes | [Release archive](https://asm.build/blog/releases), [release notes](https://asm.build/blog/releases/0.6.0) | Read the published CLI changes and their limits. |

The package terms follow the current product description: a registry and command-line tool for assembly projects.
Architecture phrases follow accepted target metadata, not inferred visitor hardware.
Exact package phrases follow registered identities and retained versions.

Keep each intent tied to useful content that already exists.
Do not create duplicate landing pages for spelling variants.
Do not pad text to meet a word count.
Do not describe Asm as an AI compiler or promise general safety, performance, or global distribution capacity.
Keep missing download observations distinct from zero.
Popularity does not establish safety.

## Titles, descriptions, and the site name

Use a concise title for each page with the suffix ` | Asm`.
Examples include `Installation and package documentation | Asm`, `stubbi/math assembly package | Asm`, and `stubbi/math@0.6.0 assembly package | Asm`.
Keep package identity and exact version visible in titles for version pages.
Keep titles, main headings, and social metadata consistent with the page's content.
Do not repeat keyword variants or the full product description in every title.
Google can choose a different title link from page content and other signals.
See [Google's title-link guidance](https://developers.google.com/search/docs/appearance/title-link).

Write a relevant description for each page's purpose.
Keep package and exact-version descriptions distinct, using only their declared metadata.
Google can generate different snippets for each query from visible content instead of the supplied description.
See [Google's snippet guidance](https://developers.google.com/search/docs/appearance/snippet).

Use **Asm** for the prose brand and preferred site name.
Keep **asm** lowercase in the wordmark, command, and website address.
Set the homepage's `WebSite` name to `Asm` and its URL to `https://asm.build/`.
Keep `og:site_name` consistent with that name.
These fields express a preference; Google selects the displayed site name automatically.
See [Google's site-name guidance](https://developers.google.com/search/docs/appearance/site-names).

Package breadcrumbs describe the visible catalog, namespace, package, and selected version hierarchy.
Their structured data uses the same native links and clean public routes.
Search state is a return action, not a parent category.
See [Google's breadcrumb guidance](https://developers.google.com/search/docs/appearance/structured-data/breadcrumb).

These primary Google documents were reviewed on 7 November 2026.
This audit covers page intent, metadata, and crawlable links.
It does not establish indexing, impressions, clicks, or improved rankings.

## Package and publication metadata

| Information | Representation and scope |
| --- | --- |
| Package source | `SoftwareSourceCode` identifies the selected exact version, summary, repository, commit-specific source URL, and license document. |
| Version identity | Overview and exact-version pages refer to the same clean version entity. An overview without an active release omits that entity. |
| License | Use the selected record's approved SPDX identifier. A package license does not license the surrounding website. |
| Complete release metadata | A typed `describedby` link points to the exact raw JSON record. Published record bytes remain unchanged. |
| Targets and files | Keep target, architecture, format, size, digest, and checked download availability together for each artifact. |
| Dependencies and features | Keep declarations bound to the checked source archive, digest, version, and target. Missing declarations remain unavailable. |
| Categories and keywords | Link the active overview to its current native discovery pages. Current classification does not relabel historical releases. |
| Authored articles | `BlogPosting` uses the visible headline, summary, literal credits, and declared calendar dates. Drafts and previews omit this markup. |
| Release notes | Keep GitHub availability dates distinct from article publication dates. Do not invent an author, publisher, or date. |
| Shared previews and feeds | Declare the actual PNG type, dimensions, and alternative text. Expose the existing Atom feed through a typed alternate link. |

The source schema describes recorded code; it does not establish publisher identity, compatibility, safety, or Google rich-result eligibility.
Omit programming-language, ABI, CPU-feature, rating, and offer claims when the record does not establish them.
Do not turn source archives or libraries into applications to satisfy a scanner.
See [SoftwareSourceCode](https://schema.org/SoftwareSourceCode), [license](https://schema.org/license), and [Google's supported structured-data features](https://developers.google.com/search/docs/appearance/structured-data/search-gallery).

Use a bounded JSON serializer for structured data.
Escape script delimiters inside JSON strings before embedding them in HTML.
Test hostile metadata as well as exact historical licenses and missing data.
See [HTML script-content restrictions](https://html.spec.whatwg.org/multipage/scripting.html#restrictions-for-contents-of-script-elements).

## Search, filters, and indexing

Typed queries and filter combinations use local URL fragments.
They are not separate pages in the sitemap or separate indexing targets.
Search terms stay outside request paths, canonical URLs, and social-preview metadata.
The client changes its bounded tab title to describe search, filter, and return states.
That title helps navigation; it does not make a query a new indexed page.

Local search matches package identity, summary, declared targets, architecture aliases, and the latest active release's license.
Reviewed current keywords and category names extend those matches after the base catalog loads.
These optional sources use fixed addresses, bounded reads, and timeouts.
A missing or invalid source leaves base search available and identifies incomplete topic coverage.
Historical licenses and stale classifications do not describe the current release.

The catalog, package versions, categories, keywords, and architecture directories supply native crawlable links and static content.
Keep these useful entry points available without scripts.
Keep legacy HTML aliases crawlable so search engines can read their clean canonical links.
Do not put transient searches in the sitemap or add `noindex` to the canonical homepage when someone searches.

Google supports fragment filters when separate facet indexing is unnecessary.
Its sitelinks search box was retired in November 2024.
Do not invent a public query endpoint or `SearchAction` for that retired feature.
See [faceted navigation](https://developers.google.com/crawling/docs/faceted-navigation), [canonical consolidation](https://developers.google.com/search/docs/crawling-indexing/consolidate-duplicate-urls), and the [search-box announcement](https://developers.google.com/search/blog/2024/10/sitelinks-search-box).
These sources and Schema.org 30.1 were reviewed on 7 November 2026.

## Before submission

1. Confirm that the intended Pages deployment succeeded.
2. Check the deployed commit in [build.json](https://asm.build/build.json).
3. Fetch each sitemap URL without an account.
4. Confirm that each page returns HTTP 200 without a redirect.
5. Confirm that each canonical link matches its sitemap URL.
6. Check the crawl rules for an unintended restriction.

## Google Search Console

1. Verify ownership of `asm.build` in Search Console.
2. Use live URL inspection for `https://asm.build/`.
3. If the page is eligible, request indexing.
4. Submit `https://asm.build/sitemap.xml` in the Sitemaps report.
5. Record the submission result and any reported error.

Follow the [sitemap submission guide](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap).
The old sitemap ping endpoint is retired.
Do not use it.

## Bing Webmaster Tools

1. Add and verify `https://asm.build/` in Bing Webmaster Tools.
2. Submit `https://asm.build/sitemap.xml`.
3. Inspect the homepage URL.
4. Record the submission result and any reported error.

Bing also supports import from a verified Search Console property.
That option requires permission to read the Search Console account.
See the [Bing verification guide](https://www2.bing.com/webmasters/help/add-and-verify-site-12184f8b).

## IndexNow

IndexNow notifies participating search engines about changed URLs.
Its ownership file is [site/1a9602d99aec90009cd0b4c3c74c45fa.txt](../site/1a9602d99aec90009cd0b4c3c74c45fa.txt).
The file contains a random public verification key.
It is not an account credential.
The filename and file contents must identify the same key.

1. Fetch the deployed ownership file from the site root.
2. Compare its bytes with the repository file.
3. Submit only added, changed, or deleted URLs from this host.
4. Record the response and submission time.

HTTP 200 confirms receipt of the submission.
HTTP 202 means that key validation remains pending.
Neither response confirms indexing.
Participating search engines share submitted URLs.
Follow the [IndexNow protocol](https://www.indexnow.org/documentation).

## Maintain the sitemap

Add a page only after its public HTML URL exists.
Use the preferred HTTPS URL.
Keep duplicate routes and URL fragments out of the sitemap.
Add `lastmod` only when it reflects a known content change.
Do not reset it for every deployment.
