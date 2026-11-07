# Search indexing

Asm publishes a [sitemap](https://asm.build/sitemap.xml) and [crawl rules](https://asm.build/robots.txt).
The sitemap contained 60 unique HTML page URLs when checked on 7 November 2026.
It includes packages, exact versions, documentation, blog releases, Explore, statistics, browse directories, sponsorship, and the CLI source reference.
Each page declares its preferred URL with a canonical link.
Public page URLs have no extension or trailing slash; the homepage uses `/`.
Existing page addresses remain working aliases.

These files help search engines discover the site.
They do not confirm submission, crawling, or indexing.
Search engines decide which pages to index.
See the [Google technical requirements](https://developers.google.com/search/docs/essentials/technical).

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
Examples include `Installation and package documentation | Asm`, `stubbi/math | Asm`, and `stubbi/math@0.6.0 | Asm`.
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
