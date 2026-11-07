# Write an Asm blog post

The blog combines authored articles and automatic release notes.
Article sources live in `blog/posts/`, outside the public website source.
The normal site build generates their pages, archives, and Atom feed.
No separate content service is required.

## Create a draft

1. Copy `blog/posts/why-asm.md` to `blog/posts/your-post-name.md`.
2. Use lowercase letters, numbers, and single hyphens in the filename.
3. Start the filename with a letter.
4. Edit the title, summary, and author fields.
5. Keep `draft = true` while you write.
6. Replace the article body with your Markdown.

Each file starts with a TOML header between `+++` lines:

```toml
+++
title = "Your article title"
summary = "A short description of the article."
author = "Your public author name"
draft = true
+++
```

The title, summary, author, and draft fields are required.
Published articles also require a `date` field.
Dates use the UTC calendar and remain explicit editorial metadata.
For example, `date = 2026-11-07` means 7 November 2026.
The optional `updated` field records a later revision date.
Published dates cannot be in the future.
The Atom feed represents each calendar date at midnight UTC.

The article page supplies its main heading.
Start body sections with `##`.
The renderer supports paragraphs, headings, lists, code blocks, tables, emphasis, and HTTPS links.
Raw HTML, embedded scripts, and images do not become active page content.
Use complete HTTPS addresses for website links.
Relative links open source files under `blog/posts/` on GitHub.
Imports, templates, and executable content are unsupported.

The build rejects invalid metadata, duplicate fields, unsafe paths, oversized posts, and unsupported characters.
Content uses the repository's [license scope](../README.md#license).
Write claims from the [brand foundation](../docs/brand/foundation.md) and [messaging guide](../docs/brand/messaging.md).
Check current capability claims against the implementation and recorded evidence.

## Preview a draft locally

1. Run this command from the repository root:

```sh
python3 tools/build_site.py --output build/blog-preview --include-blog-drafts
```

2. Serve the preview:

```sh
python3 -m http.server 8766 --bind 127.0.0.1 --directory build/blog-preview
```

3. Open <http://127.0.0.1:8766/blog/>.
4. Check the article on a narrow screen.
5. Check its links, author, summary, headings, and dates.

Use a new output directory for each build.
The preview labels drafts and adds `noindex` metadata.
Drafts stay outside the Atom feed and sitemap.
A normal build omits draft pages and their source files.
Draft files remain visible in the GitHub repository.
The draft setting controls website output, not repository visibility.
The preview flag belongs only in local preview commands.

## Publish an article

1. Add the actual publication date, such as `date = 2026-11-07`.
2. Set `draft = false`.
3. Run `make site-test`.
4. Review the source and local preview through a pull request.
5. Merge the approved change into `main`.

The existing Pages workflow builds and publishes changes pushed to `main`.
An article at `blog/posts/your-post-name.md` becomes `/blog/articles/your-post-name/`.
Keep its filename stable after publication to preserve links.
For a later revision, keep `date` and set `updated` to the revision date.
The author field becomes a public byline.

Release entries still come from accepted Asm versions and their `CHANGELOG.md` sections.
Do not copy release notes into article files.
The combined Atom feed includes articles and releases with known publication dates.
