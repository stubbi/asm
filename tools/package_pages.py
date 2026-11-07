"""Generate static package views from accepted records and the checked index.

README text comes only from an available, matching local Git snapshot. This
module performs no network operations and never executes package code.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

from datetime import datetime, timezone
from html import escape, unescape
import json
from pathlib import Path
import re
from urllib.parse import quote, unquote, urlsplit

import registry
import target_metadata
import discovery_metadata
from count_format import compact_count, count_html


SITE = "https://asm.build/"
REPOSITORY = "https://github.com/stubbi/asm"
MAX_README_BYTES = 128 * 1024
README_NAMES = ("README.md", "README", "README.txt")
EVIDENCE = {"metadata": "Metadata", "artifacts": "Artifacts", "provenance": "Provenance",
            "formal": "Formal proof", "agent_review": "Agent review"}
STATES = {"validated", "pass", "fail", "not-run", "unsupported", "error"}


def package_route(name: str, version: str | None = None) -> str:
    registry.package_name(name)
    if version is not None:
        registry.version_tuple(version)
    return "packages/" + name + "/" + (version + "/" if version is not None else "")


def record_route(record: dict) -> str:
    return f"registry/v1/packages/{record['name']}/{record['version']}.json"


def _anchor(label: str, href: str, *, package: bool = False, attrs: str = "") -> str:
    return f'<a href="{escape(href, quote=True)}"' + (' data-package-link' if package else '') + attrs + f'>{escape(label)}</a>'


def _breadcrumbs(trail: list[tuple[str, str | None]], *, back_search: str | None = None) -> str:
    """Describe the visible hierarchy without treating a search state as a parent."""
    result = '<nav class="package-breadcrumbs" aria-label="Breadcrumb"><ol itemscope itemtype="https://schema.org/BreadcrumbList">'
    if back_search:
        result += '<li>' + _anchor("Back to search", back_search, attrs=' data-back-to-search') + '</li>'
    for position, (name, url) in enumerate(trail, 1):
        result += '<li itemprop="itemListElement" itemscope itemtype="https://schema.org/ListItem">'
        label = '<span itemprop="name">' + escape(name) + '</span>'
        result += ('<a itemprop="item" data-package-link href="' + escape(url, quote=True) + '">' + label + '</a>') if url else '<span aria-current="page">' + label + '</span>'
        result += f'<meta itemprop="position" content="{position}"></li>'
    return result + '</ol></nav>'


def _release_description(name: str, record: dict | None, *, exact: bool = False) -> str:
    if record is None:
        return f"{name} has no active release. Inspect retained versions, source records, targets, and release evidence."
    targets = ", ".join(sorted({artifact["target"] for artifact in record["artifacts"]}))
    identity = name + (" " + record["version"] if exact else "")
    state = "Yanked release. " if record["yanked"] else ""
    return f'{identity}: {state}{record["summary"]} License: {record["license"]}. Recorded targets: {targets}.'


def _json_ld(value: dict | None) -> str:
    """Serialize data without allowing a source string to terminate its script."""
    if value is None:
        return ""
    encoded = json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(",", ":"))
    for character, replacement in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026")):
        encoded = encoded.replace(character, replacement)
    registry.require(len(encoded) <= 128 * 1024, "page structured data exceeds its bound")
    return '<script type="application/ld+json">' + encoded + '</script>'


def _source_url(record: dict) -> str:
    source = record["source"]
    url = source["repository"] + "/tree/" + source["commit"]
    return url + ("/" + quote(source["path"], safe="/") if source["path"] != "." else "")


def _package_schema(route: str, name: str, description: str, selected: dict | None) -> dict:
    """Describe the visible page and exact recorded source, without trust claims."""
    canonical = SITE + route.rstrip("/")
    page = {"@context": "https://schema.org", "@type": "WebPage", "@id": canonical + "#webpage",
            "url": canonical, "name": name, "description": description, "inLanguage": "en"}
    if selected is not None:
        version_url = SITE + package_route(name, selected["version"]).rstrip("/")
        page["mainEntity"] = {
            "@type": "SoftwareSourceCode", "@id": version_url + "#source", "name": name,
            "description": selected["summary"], "version": selected["version"],
            "identifier": [{"@type": "PropertyValue", "propertyID": "Package release", "value": name + "@" + selected["version"]},
                           {"@type": "PropertyValue", "propertyID": "Git commit", "value": selected["source"]["commit"]}],
            "url": _source_url(selected), "codeRepository": selected["source"]["repository"],
            "license": "https://spdx.org/licenses/" + selected["license"] + ".html",
            "creativeWorkStatus": "Yanked release" if selected["yanked"] else "Active release",
            "subjectOf": {"@type": "CreativeWork", "url": SITE + record_route(selected), "encodingFormat": "application/json"}}
    return page


def _topic_links(topics: dict | None, prefix: str) -> str:
    if not topics:
        return ""
    rows = []
    for label, group, entries in (("Categories", "categories", topics["categories"]),
                                  ("Keywords", "keywords", [(tag, tag) for tag in topics["keywords"]]),
                                  ("Architectures", "architectures", topics["architectures"])):
        if entries:
            links = "".join('<li>' + _anchor(name, prefix + "browse/" + group + "/" + identifier + "/") + '</li>'
                            for identifier, name in entries)
            rows.append('<div><dt>' + label + '</dt><dd><ul>' + links + '</ul></dd></div>')
    if not rows:
        return ""
    return ('<section class="package-section"><h2>Browse related</h2><dl class="package-source-facts package-topics">'
            + "".join(rows) + '</dl><p class="package-note">Current package classification. Check each release’s declared targets.</p></section>')


def _chrome(stage: Path) -> tuple[str, str]:
    content = registry.read_regular(stage, "index.html", 512 * 1024).decode("utf-8")
    fragments = []
    for tag in ("header", "footer"):
        matches = re.findall(rf'<{tag}\b[^>]*>.*?</{tag}>', content, re.S)
        registry.require(len(matches) == 1 and len(matches[0]) <= 65536, "site needs one bounded header and footer")
        fragments.append(matches[0])
    return tuple(fragments)


def _relative_chrome(fragment: str, prefix: str, active: bool | str) -> str:
    fragment = re.sub(r'\s+aria-current="[^"]*"', "", fragment)
    def rewrite(match):
        attribute, value = match.group(1), unescape(match.group(2))
        parsed = urlsplit(value)
        if not parsed.scheme and not parsed.netloc and not parsed.path.startswith("/"):
            value = prefix + ("index.html" + value if value.startswith("#") else value)
        return f'{attribute}="{escape(value, quote=True)}"'
    fragment = re.sub(r'\b(href|src|action)="([^"]*)"', rewrite, fragment)
    if active:
        label = active if isinstance(active, str) else "Explore"
        registry.require(label in {"Explore", "Stats", "Blog", "Docs"}, "unknown current navigation item")
        fragment = re.sub(r'(<a\b[^>]*)(>' + re.escape(label) + r'</a>)', r'\1 aria-current="page"\2', fragment, count=1)
    return fragment


def _page(route: str, title: str, description: str, body: str, chrome: tuple[str, str], *, missing=False,
          active_nav="Explore", scripts=True, structured_data=None, metadata_url=None) -> str:
    # A host can serve this document at any missing path. Root paths preserve
    # recovery and assets without changing the skip link's local fragment.
    prefix = "/" if missing else "../" * route.count("/")
    canonical = SITE + route
    header = _relative_chrome(chrome[0], prefix, active_nav if not missing else False)
    footer = _relative_chrome(chrome[1], prefix, False)
    robots = '<meta name="robots" content="noindex">' if missing else ''
    og_type = "article" if structured_data and structured_data.get("@type") == "BlogPosting" else "website"
    metadata_link = ('<link rel="describedby" type="application/json" href="' + escape(metadata_url, quote=True)
                     + '" title="Exact release metadata">') if metadata_url else ''
    script_tags = (f'<script src="{prefix}app.js" defer></script>\n'
                   f'<script src="{prefix}package-page.js" defer></script>') if scripts else ''
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#f5f5f4">
<meta name="description" content="{escape(description, quote=True)}">
<meta property="og:site_name" content="Asm">
<meta property="og:type" content="{og_type}">
<meta property="og:title" content="{escape(title, quote=True)} | Asm">
<meta property="og:description" content="{escape(description, quote=True)}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="https://asm.build/social-preview.png">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1280">
<meta property="og:image:height" content="640">
<meta property="og:image:alt" content="Asm package search, with the &gt;asm wordmark and asm.build.">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{escape(title, quote=True)} | Asm">
<meta name="twitter:description" content="{escape(description, quote=True)}">
<meta name="twitter:image" content="https://asm.build/social-preview.png">
<meta name="twitter:image:alt" content="Asm package search, with the &gt;asm wordmark and asm.build.">
{robots}
<link rel="canonical" href="{canonical}">
<link rel="alternate" type="application/atom+xml" href="{prefix}blog/atom.xml" title="Asm blog">
{metadata_link}
<link rel="icon" type="image/svg+xml" href="{prefix}icon.svg">
<link rel="stylesheet" href="{prefix}styles.css">
<link rel="stylesheet" href="{prefix}packages.css">
<script src="{prefix}navigation.js"></script>
<script src="{prefix}repository-stars.js" defer></script>
{script_tags}
{_json_ld(structured_data)}
<title>{escape(title)} | Asm</title>
</head>
<body class="package-page">
<a class="skip-link" href="#main">Skip to content</a>
{header}
<main id="main" class="container package-main">{body}</main>
{footer}
<p class="sr-only" role="status" aria-live="polite" id="copy-status"></p>
</body>
</html>
'''


def _safe_readme_link(value: str, source: dict, readme_name: str) -> str | None:
    if not value or len(value) > 2048 or any(ord(char) < 33 for char in value):
        return None
    try:
        parsed = urlsplit(value)
        if parsed.scheme:
            return value if parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password else None
        if parsed.netloc or parsed.path.startswith("/"):
            return None
        path = unquote(parsed.path)
        if path.startswith("./"):
            path = path[2:]
        if path:
            registry.portable_path(path)
        elif not parsed.fragment:
            return None
        source_path = "" if source["path"] == "." else source["path"] + "/"
        target = path or readme_name
        result = f"{source['repository']}/blob/{source['commit']}/{source_path}{quote(target, safe='/')}"
        if parsed.query:
            result += "?" + parsed.query
        if parsed.fragment:
            result += "#" + parsed.fragment
        return result
    except (ValueError, registry.RegistryError):
        return None


def _inline(text: str, source: dict, readme_name: str) -> str:
    # Exclude nested delimiters so unfinished links cannot repeatedly scan
    # overlapping suffixes. Unsupported nested syntax stays literal text.
    pattern = r'`([^`\n]+)`|(?<!!)\[([^\[\]\n]+)\]\(([^()\[\]\s]+)\)|\*\*([^*\n]+)\*\*|\*([^*\n]+)\*'
    result, cursor = [], 0
    for match in re.finditer(pattern, text):
        result.append(escape(text[cursor:match.start()]))
        code, label, target, strong, emphasis = match.groups()
        if code is not None:
            result.append("<code>" + escape(code) + "</code>")
        elif label is not None:
            href = _safe_readme_link(target, source, readme_name)
            result.append(_anchor(label, href) if href else escape(match.group()))
        else:
            tag, value = ("strong", strong) if strong is not None else ("em", emphasis)
            result.append(f"<{tag}>" + escape(value) + f"</{tag}>")
        cursor = match.end()
    result.append(escape(text[cursor:]))
    return "".join(result)


def _markdown(text: str, source: dict, readme_name: str, *, heading_offset=2) -> str:
    """Render a small Markdown subset; unsupported constructs remain literal text."""
    registry.require(type(heading_offset) is int and 0 <= heading_offset <= 5, "invalid Markdown heading offset")
    lines, result, index, heading_ids = text.splitlines(), [], 0, set()
    section_title, table_number = "Source documentation", 0
    def cells(line): return line.strip().strip("|").split("|")
    def table_rule(line):
        return "|" in line and all(re.fullmatch(r"\s*:?-{3,}:?\s*", cell) for cell in cells(line))
    while index < len(lines):
        line = lines[index]
        if not line.strip():
            index += 1; continue
        fence = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if fence:
            index += 1; code = []
            closing = re.compile(r"^ {0,3}" + re.escape(fence[1][0]) + "{" + str(len(fence[1])) + r",}\s*$")
            while index < len(lines) and closing.fullmatch(lines[index]) is None:
                code.append(lines[index]); index += 1
            result.append('<pre tabindex="0"><code>' + escape("\n".join(code)) + '</code></pre>')
            index += 1; continue
        heading = re.match(r"^(#{1,6})\s+(.+)$", line)
        if heading:
            level = min(6, len(heading[1]) + heading_offset)
            slug = re.sub(r"[^a-z0-9]+", "-", heading[2].lower()).strip("-") or "section"
            identifier, suffix = "readme-" + slug, 2
            while identifier in heading_ids:
                identifier = f"readme-{slug}-{suffix}"
                suffix += 1
            heading_ids.add(identifier)
            section_title = heading[2]
            result.append(f'<h{level} id="{identifier}">{_inline(heading[2], source, readme_name)}</h{level}>')
            index += 1; continue
        if index + 1 < len(lines) and "|" in line and table_rule(lines[index + 1]):
            headers = "".join("<th>" + _inline(cell.strip(), source, readme_name) + "</th>" for cell in cells(line))
            index += 2; rows = []
            while index < len(lines) and "|" in lines[index] and lines[index].strip():
                rows.append("<tr>" + "".join("<td>" + _inline(cell.strip(), source, readme_name) + "</td>" for cell in cells(lines[index])) + "</tr>")
                index += 1
            table_number += 1
            table_label = escape(f"{section_title}, table {table_number}", quote=True)
            result.append('<div class="package-table-scroll" tabindex="0" aria-label="Scrollable table"><table aria-label="' + table_label + '"><thead><tr>' + headers + '</tr></thead><tbody>' + "".join(rows) + '</tbody></table></div>')
            continue
        listing = re.match(r"^\s*(?:([-*+])|(\d+)\.)\s+(.+)$", line)
        if listing:
            tag = "ol" if listing[2] else "ul"; items = []
            while index < len(lines):
                item = re.match(r"^\s*(?:([-*+])|(\d+)\.)\s+(.+)$", lines[index])
                if not item or bool(item[2]) != (tag == "ol"): break
                items.append("<li>" + _inline(item[3], source, readme_name) + "</li>"); index += 1
            result.append(f"<{tag}>" + "".join(items) + f"</{tag}>"); continue
        paragraph = [line]; index += 1
        while index < len(lines) and lines[index].strip() and not re.match(r"^(?:#{1,6}\s| {0,3}(?:`{3,}|~{3,})|\s*[-*+]\s|\s*\d+\.\s)", lines[index]):
            if index + 1 < len(lines) and table_rule(lines[index + 1]): break
            paragraph.append(lines[index]); index += 1
        result.append("<p>" + _inline("\n".join(paragraph), source, readme_name) + "</p>")
    return "\n".join(result)


def _readme(repo: Path, record: dict | None, cache: dict) -> str:
    fallback = '<p class="package-note">The source README is unavailable for this recorded release. Read the source repository or release record.</p>'
    if record is None:
        return '<p class="package-note">Select an exact release from the version history to read its source documentation.</p>'
    source = record["source"]
    key = (source["repository"], source["commit"], source["path"])
    if key in cache: return cache[key]
    try:
        origin = registry.git_output(repo, "config", "--get", "remote.origin.url").decode().strip()
        registry.require(origin in {REPOSITORY, REPOSITORY + ".git", "git@github.com:stubbi/asm.git"}, "local repository origin does not match")
        registry.require(source["repository"] == REPOSITORY, "README repository is not available locally")
        registry.portable_path(source["path"], allow_root=True)
        root = "" if source["path"] == "." else source["path"] + "/"
        # Preserve the Markdown preference and inspect only accepted root names.
        for filename in README_NAMES:
            try:
                size = int(registry.git_output(repo, "cat-file", "-s", source["commit"] + ":" + root + filename))
                break
            except registry.RegistryError:
                continue
        else:
            raise registry.RegistryError("source root README is unavailable")
        registry.require(0 < size <= MAX_README_BYTES, "README exceeds the content bound")
        files = registry.git_files(repo, source["commit"], source["path"], includes=[filename])
        content = files[filename][0]
        registry.require(len(content) <= MAX_README_BYTES, "README exceeds the content bound")
        text = content.decode("utf-8")
        registry.require(len(text.splitlines()) <= 4096 and all(ord(c) >= 32 or c in "\n\r\t" for c in text), "README contains unsupported content")
        url = f"{source['repository']}/blob/{source['commit']}/{root}{filename}"
        result = ('<p class="package-note">Source snapshot: ' + _anchor(filename, url) + ' at commit <code>' + escape(source["commit"]) + '</code>. This is source documentation, not artifact verification.</p><div class="package-readme-content">' + _markdown(text, source, filename) + '</div>')
    except (registry.RegistryError, ValueError, UnicodeError, KeyError, OSError):
        result = fallback
    cache[key] = result
    return result


def _facts(values: list[tuple[str, str]], class_name: str) -> str:
    return f'<dl class="{class_name}">' + "".join(f'<div><dt>{escape(label)}</dt><dd>{escape(value)}</dd></div>' for label, value in values) + '</dl>'


def _preview_metadata(record: dict | None) -> str:
    if record is None:
        return ''
    groups = {}
    for artifact in record['artifacts']:
        groups.setdefault(artifact['kind'], set()).add(artifact['target'])
    labels = {'source': 'Source', 'executable': 'Executable'}
    content = _facts([('License', record['license']), ('Formats', ' · '.join(labels[kind] for kind in sorted(groups)))], 'package-result-meta')
    content += '<dl class="package-result-targets">'
    for kind, targets in sorted(groups.items()):
        content += '<div class="package-result-target-group"><dt class="package-result-target-label">' + labels[kind] + ' targets</dt><dd><ul class="package-result-target-list">'
        content += ''.join('<li class="package-result-target"><code>' + escape(target) + '</code></li>' for target in sorted(targets))
        content += '</ul></dd></div>'
    return content + '</dl>'


def _evidence_label(value: object) -> str:
    if not isinstance(value, str) or value not in STATES:
        return "Unavailable"
    return "Not run" if value == "not-run" else value.capitalize()


def _counts(counts: dict, name: str, version: str | None, *, html=False) -> str:
    def value(number, lower_bound=False):
        if html:
            return count_html(number, lower_bound=lower_bound)
        return ("≥ " if lower_bound else "") + compact_count(number, lower_bound=lower_bound)
    if counts.get("source") == "asm-delivery-events":
        package = counts.get("packages", {}).get(name, {})
        count = package.get("total") if version is None else package.get("versions", {}).get(version)
        if count is None:
            return "Asm download data is unavailable."
        def timestamp(value):
            try:
                return datetime.fromisoformat(value.replace("Z", "+00:00")).strftime("%d %b %Y at %H:%M UTC").lstrip("0")
            except (AttributeError, ValueError):
                return "an unavailable date"
        observed = counts.get("observed_at")
        period = " · last 30 days ending " + timestamp(observed) if observed else ""
        if not counts.get("complete") and count == 0:
            return "No completed downloads recorded in the observed part of this window. Coverage is incomplete." + (" Observations are stale." if counts.get("stale") else "")
        return "Asm downloads: " + value(count, not counts.get("complete")) + period + (". Observations are stale." if counts.get("stale") else "")
    entry = counts.get("packages", {}).get(name, {}) if isinstance(counts, dict) else {}
    number = entry.get("total") if version is None else entry.get("versions", {}).get(version)
    if counts.get("schema") != 1 or counts.get("source") != "github-release-assets" or type(number) is not int or number < 0:
        return "GitHub asset downloads: unavailable"
    observed = counts.get("observed_at")
    try:
        date = datetime.fromisoformat(observed.replace("Z", "+00:00")).date().isoformat()
    except (AttributeError, ValueError, TypeError):
        date = None
    return "GitHub asset downloads: " + value(number) + (f" · observed {date}" if date else " · observation time unavailable")


def counts_html(counts: dict, name: str, version: str | None) -> str:
    """Render compact counts with exact accessible values and retained scope.

    All non-count text is fixed text or a parsed, formatted date. Registry
    strings and unparsed source data never enter this HTML representation.
    """
    return _counts(counts, name, version, html=True)


def _history(name: str, records: list[dict], route: str) -> str:
    prefix = "../" * route.count("/")
    items = []
    for record in records:
        target = package_route(name, record["version"])
        label = "Yanked" if record["yanked"] else "Active"
        attrs = ' aria-current="page"' if route == target else ''
        reason = '<p>' + escape(record.get("yank_reason", "")) + '</p>' if record["yanked"] else ''
        items.append('<li>' + _anchor(record["version"], prefix + target, package=True, attrs=attrs) + f'<span class="release-state">{label}</span>' + reason + '</li>')
    return '<ul class="package-versions">' + "".join(items) + '</ul>'


def _file_filters(record: dict, indexed: dict) -> str:
    artifacts = indexed["artifacts"]
    targets = sorted({item["target"] for item in artifacts})
    kinds = sorted({item["kind"] for item in artifacts})
    architectures = sorted({target_metadata.architecture_for_target(item["target"]) for item in artifacts} - {None})
    form = ''
    if not record["yanked"]:
        options = lambda values: "".join(f'<option value="{escape(value, quote=True)}">{escape(value)}</option>' for value in values)
        form = ('<form class="package-filter-form" hidden aria-label="Filter release files">'
                '<div class="package-file-filter"><label for="artifact-kind">Format</label><select id="artifact-kind" data-artifact-filter="kind"><option value="">All formats</option>' + options(kinds) + '</select></div>'
                '<div class="package-file-filter"><label for="artifact-architecture">Architecture</label><select id="artifact-architecture" data-artifact-filter="architecture"><option value="">All architectures</option>' +
                ''.join('<option value="' + key + '">' + target_metadata.ARCHITECTURES[key] + ' (' + key + ')</option>' for key in architectures) + '</select></div>'
                '<div class="package-file-filter"><label for="artifact-target">Target</label><select id="artifact-target" data-artifact-filter="target"><option value="">All targets</option>' + options(targets) + '</select></div>'
                '<button type="button" class="reset-search" data-clear-artifact-filters>Clear file filters</button></form>')
    return form


def _quick_fetch(record: dict, indexed: dict) -> str:
    artifacts = indexed["artifacts"]
    single = artifacts[0] if len(artifacts) == 1 else None
    command = (f"asm fetch {record['name']}@{record['version']} --target {single['target']} --kind {single['kind']}"
               if single else "")
    label = (("Executable" if single["kind"] == "executable" else "Source archive") + " · " + single["target"]) if single else "Selected release file"
    return (_file_filters(record, indexed) +
            '<p class="package-selection-note" data-fetch-selection' + (' hidden' if single else '') + '>Choose a release file below. Each file includes its exact fetch command.</p>' +
            '<div class="command-block package-quick-command" data-selected-fetch' + (' hidden' if not single else '') + '><div class="command-block-heading"><span data-selected-fetch-label>' + escape(label) +
            '</span><button class="copy-button" type="button" data-copy="selected-fetch-command" aria-label="Copy selected fetch command">Copy</button></div><pre tabindex="0"><code id="selected-fetch-command">' +
            escape(command) + '</code></pre></div>')


def _dependency_sources(value: object, index: dict) -> dict:
    """Bind optional declarations to checked source artifacts, never catalog fields.

    Invalid or ambiguous sidecars leave declarations unavailable. They cannot
    prevent package inspection or substitute another release's declarations.
    """
    if value is None:
        return {}
    try:
        registry.exact_keys(value, {"schema", "sources"}, {"schema", "sources"}, "source declarations")
        registry.require(type(value["schema"]) is int and value["schema"] == 1
                         and isinstance(value["sources"], list) and len(value["sources"]) <= registry.MAX_ROWS,
                         "invalid source declarations")
        registry.require(len(registry.json_bytes(value)) <= 4 * 1024 * 1024, "source declarations exceed four MiB")
        checked = {(package["name"], version["version"], artifact["target"], artifact["sha256"])
                   for package in index["packages"] for version in package["versions"]
                   if version.get("evidence", {}).get("artifacts") == "validated"
                   for artifact in version["artifacts"] if artifact["kind"] == "source"}
        result = {}
        for source in value["sources"]:
            registry.exact_keys(source, {"name", "version", "target", "metadata"},
                                {"name", "version", "target", "metadata"}, "source declaration")
            registry.package_name(source["name"])
            registry.version_tuple(source["version"])
            registry.require(source["target"] in registry.TARGETS, "invalid source declaration target")
            metadata = registry.exact_keys(source["metadata"], {"schema", "source_sha256", "dependencies", "features"},
                                          {"schema", "source_sha256", "dependencies", "features"}, "source metadata")
            registry.require(type(metadata["schema"]) is int and metadata["schema"] == 1
                             and isinstance(metadata["source_sha256"], str)
                             and registry.HEX64.fullmatch(metadata["source_sha256"]) is not None,
                             "invalid source metadata digest")
            identity = (source["name"], source["version"], source["target"], metadata["source_sha256"])
            registry.require(identity not in result, "duplicate source declaration")
            dependencies, features = metadata["dependencies"], metadata["features"]
            registry.require(isinstance(dependencies, list) and len(dependencies) <= registry.MAX_DEPENDENCIES
                             and isinstance(features, dict) and len(features) <= registry.MAX_FEATURES,
                             "invalid dependency or feature declarations")
            declared = {}
            for dependency in dependencies:
                registry.exact_keys(dependency, {"name", "requirement", "optional", "default_features", "features"},
                                    {"name", "requirement", "optional", "default_features", "features"}, "dependency")
                name = registry.package_name(dependency["name"])
                registry.require(name not in declared and type(dependency["optional"]) is bool
                                 and type(dependency["default_features"]) is bool, "invalid dependency declaration")
                registry.validate_requirement(dependency["requirement"])
                for feature in registry.feature_entries(dependency["features"], "requested features"):
                    registry.feature_name(feature)
                declared[name] = dependency
            edges = {}
            for name, members in features.items():
                registry.feature_name(name)
                edges[name] = []
                for member in registry.feature_entries(members, "feature members"):
                    registry.require(len(member) <= 137, "feature member exceeds its bound")
                    if member.startswith("dep:"):
                        dependency = member[4:]
                        registry.require(dependency in declared and declared[dependency]["optional"],
                                         "feature must select a declared optional dependency")
                    elif "/" in member:
                        dependency, _, feature = member.rpartition("/")
                        registry.feature_name(feature)
                        registry.require(dependency in declared, "feature selects an undeclared dependency")
                    else:
                        registry.feature_name(member)
                        registry.require(member in features, "feature selects an undeclared local feature")
                        edges[name].append(member)
            visited, active = set(), set()
            def visit(name):
                registry.require(name not in active, "feature declarations contain a cycle")
                if name in visited: return
                active.add(name)
                for child in edges[name]: visit(child)
                active.remove(name)
                visited.add(name)
            for name in edges: visit(name)
            # Unchecked and mismatched identities stay unknown without blocking
            # other independently matched source declarations.
            result[identity] = metadata if identity in checked else None
        return {identity: metadata for identity, metadata in result.items() if metadata is not None}
    except (registry.RegistryError, KeyError, TypeError, ValueError, UnicodeError):
        return {}


def _dependency_markup(metadata: dict | None, prefix: str, package_names: set[str]) -> str:
    section = '<section class="dependency-section"><h4>Declared dependencies</h4>'
    if metadata is None:
        return section + '<p class="dependency-note">Dependency information unavailable for this source archive.</p></section>'
    def link(name):
        if name in package_names:
            return _anchor(name, prefix + package_route(name), package=True, attrs=' class="dependency-link"')
        return '<span class="dependency-name"><code>' + escape(name) + '</code><span class="dependency-unavailable">Not in this catalog</span></span>'
    features = metadata["features"]
    if metadata["dependencies"]:
        section += '<ul class="dependency-list">'
        for dependency in metadata["dependencies"]:
            name = dependency["name"]
            conditions = ["Optional" if dependency["optional"] else "Required",
                          "Default features requested" if dependency["default_features"] else "Default features disabled"]
            if dependency["optional"]:
                enabled = [feature for feature, members in features.items()
                           if any(member == "dep:" + name or member.startswith(name + "/") for member in members)]
                if enabled: conditions.append("Enabled by: " + ", ".join(enabled))
            section += '<li class="dependency-item"><div class="dependency-heading">' + link(name) + '<code class="dependency-requirement">' + escape(dependency["requirement"]) + '</code></div><p class="dependency-policy">' + escape(" · ".join(conditions)) + '</p>'
            if dependency["features"]:
                section += '<p class="dependency-policy">Requested features: ' + escape(", ".join(dependency["features"])) + '</p>'
            section += '</li>'
        section += '</ul>'
    else:
        section += '<p class="dependency-note">No package dependencies declared.</p>'
    if features:
        section += '<details class="dependency-features"><summary>Feature options</summary><dl>'
        for name, members in features.items():
            section += '<dt><code>' + escape(name) + '</code>' + ('<span class="dependency-policy">Enabled unless disabled</span>' if name == "default" else '') + '</dt><dd>'
            if members:
                section += '<ul>'
                for member in members:
                    if member.startswith("dep:"):
                        text = 'Enable dependency ' + link(member[4:])
                    elif "/" in member:
                        dependency, _, feature = member.rpartition("/")
                        text = 'Request <code>' + escape(feature) + '</code> from ' + link(dependency)
                    else:
                        text = 'Enable feature <code>' + escape(member) + '</code>'
                    section += '<li>' + text + '</li>'
                section += '</ul>'
            else:
                section += '<p class="dependency-note">No additional package requirements.</p>'
            section += '</dd>'
        section += '</dl></details>'
    else:
        section += '<p class="dependency-note">No feature options declared.</p>'
    return section + '<p class="dependency-note">Direct declarations from this checked source archive. They do not describe resolved transitive dependencies or executable contents.</p></section>'


def _artifacts(record: dict, indexed: dict, prefix: str, *, delivery=False, dependency_sources=None,
               package_names=frozenset()) -> str:
    artifacts = indexed["artifacts"]
    cards = []
    for item in artifacts:
        registry.artifact_url(item["url"])
        kind, target = item["kind"], item["target"]
        identifier = kind + "-" + target
        filename = urlsplit(item["url"]).path.rsplit("/", 1)[1]
        label = "Executable" if kind == "executable" else "Source archive"
        architecture = target_metadata.architecture_for_target(target)
        facts = [("Architecture", target_metadata.ARCHITECTURES[architecture] + " (" + architecture + ")")] if architecture else []
        data = _facts(facts + [("Target", target), ("Format", kind), ("Size", str(item["bytes"]) + " bytes")], "package-artifact-facts")
        if not record["yanked"] and indexed.get("evidence", {}).get("artifacts") == "validated":
            if delivery:
                import artifact_delivery
                destination = prefix + artifact_delivery.route(record, item).lstrip("/")
            else:
                destination = item["url"]
            action = _anchor("Download " + label.lower(), destination)
        else:
            action = '<code>' + escape(item["url"]) + '</code>'
            if not record["yanked"]:
                status = _evidence_label(indexed.get("evidence", {}).get("artifacts"))
                action += '<span>Artifact byte check: ' + status + '. Read the ' + _anchor("release record", prefix + record_route(record)) + ' for the declared URL.</span>'
        command = ''
        if not record["yanked"]:
            value = f"asm fetch {record['name']}@{record['version']} --target {target} --kind {kind}"
            command = f'<div class="command-block"><div class="command-block-heading"><span>Fetch this file</span><button class="copy-button" type="button" data-copy="fetch-{identifier}" aria-label="Copy fetch command for {kind} {target}">Copy</button></div><pre tabindex="0"><code id="fetch-{identifier}">{escape(value)}</code></pre></div>'
        declarations = ''
        if kind == "source":
            metadata = (dependency_sources or {}).get((record["name"], record["version"], target, item["sha256"]))
            declarations = _dependency_markup(metadata, prefix, package_names)
        cards.append(f'<article class="package-artifact" id="artifact-{identifier}" data-artifact-kind="{kind}" data-artifact-target="{target}" data-artifact-architecture="{architecture or ""}"><header><h3>{label}</h3><code>{escape(filename)}</code></header>{data}<p class="package-digest"><span>SHA-256</span><code>{item["sha256"]}</code></p><p class="package-artifact-action">{action}</p>{command}{declarations}</article>')
    status = f'<p id="artifact-filter-status" role="status" aria-live="polite">{len(cards)} release files shown.</p>'
    empty = '<p class="package-artifact-empty" hidden role="status">No files match. Clear the file filters.</p>'
    return status + '<div class="package-artifacts">' + "".join(cards) + '</div>' + empty


def _package_body(repo: Path, route: str, name: str, records: list[dict], selected: dict | None,
                  indexed_versions: dict, counts: dict, exact: bool, cache: dict, *, delivery=False,
                  activity=None, publications=None, dependency_sources=None, package_names=frozenset(), topics=None) -> str:
    prefix = "../" * route.count("/")
    owner = name.split("/")[0]
    trail = [("Packages", prefix + "packages/"), (owner, prefix + "packages/" + owner + "/")]
    if exact:
        trail.append((name, prefix + package_route(name)))
    trail.append((selected["version"] if exact else name, None))
    breadcrumbs = _breadcrumbs(trail, back_search=prefix + "index.html#catalog")
    summary = selected["summary"] if selected else "This package has no active release. Select an exact release from its history."
    release = ("Yanked release" if selected["yanked"] else "Active release") if selected else "No active release"
    alert = ''
    if selected and selected["yanked"]:
        alert = '<div class="package-alert"><p>Yanked: ' + escape(selected["yank_reason"]) + '</p><p>Fetch commands and download links are unavailable for this release.</p></div>'
    elif selected is None:
        alert = '<p class="package-alert">No active release is available. The version history retains the published records.</p>'
    indexed = indexed_versions.get(selected["version"]) if selected else None
    targets = sorted({item["target"] for item in indexed["artifacts"]}) if indexed else []
    kinds = sorted({item["kind"] for item in indexed["artifacts"]}) if indexed else []
    facts = _facts([("Version", selected["version"] if selected else "No active release"),
                    ("License", selected["license"] if selected else "Select an exact release"),
                    ("Formats", ", ".join("Executable" if kind == "executable" else "Source archive" for kind in kinds) if selected else "Select an exact release")], "package-facts")
    if selected:
        facts += '<div class="package-target-summary"><span>Release targets</span><ul>' + ''.join('<li><code>' + escape(target) + '</code></li>' for target in targets) + '</ul></div>'
    identity = '<span class="package-owner">' + escape(owner) + '/</span>' + escape(name.split('/')[1])
    heading = f'<header class="package-heading"><div class="package-title-row"><h1 class="package-identity">{identity}</h1><p class="package-release-label">{escape(release)}</p></div><p class="package-summary">{escape(summary)}</p>{alert}{facts}</header>'
    nav = '<nav class="package-section-nav" aria-label="Package sections">' + "".join(_anchor(label, "#" + identifier) for identifier, label in (("use", "Use"), ("readme", "Readme"), ("files", "Files"), ("evidence", "Evidence"), ("versions", "Versions"), ("activity", "Downloads"))) + '</nav>'
    readme = '<section id="readme" class="package-section"><h2>Readme</h2>' + _readme(repo, selected, cache) + '</section>'
    files = '<section id="files" class="package-section"><h2>Files</h2>' + (_artifacts(selected, indexed, prefix, delivery=delivery, dependency_sources=dependency_sources, package_names=package_names) if selected else '<p>Select an exact release to inspect its files.</p>') + '</section>'
    evidence = _facts([(label, _evidence_label((indexed or {}).get("evidence", {}).get(key)))
                       for key, label in EVIDENCE.items()], "package-evidence-list")
    evidence = '<section id="evidence" class="package-section"><h2>Release evidence</h2>' + evidence + '<p class="package-note">A digest identifies bytes. A matching digest does not establish publisher identity or general software safety.</p><p class="package-note">The registry record does not declare ABI or required CPU features. Read package documentation.</p>'
    if selected and not any(item["kind"] == "source" for item in indexed["artifacts"]):
        evidence += '<p class="package-note">Dependency information unavailable. This release has no checked source archive.</p>'
    evidence += '</section>'
    history = '<section id="versions" class="package-section"><h2>Versions</h2>' + _history(name, records, route) + '</section>'
    use = '<section id="use" class="package-section"><h2>Use this package</h2>'
    if selected and not selected["yanked"]:
        use += '<p>' + _anchor("Install Asm", "https://github.com/stubbi/asm#install-the-command") + ' before you fetch a file. Run <code>asm doctor</code> to check the required host tools.</p>' + _quick_fetch(selected, indexed) + '<p class="package-use-note">Fetch downloads and checks bytes. It does not execute the package.</p>' + _anchor("Inspect release files", "#files", attrs=' class="text-link"')
    else:
        use += '<p>Fetch commands are unavailable. Read the version history and release records.</p>'
    use += '</section>'
    source = '<section id="source" class="package-section"><h2>Source</h2>'
    if selected:
        source += '<p>' + _anchor("Source repository", selected["source"]["repository"]) + '</p>' + _facts([("Source commit", selected["source"]["commit"]), ("Source path", selected["source"]["path"])], "package-source-facts")
        source += '<p>' + _anchor("Browse source at this commit", _source_url(selected)) + '</p>'
        source += '<p>' + _anchor("Release record (JSON)", prefix + record_route(selected)) + '</p>'
    else:
        source += '<p>Select an exact release to inspect its source and record.</p>'
    source += '<p class="package-note" data-downloads-name="' + escape(name, quote=True) + '" data-downloads-version="' + (escape(selected["version"], quote=True) if selected and exact else '') + '">' + counts_html(counts, name, selected["version"] if selected and exact else None) + '</p><p class="package-note">The namespace is a package name prefix, not an authenticated publisher profile.</p></section>'
    if publications:
        entry = next((item for item in publications.get("packages", []) if item["name"] == name), {})
        if entry.get("publication_source") == "github-release":
            values = [(label, _discovery_instant(entry[key]).strftime("%d %b %Y").lstrip("0")) for key, label in (("first_published_at", "First GitHub release"), ("last_published_at", "Latest GitHub release")) if entry.get(key)]
            if values:
                source += '<section class="package-section"><h2>Package publication</h2>' + _facts(values, "package-source-facts") + '<p class="package-note">Package-wide history from GitHub release availability. These dates do not identify this selected version.</p></section>'
    if not exact and selected:
        source += _topic_links(topics, prefix)
    import package_activity
    version = selected["version"] if selected and exact else None
    activity_route = prefix + "registry/v1/activity/" + name + ("/" + version if version else "") + ".json"
    graph = ('<!-- package-activity:start ' + name + ' ' + (version or '') + ' -->' +
             package_activity.render_activity(activity, prefix + "discovery/", activity_route) + '<!-- package-activity:end -->')
    return breadcrumbs + heading + nav + '<div class="package-layout"><div class="package-primary">' + use + readme + files + evidence + history + graph + '</div><aside class="package-sidebar">' + source + '</aside></div>'


def write_package_pages(repo: Path, stage: Path, records: list[dict], index: dict, counts: dict, *, delivery=False,
                        activities=None, publications=None, dependency_metadata=None) -> list[str]:
    """Write catalog, namespace, overview, exact release, and 404 routes.

    Call after the stage's index and raw records exist. Returns root-relative
    routes without a leading slash. No original stage page is modified.
    """
    records = registry.check_records(records)
    registry.require(index.get("schema") == 1 and isinstance(index.get("packages"), list), "unsupported package index")
    chrome = _chrome(stage)
    grouped = {}
    for record in records: grouped.setdefault(record["name"], []).append(record)
    indexed = {package["name"]: package for package in index["packages"]}
    registry.require(set(indexed) == set(grouped), "package records and index differ")
    dependency_sources = _dependency_sources(dependency_metadata, index)
    classification = discovery_metadata.read_metadata(stage, index, "registry/v1/discovery-metadata.json")
    categories = read_discovery_categories(stage, index, "registry/v1/categories.json")
    topics = {}
    for item in classification["packages"]:
        if item["version"] is not None:
            package = indexed[item["name"]]
            selected = next(release for release in package["versions"] if release["version"] == item["version"])
            architectures = sorted({target_metadata.architecture_for_target(artifact["target"])
                                    for artifact in selected["artifacts"]} - {None})
            topics[item["name"]] = {"keywords": item["keywords"],
                "categories": [(category["id"], category["name"]) for category in categories if item["name"] in category["packages"]],
                "architectures": [(key, target_metadata.ARCHITECTURES[key] + " (" + key + ")") for key in architectures]}
    routes, cache = [], {}
    def write(route, title, description, body, missing=False, *, package=None, record=None):
        destination = stage / route if route.endswith(".html") else stage / route / "index.html"
        schema = _package_schema(route, package, description, record) if package else None
        if schema is not None and record is not None and route == package_route(package):
            schema["keywords"] = topics[package]["keywords"]
        metadata_url = "../" * route.count("/") + record_route(record) if record else None
        registry.write_atomic(destination, _page(route, title, description, body, chrome, missing=missing,
                                               structured_data=schema, metadata_url=metadata_url).encode())
        routes.append(route)
    def listing(names, route):
        prefix = "../" * route.count("/")
        rows = []
        for name in sorted(names):
            latest = next((record for record in grouped[name] if not record["yanked"]), None)
            summary = latest["summary"] if latest else "No active release. Inspect the version history."
            version = latest["version"] if latest else "No active release"
            version_link = _anchor(version, prefix + package_route(name, version), package=True, attrs=' class="package-version"') if latest else '<span class="package-version">No active release</span>'
            rows.append('<li class="package-catalog-item"><div class="package-result-heading">' + _anchor(name, prefix + package_route(name), package=True, attrs=' class="package-catalog-name"') + version_link + '</div><p>' + escape(summary) + '</p>' + _preview_metadata(latest) + '</li>')
        return '<ul class="package-catalog">' + "".join(rows) + '</ul>' if rows else '<p class="package-empty">The registry has no published packages yet.</p>'
    for name, releases in grouped.items():
        releases.sort(key=lambda record: registry.version_tuple(record["version"]), reverse=True)
        matches = {version["version"]: version for version in indexed[name]["versions"]}
        registry.require(len(matches) == len(releases), "package versions and index differ")
        for record in releases:
            version = matches.get(record["version"])
            registry.require(version is not None and sorted(version["artifacts"], key=lambda a: (a["target"], a["kind"])) == sorted(record["artifacts"], key=lambda a: (a["target"], a["kind"])), "index artifacts differ from the release record")
        selected = next((record for record in releases if not record["yanked"]), None)
        registry.require(indexed[name]["latest"] == (selected["version"] if selected else None), "index latest release differs")
        route = package_route(name)
        write(route, name, _release_description(name, selected), _package_body(repo, route, name, releases, selected, matches, counts, False, cache, delivery=delivery,
              activity=(activities or {}).get((name, None)), publications=publications,
              dependency_sources=dependency_sources, package_names=set(indexed), topics=topics.get(name)), package=name, record=selected)
        for record in releases:
            route = package_route(name, record["version"])
            write(route, name + "@" + record["version"], _release_description(name, record, exact=True), _package_body(repo, route, name, releases, record, matches, counts, True, cache, delivery=delivery,
                  activity=(activities or {}).get((name, record["version"])), publications=publications,
                  dependency_sources=dependency_sources, package_names=set(indexed)), package=name, record=record)
    write("packages/", "Assembly packages", "Browse the Asm assembly package catalog. Compare package purposes, exact releases, licenses, and declared targets, then inspect source and release evidence.", '<header class="package-heading"><h1>Assembly packages</h1><p>Inspect package records, targets, and release evidence.</p></header>' + listing(grouped, "packages/"))
    for owner in sorted({name.split("/")[0] for name in grouped}):
        route = "packages/" + owner + "/"
        write(route, owner + " assembly packages", "Browse assembly packages in the " + owner + " namespace. Inspect exact versions, licenses, targets, and source records. A namespace is a package name prefix.", _breadcrumbs([("Packages", "../../packages/"), (owner, None)]) + '<header class="package-heading"><h1>' + escape(owner) + '</h1><p>This namespace is a package name prefix, not an authenticated publisher profile.</p></header>' + listing([name for name in grouped if name.split("/")[0] == owner], route))
    write("404.html", "Page not found", "The requested Asm page was not found.", '<section class="package-empty"><h1>Page not found</h1><p>Check the address or browse the available packages.</p>' + _anchor("Browse packages", "/packages/", attrs=' class="button button-primary"', package=True) + _anchor("Asm home", "/index.html", attrs=' class="text-link"') + '</section>', missing=True)
    return routes


def catalog_stats(index: dict) -> dict:
    """Count retained identities, not adoption or supported CLI hosts."""
    registry.require(index.get("schema") == 1 and isinstance(index.get("packages"), list), "invalid statistics catalog")
    names, releases, files, targets = set(), set(), set(), set()
    for package in index["packages"]:
        name = registry.package_name(package["name"])
        names.add(name)
        for release in package["versions"]:
            version = release["version"]
            registry.version_tuple(version)
            releases.add((name, version))
            for artifact in release["artifacts"]:
                registry.require(artifact["target"] in registry.TARGETS and artifact["kind"] in registry.KINDS,
                                 "invalid statistics artifact")
                files.add((name, version, artifact["kind"], artifact["target"]))
                targets.add(artifact["target"])
    return {"packages": len(names), "releases": len(releases), "files": len(files), "targets": len(targets)}


def write_catalog_stats(stage: Path, index: dict) -> None:
    """Make truthful totals available before scripts or network requests."""
    content = registry.read_regular(stage, "index.html", 512 * 1024).decode("utf-8")
    for key, value in catalog_stats(index).items():
        pattern = r'(<dd data-catalog-stat="' + key + r'">).*?(</dd>)'
        content, count = re.subn(pattern, lambda match: match[1] + count_html(value) + match[2], content, flags=re.S)
        registry.require(count == 1, "homepage needs one statistic for " + key)
    registry.write_atomic(stage / "index.html", content.encode("utf-8"))



# Discovery is a versioned sidecar. It never changes published release records.
def _categories(value: dict, index: dict) -> list[dict]:
    registry.require(isinstance(value, dict) and set(value) == {"schema", "categories"}
                     and type(value["schema"]) is int and value["schema"] == 1,
                     "unsupported discovery categories")
    entries = value["categories"]
    registry.require(isinstance(entries, list) and len(entries) <= 32, "too many discovery categories")
    known = {item["name"]: item for item in index["packages"]}
    result, identifiers = [], set()
    for item in entries:
        registry.require(isinstance(item, dict) and set(item) == {"id", "name", "packages"}, "invalid discovery category")
        identifier, label, names = item["id"], item["name"], item["packages"]
        registry.require(isinstance(identifier, str) and re.fullmatch(r"[a-z][a-z0-9-]{0,39}", identifier)
                         and not identifier.endswith("-") and "--" not in identifier and identifier not in identifiers,
                         "invalid discovery category identity")
        registry.require(isinstance(label, str) and 0 < len(label) <= 80 and label == label.strip()
                         and all(ord(c) >= 32 and ord(c) != 127 for c in label), "invalid discovery category name")
        registry.require(isinstance(names, list) and len(names) <= len(known)
                         and all(isinstance(name, str) and name in known for name in names)
                         and len(names) == len(set(names)), "invalid discovery category packages")
        identifiers.add(identifier)
        active = sorted(name for name in names if known[name].get("latest") is not None)
        if active:
            result.append({"id": identifier, "name": label, "packages": active})
    return result


def read_discovery_categories(root: Path, index: dict, filename="discovery-categories.json") -> list[dict]:
    if not (root / filename).exists() and not (root / filename).is_symlink():
        return []
    value = registry.strict_json(registry.read_regular(root, filename, 64 * 1024))
    return _categories(value, index)


def with_discovery_categories(site: Path, index: dict, snapshot: dict) -> dict:
    return {**snapshot, "categories": read_discovery_categories(site, index, "registry/v1/categories.json")}


def _discovery_instant(value: str) -> datetime:
    try:
        registry.require(isinstance(value, str) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z", value), "invalid discovery timestamp")
        instant = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise registry.RegistryError("invalid discovery timestamp") from error
    return instant


def _discovery_date(value: str) -> str:
    instant = _discovery_instant(value)
    return f'<time datetime="{value}">{instant.strftime("%d %b %Y").lstrip("0")}</time>'


def discovery_page(stage: Path, index: dict, snapshot: dict, kind: str) -> str:
    """Render one read-only feed with the same chrome as every package page."""
    if kind not in {"popular", "new", "updated", "metrics"} and not kind.startswith("categories/"):
        raise KeyError(kind)
    snapshot = with_discovery_categories(stage, index, snapshot)
    registry.require(snapshot.get("schema") == 1 and snapshot.get("policy") == "asm-deliveries-v1"
                     and snapshot.get("source") == "asm-delivery-events" and isinstance(snapshot.get("packages"), list)
                     and isinstance(snapshot.get("feeds"), dict), "unsupported discovery snapshot")
    indexed = {item["name"]: item for item in index["packages"]}
    facts = {item["name"]: item for item in snapshot["packages"]}
    registry.require(len(facts) == len(snapshot["packages"]) and set(facts) == set(indexed), "discovery packages differ from the index")
    route = "discovery/" if kind == "metrics" else "browse/" + kind + "/"
    prefix = "../" * route.count("/")
    category = None
    if kind.startswith("categories/"):
        category = next((item for item in snapshot["categories"] if item["id"] == kind.split("/", 1)[1]), None)
        if category is None:
            raise KeyError(kind)
    titles = {"popular": "Most downloaded", "new": "New packages", "updated": "Recently updated", "metrics": "Discovery data"}
    title = category["name"] if category else titles[kind]
    descriptions = {"popular": "Downloads · Last 30 days", "new": "First GitHub release, newest first.",
                    "updated": "Package release activity, newest publication first.", "metrics": "The sources, coverage, and limits behind Popular and New packages."}
    description = "Assembly packages by purpose." if category else descriptions[kind]
    navigation = '<nav class="package-section-nav" aria-label="Browse packages">' + "".join(
        _anchor(label, prefix + target, attrs=' aria-current="page"' if selected == kind else '')
        for label, target, selected in (("Explore", "explore/", "explore"), ("All packages", "packages/", "all"), ("Most downloaded", "browse/popular/", "popular"),
                                        ("New", "browse/new/", "new"), ("Recently updated", "browse/updated/", "updated"))) + '</nav>'
    body = '<header class="package-heading"><h1>' + escape(title) + '</h1><p>' + escape(description) + '</p></header>' + navigation
    observed = snapshot.get("observed_at")
    if observed:
        body += '<p class="package-note">Observed ' + _discovery_date(observed) + ' at ' + escape(observed[11:19]) + ' UTC.'
        if snapshot.get("stale"):
            body += ' This observation is stale. A refresh is pending or failed.'
        body += ' ' + _anchor("About these numbers", prefix + "discovery/") + '</p>'
    elif kind == "popular":
        body += '<p class="package-note">Download data is unavailable. Browse all packages or try again after a refresh.</p>'
    if kind == "popular" and snapshot.get("collection_started_at"):
        body += '<p class="package-note">Collecting downloads since ' + _discovery_date(snapshot["collection_started_at"]) + '. '
        body += ('The full window is covered.' if snapshot.get("coverage", {}).get("complete") else 'The 30-day history is incomplete. Counts are observed minimums.') + '</p>'
    if kind == "metrics":
        window = snapshot.get("window", {})
        interval = (escape(str(window.get("start"))) + ' through ' + escape(str(window.get("end")))) if observed else 'Unavailable'
        body += '''<div class="discovery-explanation"><section class="package-section"><h2>Downloads</h2>
<p>Popular uses completed transfers reported by Asm’s delivery service. The artifact’s storage provider does not supply the ranking counter.</p>
<p>Each event identifies the exact package, version, target, format, byte length, and SHA-256 digest selected for delivery.</p>
<p>A full response counts only after the service writes and flushes all declared bytes. This does not prove that a client saved or verified them.</p>
<p>Head requests, redirects, incomplete transfers, range responses, conditional responses, known bots, and internal validation do not enter Popular.</p>
<p>Repeated full requests count as separate transfers. Replayed event identifiers count once; conflicting event contents are rejected.</p>
<p>Unidentified automation can still contribute. Transfers do not measure people, installations, suitability, or safety.</p>
<p>The rolling window covers 30 days through the reporting watermark. The ≥ symbol marks an incomplete observation window.</p>
<p>New collection, server downtime, and reporting failures create coverage gaps. Missing reports never become zero downloads.</p>
<p>Only positive observed totals enter Popular. Equal totals use the canonical package name as a stable tie-breaker.</p>
<p>Downloads outside Asm’s observed delivery sources are outside this metric. Missing mirror reports do not establish global volume.</p>
<p>The local service records anonymous delivery events without cookies, fingerprints, IP addresses, user-agent strings, or search terms.</p>
<p>Reporting failures leave artifact delivery available and make the metric stale or incomplete. Search and exact package access remain separate.</p>
</section><section class="package-section"><h2>Publication dates</h2>
<p>New packages currently uses the first matching public GitHub release across each legacy package’s registered history.</p>
<p>These historical dates are separate from download measurement. GitHub download counters never enter Popular.</p>
<p>Recently updated uses the latest active release when its availability is later than the package’s first release.</p>
<p>Registry admission events require the separate authenticated publication service. Historical imports do not invent those events.</p>
<p>Yanking does not reset a package’s first date. Packages without active releases leave discovery while their version records remain available.</p>
</section><section class="package-section"><h2>Source and observation</h2>'''
        body += '<dl class="package-source-facts"><div><dt>Policy</dt><dd>asm-deliveries-v1</dd></div><div><dt>UTC window</dt><dd><code>' + interval + '</code></dd></div></dl>'
        body += '<p>' + _anchor("Read the discovery snapshot", prefix + "registry/v1/discovery.json") + '</p><p>Sponsorship does not influence ranking.</p></section></div>'
    else:
        names = category["packages"] if category else snapshot["feeds"].get(kind)
        registry.require(isinstance(names, list) and len(names) <= len(indexed)
                         and all(isinstance(name, str) and name in indexed and indexed[name].get("latest") for name in names)
                         and len(names) == len(set(names)), "invalid discovery feed")
        rows = []
        for name in names:
            item, fact = indexed[name], facts[name]
            latest = next((version for version in item["versions"]
                           if version["version"] == item["latest"] and not version["yanked"]), None)
            registry.require(latest is not None and latest["artifacts"], "discovery package has no active release artifacts")
            targets = sorted({artifact["target"] for artifact in latest["artifacts"]})
            metadata = ['<span>Latest version ' + escape(item["latest"]) + '</span>', '<span>' + escape(' · '.join(targets)) + '</span>']
            if kind == "popular":
                count = fact.get("downloads_30d")
                exact = fact.get("downloads_30d_exact")
                registry.require(type(count) is int and 0 <= count <= 9007199254740991 and type(exact) is bool, "invalid discovery count")
                metadata.append('<span>' + count_html(count, lower_bound=not exact) + ' downloads</span>')
            elif not category:
                value = fact.get("first_published_at" if kind == "new" else "last_published_at")
                publication_cutoff = snapshot.get("publication_observed_at") or observed
                limit = _discovery_instant(publication_cutoff) if publication_cutoff else datetime.now(timezone.utc)
                registry.require(isinstance(value, str) and _discovery_instant(value) <= limit, "invalid discovery publication date")
                metadata.append('<span>' + ('First GitHub release ' if kind == 'new' else 'Latest GitHub release ') + _discovery_date(value) + '</span>')
            rows.append('<li class="package-catalog-item">' + _anchor(name, prefix + package_route(name), package=True, attrs=' class="package-catalog-name"') + '<p>' + escape(item["summary"]) + '</p><div class="package-catalog-meta">' + ''.join(metadata) + '</div></li>')
        if rows:
            body += '<ul class="package-catalog">' + ''.join(rows) + '</ul>'
        else:
            message = ("Download measurements are unavailable." if observed is None else "No completed downloads were recorded for this observation period.") if kind == "popular" else "No packages have publication data for this feed yet."
            body += '<p class="package-empty">' + message + ' ' + _anchor("Browse all packages", prefix + 'packages/') + '.</p>'
    meta_titles = {"popular": "Most downloaded assembly packages", "new": "New assembly packages",
                   "updated": "Recently updated assembly packages", "metrics": "Package discovery data and coverage"}
    meta_descriptions = {
        "popular": "Explore assembly packages by observed Asm downloads during the last 30 days. Check the reporting cutoff, coverage, targets, and exact releases.",
        "new": "Discover new assembly packages in Asm, ordered by their first recorded GitHub release. Inspect each package's purpose, targets, and exact versions.",
        "updated": "Browse recently updated assembly packages by their latest recorded publication. Inspect release versions, targets, source, and available evidence.",
        "metrics": "Understand Asm package discovery: completed download transfers, publication dates, observation windows, missing data, and ranking limits."}
    meta_title = category["name"] + " assembly packages" if category else meta_titles[kind]
    meta_description = ("Browse assembly packages in the " + category["name"] + " category. Compare purposes and declared targets, then inspect exact versions, source, and release evidence.") if category else meta_descriptions[kind]
    return _page(route, meta_title, meta_description, body, _chrome(stage), active_nav="Stats" if kind == "metrics" else "Explore")


def write_discovery_pages(stage: Path, index: dict, snapshot: dict) -> list[str]:
    enriched = with_discovery_categories(stage, index, snapshot)
    kinds = ["popular", "new", "updated", "metrics"] + ["categories/" + item["id"] for item in enriched["categories"]]
    routes = []
    for kind in kinds:
        route = "discovery/" if kind == "metrics" else "browse/" + kind + "/"
        registry.write_atomic(stage / route / "index.html", discovery_page(stage, index, enriched, kind).encode())
        routes.append(route)
    return routes
