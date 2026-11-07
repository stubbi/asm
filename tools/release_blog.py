"""Generate repository articles and release posts from accepted Asm versions.

No network access or package execution occurs here. Exact release dates come
from the caller's source-bound publication adapter, never package-wide dates.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

from datetime import datetime, timezone
from html import escape
from pathlib import Path
import re
from xml.etree import ElementTree

import package_pages
import registry
import blog_posts

NAME = "stubbi/asm"
REPOSITORY = "https://github.com/stubbi/asm"
MAX_CHANGELOG_BYTES = 512 * 1024
MAX_LINES = 16384
ATOM = "http://www.w3.org/2005/Atom"


def _sections(repo: Path) -> dict[str, str]:
    try:
        text = registry.read_regular(repo, "CHANGELOG.md", MAX_CHANGELOG_BYTES).decode("utf-8")
    except UnicodeError as error:
        raise registry.RegistryError("change log must contain valid UTF-8") from error
    lines = text.splitlines(keepends=True)
    registry.require(len(lines) <= MAX_LINES and all(char in "\t\r\n" or ord(char) >= 32 and char not in "\ufffe\uffff" for char in text),
                     "change log contains unsupported characters or exceeds its line bound")
    sections, current, body, fence = {}, None, [], None
    def finish():
        if current is not None:
            notes = "".join(body).strip()
            registry.require(len(notes.encode("utf-8")) <= package_pages.MAX_README_BYTES
                             and len(body) <= 4096, "release notes exceed their bound")
            sections[current] = notes
    for line in lines:
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if marker:
            if fence is None: fence = (marker[1][0], len(marker[1]))
            elif marker[1][0] == fence[0] and len(marker[1]) >= fence[1] and not marker[2].strip(): fence = None
        heading = re.match(r"^##\s+(.+?)\s*$", line) if fence is None and marker is None else None
        if heading:
            finish()
            current = heading[1]
            # Named maintenance sections are not releases. A heading that
            # starts like a version must still pass the strict version parser.
            if current != "Unreleased":
                if re.match(r"^(?:v)?\d", current): registry.version_tuple(current)
                else: current = None
            if current is not None:
                registry.require(current not in sections and len(sections) <= registry.MAX_ROWS,
                                 "duplicate release section or too many change log sections")
            body = []
        elif current is not None:
            body.append(line)
    registry.require(fence is None, "change log has an unclosed code block")
    finish()
    return sections


def _releases(index: dict) -> dict[str, dict]:
    registry.require(isinstance(index, dict) and type(index.get("schema")) is int and index["schema"] == 1
                     and isinstance(index.get("packages"), list) and len(index["packages"]) <= registry.MAX_ROWS,
                     "unsupported release blog index")
    matches = [item for item in index["packages"] if isinstance(item, dict) and item.get("name") == NAME]
    registry.require(len(matches) <= 1, "duplicate Asm package identity")
    if not matches: return {}
    package, result = matches[0], {}
    registry.require(isinstance(package.get("versions"), list) and len(package["versions"]) <= registry.MAX_ROWS,
                     "invalid Asm release list")
    for release in package["versions"]:
        registry.require(isinstance(release, dict), "invalid Asm release")
        record = {"schema": 1, "name": NAME, "summary": package.get("summary"),
                  **{key: release.get(key) for key in ("version", "license", "source", "artifacts", "yanked")}}
        if release.get("yanked"): record["yank_reason"] = release.get("yank_reason")
        registry.validate_manifest(record)
        registry.require(record["source"]["repository"] == REPOSITORY and record["source"]["path"] == ".",
                         "release blog requires the canonical Asm source")
        registry.require(record["version"] not in result, "duplicate Asm release version")
        result[record["version"]] = record
    return result


def _dates(values: dict | None, versions: dict, now: datetime) -> dict[str, str]:
    registry.require(values is None or isinstance(values, dict) and len(values) <= registry.MAX_ROWS,
                     "invalid release publication map")
    result = {}
    for version, value in (values or {}).items():
        registry.require(version in versions, "publication date names an unknown Asm version")
        if value is None: continue
        registry.require(isinstance(value, str) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)", value),
                         "release publication date must be UTC")
        try: instant = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as error: raise registry.RegistryError("invalid release publication date") from error
        registry.require(datetime(1970, 1, 1, tzinfo=timezone.utc) <= instant <= now,
                         "release publication date is invalid or in the future")
        result[version] = instant.isoformat().replace("+00:00", "Z")
    return result


def _date(value: str | None) -> str:
    if value is None: return '<span class="package-note">Publication date unavailable.</span>'
    instant = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return '<span class="blog-date-label">GitHub release availability: </span><time datetime="' + value + '">' + instant.strftime("%d %b %Y at %H:%M UTC").lstrip("0") + '</time>'


def _route(version: str) -> str:
    return "blog/releases/" + version + "/"


def _summary(notes: str) -> str:
    """Use an existing change-log sentence rather than separate teaser copy."""
    first = next((line.strip() for line in notes.splitlines() if line.strip()), "")
    first = re.sub(r"^(?:[-*+]\s+|#{1,6}\s+)", "", first)
    return first if len(first) <= 220 else first[:217].rsplit(" ", 1)[0] + "…"


def _blog_page(route: str, title: str, description: str, body: str, chrome: tuple[str, str], preview: bool) -> str:
    html = package_pages._page(route, title, description, body, chrome, active_nav="Blog", scripts=False)
    # Preview is a build-wide choice. Archives and released posts must also
    # remain unindexed when they link to unpublished articles.
    if preview: html = html.replace("</head>", '<meta name="robots" content="noindex">\n</head>', 1)
    return html


def _navigation(route: str, selected: str) -> str:
    prefix = "../" * route.count("/")
    links = []
    for label, target in (("All", "blog/"), ("Articles", "blog/articles/"), ("Releases", "blog/releases/")):
        current = (' aria-current="' + ("page" if route == target else "location") + '"') if label == selected else ''
        links.append(package_pages._anchor(label, prefix + target, attrs=current))
    return '<nav class="package-section-nav" aria-label="Blog">' + ''.join(links) + '</nav>'


def _byline(post: dict) -> str:
    text = escape(post["author"])
    if post["draft"]:
        text += ' · <span>Unpublished</span>'
    else:
        instant = datetime.fromisoformat(post["date"].replace("Z", "+00:00"))
        text += ' · <time datetime="' + post["date"] + '">' + instant.strftime("%d %b %Y").lstrip("0") + '</time>'
        if post["updated"] and post["updated"] != post["date"]:
            updated = datetime.fromisoformat(post["updated"].replace("Z", "+00:00"))
            text += ' · Updated <time datetime="' + post["updated"] + '">' + updated.strftime("%d %b %Y").lstrip("0") + '</time>'
    return '<p class="blog-byline">' + text + '</p>'


def _listing(posts: list[dict], route: str) -> str:
    prefix = "../" * route.count("/")
    rows = []
    for post in posts:
        article = post["kind"] == "article"
        label = "Draft" if post.get("draft") else "Article" if article else "Release"
        metadata = _byline(post) if article else '<p class="blog-date">' + _date(post["date"]) + '</p>'
        summary = escape(post["summary"]) if article else post["summary"]
        rows.append('<li class="package-catalog-item blog-list-item"><span class="blog-kind">' + label + '</span><h2>' +
                    package_pages._anchor(post["title"], prefix + post["route"], attrs=' class="package-catalog-name"') +
                    '</h2>' + metadata + '<p>' + summary + '</p></li>')
    return '<ul class="package-catalog blog-list">' + ''.join(rows) + '</ul>'


def _feed(posts: list[dict], now: datetime) -> bytes:
    # RFC 4287 requires feed/entry updated timestamps. Undated releases stay
    # in HTML only; an empty feed labels its actual metadata generation time.
    ElementTree.register_namespace("", ATOM)
    tag = lambda name: "{" + ATOM + "}" + name
    feed = ElementTree.Element(tag("feed"), {"{http://www.w3.org/XML/1998/namespace}lang": "en"})
    def add(parent, name, text=None, **attrs):
        child = ElementTree.SubElement(parent, tag(name), attrs)
        child.text = text
        return child
    dated = [post for post in posts if post["date"] is not None and not post.get("draft")
             and datetime.fromisoformat(post["date"].replace("Z", "+00:00")) <= now]
    add(feed, "id", package_pages.SITE + "blog/")
    add(feed, "title", "Asm blog")
    add(feed, "link", href=package_pages.SITE + "blog/atom.xml", rel="self", type="application/atom+xml")
    add(feed, "link", href=package_pages.SITE + "blog/", rel="alternate", type="text/html")
    add(add(feed, "author"), "name", "Asm")
    updated = max((post.get("updated") or post["date"] for post in dated), key=lambda value: datetime.fromisoformat(value.replace("Z", "+00:00"))) if dated else now.isoformat().replace("+00:00", "Z")
    add(feed, "updated", updated)
    add(feed, "subtitle", "Articles and release notes from Asm. Release dates describe GitHub availability; undated releases remain on the website." if dated else
        "No dated posts are available. The updated timestamp records feed metadata generation, not publication.")
    for post in dated:
        entry = add(feed, "entry")
        add(entry, "id", package_pages.SITE + post["route"])
        add(entry, "title", post["title"])
        add(entry, "link", href=package_pages.SITE + post["route"], rel="alternate", type="text/html")
        add(entry, "published", post["date"])
        add(entry, "updated", post.get("updated") or post["date"])
        if post["kind"] == "article":
            add(add(entry, "author"), "name", post["author"])
            add(entry, "summary", post["summary"])
        else:
            add(entry, "summary", "Change log for Asm " + post["version"] + ". The publication date describes GitHub release availability.")
        add(entry, "content", post["html"], type="html")
    return ElementTree.tostring(feed, encoding="utf-8", xml_declaration=True)


def write_release_blog(repo: Path, stage: Path, index: dict, publication=None, *, release_dates=None, include_drafts=False) -> list[str]:
    """Write articles, release posts, archives, and Atom; return public HTML routes.

    Only accepted stubbi/asm versions with released change-log sections qualify.
    The caller supplies a version-to-UTC map from exact artifact-bound release
    metadata. Package-wide discovery dates are deliberately never substituted.
    All source parsing and rendering complete before the first output write.
    Preview drafts are visibly unpublished, unindexed, and excluded from Atom
    and the returned sitemap routes. No authored Markdown is copied to stage.
    """
    releases, sections = _releases(index), _sections(repo)
    registry.require(set(releases) <= sections.keys(), "an accepted Asm release lacks its change log section")
    now = datetime.now(timezone.utc)
    dates = _dates(release_dates, releases, now)
    articles = blog_posts.load_posts(repo, include_drafts=include_drafts, now=now)
    chrome = package_pages._chrome(stage)
    # Parsed instants, rather than lexical ISO text, preserve fractional order.
    versions = sorted(releases, key=lambda version: (version in dates, datetime.fromisoformat(dates[version].replace("Z", "+00:00")) if version in dates else datetime.min.replace(tzinfo=timezone.utc), registry.version_tuple(version)), reverse=True)
    posts, outputs = [], []
    for version in versions:
        record, route = releases[version], _route(version)
        registry.require(bool(sections[version]), "released change log section is empty")
        content = package_pages._markdown(sections[version], record["source"], "CHANGELOG.md")
        prefix = "../" * route.count("/")
        facts = '<dl class="package-facts"><div><dt>Version</dt><dd><code>' + version + '</code></dd></div><div><dt>Release license</dt><dd><code>' + escape(record["license"]) + '</code></dd></div></dl>'
        state = '<p class="package-alert">Yanked: ' + escape(record["yank_reason"]) + '</p>' if record["yanked"] else ''
        body = ('<nav class="package-breadcrumbs" aria-label="Breadcrumb"><a href="' + prefix + 'blog/">Blog</a></nav>' + _navigation(route, "Releases") +
                '<article class="blog-post"><header class="package-heading blog-heading"><span class="blog-kind">Release</span><h1>Asm ' + version + '</h1><p class="blog-date">' + _date(dates.get(version)) + '</p>' + facts + state + '</header>'
                '<div class="package-readme-content blog-release-content">' + content + '</div><section class="package-section blog-source"><h2>Release source</h2>'
                '<p>Generated from this version’s section in the repository change log.</p><p>' +
                package_pages._anchor("Change log source", REPOSITORY + "/blob/main/CHANGELOG.md#" + version.replace(".", "")) + ' · ' +
                package_pages._anchor("GitHub release notes", REPOSITORY + "/releases/tag/v" + version) + ' · ' +
                package_pages._anchor("Exact package and evidence", prefix + package_pages.package_route(NAME, version)) + '</p>'
                '<p>Release source commit: <code>' + record["source"]["commit"] + '</code></p></section></article>')
        html = _blog_page(route, "Asm " + version, "Release notes for Asm " + version + ".", body, chrome, include_drafts)
        outputs.append((route + "index.html", html.encode("utf-8")))
        posts.append({"kind": "release", "title": "Asm " + version, "version": version, "route": route, "date": dates.get(version), "html": content,
                      "summary": package_pages._inline(_summary(sections[version]), record["source"], "CHANGELOG.md")})
    for post in articles:
        route = post["route"]
        prefix = "../" * route.count("/")
        kind = "Draft" if post["draft"] else "Article"
        body = ('<nav class="package-breadcrumbs" aria-label="Breadcrumb">' + package_pages._anchor("Blog", prefix + "blog/") + '</nav>' +
                _navigation(route, "Articles") + '<article class="blog-post"><header class="package-heading blog-heading">' +
                '<span class="blog-kind">' + kind + '</span><h1>' + escape(post["title"]) + '</h1>' +
                '<p class="package-summary">' + escape(post["summary"]) + '</p>' + _byline(post) + '</header>' +
                '<div class="package-readme-content blog-release-content">' + post["html"] + '</div>' +
                '<section class="package-section blog-source"><h2>Article source</h2><p>' +
                package_pages._anchor("Read the maintained source", post["source"]) + '</p><p>' +
                package_pages._anchor("Back to articles", prefix + "blog/articles/") + ' · ' +
                package_pages._anchor("Back to blog", prefix + "blog/") + '</p></section></article>')
        html = _blog_page(route, post["title"], post["summary"], body, chrome, include_drafts)
        outputs.append((route + "index.html", html.encode("utf-8")))
    posts += articles
    # Published timestamps define chronological order. Stable route ordering
    # resolves equal instants. Undated release versions retain numeric order.
    dated = sorted((post for post in posts if post["date"] is not None and not post.get("draft")), key=lambda post: post["route"])
    dated.sort(key=lambda post: datetime.fromisoformat(post["date"].replace("Z", "+00:00")), reverse=True)
    drafts = sorted((post for post in posts if post.get("draft")), key=lambda post: post["route"])
    undated = [post for post in posts if post["kind"] == "release" and post["date"] is None]
    posts = dated + drafts + undated
    for route, title, description, selected, entries in (
            ("blog/", "Blog", "Articles about Asm and release notes from the change log.", "All", posts),
            ("blog/articles/", "Articles", "Articles about Asm, assembly, and dependable software reuse.", "Articles", [post for post in posts if post["kind"] == "article"]),
            ("blog/releases/", "Releases", "Release notes for registered Asm releases.", "Releases", [post for post in posts if post["kind"] == "release"])):
        prefix = "../" * route.count("/")
        body = ('<header class="package-heading blog-heading"><h1>' + title + '</h1><p>' + description + '</p></header>' +
                _navigation(route, selected) + '<p class="blog-feed-link">' + package_pages._anchor("Subscribe with Atom", prefix + "blog/atom.xml") + '</p>')
        body += _listing(entries, route) if entries else '<p>' + ("No articles are published yet." if selected == "Articles" else "No Asm releases are registered yet." if selected == "Releases" else "No posts are published yet.") + '</p>'
        body += '<p class="package-note">Release entries require registered Asm versions. Unreleased changes stay in the repository change log. The feed includes published articles and releases with known dates.</p>'
        outputs.append((route + "index.html", _blog_page(route, title, description, body, chrome, include_drafts).encode("utf-8")))
    outputs.append(("blog/atom.xml", _feed(posts, now)))
    for relative, data in outputs: registry.write_atomic(stage / relative, data)
    return ["blog/", "blog/articles/", "blog/releases/"] + [post["route"] for post in posts if not post.get("draft")]
