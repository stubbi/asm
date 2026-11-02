# Search indexing

asm publishes a [sitemap](https://asm.build/sitemap.xml) and [crawl rules](https://asm.build/robots.txt).
The sitemap lists the homepage and CLI source reference.
Each page declares its preferred URL with a canonical link.
The catalog has no separate HTML package pages yet.

These files help search engines discover the site.
They do not confirm submission, crawling, or indexing.
Search engines decide which pages to index.
See the [Google technical requirements](https://developers.google.com/search/docs/essentials/technical).

## Before submission

1. Confirm that the intended Pages deployment succeeded.
2. Check the deployed commit in [build.json](https://asm.build/build.json).
3. Fetch each sitemap URL without an account.
4. Confirm that each page returns HTTP 200.
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
