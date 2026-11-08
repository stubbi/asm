"""Render native discovery routes from accepted releases and scoped sidecars.

This module reads no remote data and never executes or downloads a package.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

from datetime import datetime, timezone
from html import escape
from pathlib import Path
import re
from urllib.parse import quote

import package_pages
import registry
from count_format import count_html
import discovery_metadata
from target_metadata import ARCHITECTURES, architecture_for_target, architecture_groups

MAX_COUNT = 9007199254740991
ID = re.compile(r"[a-z][a-z0-9-]{0,39}\Z")
BASE = ("explore", "categories", "keywords", "architectures", "depended-on", "downloaded")


def _identifier(value):
    return isinstance(value, str) and ID.fullmatch(value) is not None and not value.endswith("-") and "--" not in value


def _count(value):
    registry.require(type(value) is int and 0 <= value <= MAX_COUNT, "invalid discovery count")
    return value


def _active(index):
    registry.require(type(index.get("schema")) is int and index["schema"] == 1
                     and isinstance(index.get("packages"), list) and len(index["packages"]) <= registry.MAX_ROWS,
                     "unsupported Explore index")
    active, names = {}, set()
    for package in index["packages"]:
        name = registry.package_name(package["name"])
        registry.require(name not in names, "duplicate Explore package")
        names.add(name)
        if package.get("latest") is None: continue
        registry.version_tuple(package["latest"])
        versions = package.get("versions")
        registry.require(isinstance(versions, list) and len(versions) <= registry.MAX_ROWS, "invalid Explore release list")
        matches = [item for item in versions if item.get("version") == package["latest"] and item.get("yanked") is False]
        registry.require(len(matches) == 1 and isinstance(matches[0].get("artifacts"), list) and matches[0]["artifacts"],
                         "Explore package lacks its latest active artifacts")
        targets = set()
        for artifact in matches[0]["artifacts"]:
            registry.require(artifact.get("target") in registry.TARGETS and artifact.get("kind") in registry.KINDS,
                             "invalid Explore artifact")
            registry.artifact_url(artifact.get("url"))
            targets.add(artifact["target"])
        registry.require(isinstance(package.get("summary"), str) and len(package["summary"]) <= 160,
                         "invalid Explore summary")
        active[name] = {"summary": package["summary"], "version": package["latest"], "targets": sorted(targets)}
    return active, names


def _names(values, active):
    registry.require(isinstance(values, list) and len(values) <= len(active)
                     and all(isinstance(name, str) and name in active for name in values)
                     and len(values) == len(set(values)), "invalid Explore package membership")
    return values


def _inputs(stage, index, snapshot, metadata, retained):
    active, all_names = _active(index)
    registry.require(snapshot.get("schema") == 1 and snapshot.get("policy") == "asm-deliveries-v1"
                     and snapshot.get("source") == "asm-delivery-events"
                     and isinstance(snapshot.get("packages"), list) and isinstance(snapshot.get("feeds"), dict),
                     "unsupported Explore activity source")
    facts = {row["name"]: row for row in snapshot["packages"]}
    registry.require(len(facts) == len(snapshot["packages"]) and set(facts) == all_names,
                     "Explore activity differs from the accepted index")
    for kind in ("new", "popular", "updated"): _names(snapshot["feeds"].get(kind), active)
    raw_categories = snapshot.get("categories")
    if raw_categories is None:
        raw_categories = package_pages.with_discovery_categories(stage, index, snapshot)["categories"]
    categories = package_pages._categories({"schema": 1, "categories": raw_categories}, index)
    registry.require(metadata.get("schema") == 1 and isinstance(metadata.get("keywords"), list)
                     and len(metadata["keywords"]) <= discovery_metadata.MAX_TOTAL_KEYWORDS
                     and isinstance(metadata.get("dependents"), list) and len(metadata["dependents"]) <= len(active),
                     "unsupported Explore relationship metadata")
    keywords = {}
    for row in metadata["keywords"]:
        registry.require(_identifier(row.get("id")) and row["id"] not in keywords
                         and isinstance(row.get("name"), str) and 0 < len(row["name"]) <= 80,
                         "invalid Explore keyword")
        _names(row.get("packages"), active)
        registry.require(_count(row.get("package_count")) == len(row["packages"]), "keyword count differs from its membership")
        if row["packages"]: keywords[row["id"]] = row
    dependents = {}
    for row in metadata["dependents"]:
        registry.require(row.get("name") in active and row["name"] not in dependents and type(row.get("exact")) is bool,
                         "invalid Explore dependency identity")
        _names(row.get("packages"), active)
        if row.get("count") is not None:
            registry.require(_count(row["count"]) == len(row["packages"]), "dependency count differs from its membership")
        else:
            registry.require(not row["packages"] and not row["exact"], "unknown dependency count has declared members")
        dependents[row["name"]] = row
    coverage = metadata.get("dependency_coverage")
    registry.require(isinstance(coverage, dict) and _count(coverage.get("total")) == len(active)
                     and _count(coverage.get("known")) <= coverage["total"]
                     and type(coverage.get("complete")) is bool and coverage["complete"] == (coverage["known"] == coverage["total"]),
                     "invalid dependency declaration coverage")
    registry.require(retained.get("schema") == 1 and retained.get("source") == "asm-delivery-events"
                     and retained.get("policy") == "asm-deliveries-v1" and retained.get("scope") == "since-collection"
                     and isinstance(retained.get("packages"), dict)
                     and type(retained.get("complete")) is bool and type(retained.get("stale")) is bool,
                     "unsupported retained download scope")
    return active, facts, keywords, dependents, categories


def _card(prefix, name, signal, package, architecture=None):
    targets = ' · '.join('<span class="discovery-target">' + escape(value) + '</span>' for value in package["targets"])
    context = ""
    if architecture is not None:
        registry.require(architecture in ARCHITECTURES, "unsupported package architecture context")
        context = '#from=' + quote('#search?architecture=' + architecture + '&all=1', safe='')
    return ('<li><a class="discovery-item" href="' + prefix + package_pages.package_route(name) + context + '">'
            '<span class="discovery-name">' + escape(name) + '</span><span class="discovery-signal">' + signal + '</span>'
            '<span class="discovery-summary">' + escape(package["summary"]) + '</span><span class="discovery-targets">'
            '<span class="discovery-version">' + escape(package["version"]) + '</span> · ' + targets + '</span></a></li>')


def _package_cards(prefix, names, active, signals, *, architecture=None):
    return '<ul class="discovery-items">' + ''.join(_card(prefix, name, signals.get(name, ""), active[name], architecture) for name in names) + '</ul>'


def _directory_cards(prefix, entries, group):
    return '<ul class="discovery-items discovery-topics">' + ''.join(
        '<li><a class="discovery-item discovery-topic" href="' + prefix + 'browse/' + group + '/' + row["id"] + '/"><span class="discovery-name">' + escape(row["name"]) +
        '</span><span class="discovery-signal">' + count_html(len(row["packages"])) + (' package' if len(row["packages"]) == 1 else ' packages') +
        '</span></a></li>'
        for row in entries) + '</ul>'


def _time(value):
    instant = package_pages._discovery_instant(value)
    return '<time datetime="' + value + '">' + instant.strftime("%Y-%m-%d at %H:%M:%S UTC") + '</time>'


def _download_note(snapshot, prefix, *, retained=False):
    if snapshot.get("observed_at") is None:
        return '<p class="package-note">Download data is unavailable. Missing observations do not establish zero downloads.</p>'
    start = snapshot.get("collection_started_at")
    note = ('Since collection started ' + _time(start) + '. ' if retained and start else '')
    note += 'Reporting cutoff: ' + _time(snapshot["observed_at"]) + '. '
    complete = snapshot.get("complete") if retained else snapshot.get("coverage", {}).get("complete")
    note += ('The stated period is fully covered.' if complete else 'Coverage is incomplete. Counts are observed minimums.')
    if snapshot.get("stale"): note += ' These observations are stale.'
    note += ' ' + package_pages._anchor("Discovery data and coverage", prefix + "discovery/")
    return '<p class="package-note">' + note + '</p>'


def _dependency_note(metadata):
    coverage = metadata["dependency_coverage"]
    return ('<p class="package-note">Dependency declarations are known for ' + count_html(coverage["known"]) + ' of ' + count_html(coverage["total"]) +
            ' active packages. ' + ('Coverage is complete.' if coverage["complete"] else 'Coverage is incomplete; unknown declarations do not establish zero dependents.') +
            ' Counts describe distinct active packages with declared direct dependencies. They do not establish suitability or safety.</p>')


def _render_explore(stage: Path, index: dict, snapshot: dict | None, metadata: dict | None, retained: dict | None, kind="explore") -> tuple[str, bool]:
    """Render a document and derive indexing eligibility from its actual rows."""
    keyword = kind.split("/", 1)[1] if isinstance(kind, str) and kind.startswith("keywords/") else None
    architecture = kind.split("/", 1)[1] if isinstance(kind, str) and kind.startswith("architectures/") else None
    if kind not in BASE and not _identifier(keyword) and architecture not in ARCHITECTURES: raise KeyError(kind)
    if kind == "architectures" or architecture is not None:
        # Architecture membership depends only on accepted active artifacts.
        active, _ = _active(index)
        facts, keywords, dependents, categories = {}, {}, {}, []
    else:
        active, facts, keywords, dependents, categories = _inputs(stage, index, snapshot, metadata, retained)
    if keyword is not None and keyword not in keywords: raise KeyError(kind)
    architectures = [{**group, "name": group["name"] + ' (' + group["id"] + ')'} for group in architecture_groups(index)]
    architecture_map = {group["id"]: group for group in architectures}
    if architecture is not None and architecture not in architecture_map: raise KeyError(kind)
    route = "explore/" if kind == "explore" else "browse/" + kind + "/"
    prefix = "../" * route.count("/")
    titles = {"explore": "Explore packages", "categories": "Categories", "keywords": "Keywords", "architectures": "Architectures",
              "depended-on": "Most depended on", "downloaded": "Most downloaded packages"}
    title = (architecture_map[architecture]["name"] + " packages" if architecture else
             "Packages tagged " + keywords[keyword]["name"] if keyword else titles[kind])
    captions = {"explore": "Find packages by activity, purpose, and dependencies.",
                "categories": "Purpose categories, ranked by active package membership.",
                "keywords": "Declared keywords, ranked by active package membership.",
                "architectures": "Active packages grouped by their declared release targets.",
                "depended-on": "Declared direct dependencies of active packages.",
                "downloaded": "Since collection started · Asm completed transfers"}
    caption = ("Latest active releases with matching architecture artifacts." if architecture else
               "Active packages with this declared keyword." if keyword else captions[kind])
    page_titles = {"explore": "Explore assembly packages", "categories": "Assembly package categories",
                   "keywords": "Assembly package keywords", "architectures": "Assembly packages by architecture",
                   "depended-on": "Assembly packages by direct dependents",
                   "downloaded": "Package downloads since collection began"}
    descriptions = {
        "explore": "Compare assembly packages by release activity, purpose, architecture, and direct dependencies. Missing measurements and declaration coverage remain explicit.",
        "categories": "Browse purpose categories for active assembly packages. Category counts describe distinct package membership rather than popularity or compatibility.",
        "keywords": "Browse declared keywords attached to active assembly packages. Keyword counts describe package membership rather than search activity.",
        "architectures": "Browse active assembly packages by the architecture of their declared artifacts. Operating systems and artifact formats remain explicit.",
        "depended-on": "Find assembly packages used as direct dependencies of active releases. Check declared dependency coverage and source-bound package versions.",
        "downloaded": "Inspect Asm completed transfers since collection began. Rankings retain collection coverage and exclude unknown earlier or external-host activity.",
    }
    if architecture:
        label = architecture_map[architecture]["name"]
        page_title = label + " assembly packages"
        description = "Find active assembly packages with declared " + label + " artifacts. Compare operating systems, artifact formats, and exact versions before use."
    elif keyword:
        label = keywords[keyword]["name"]
        page_title = "Assembly packages tagged " + label
        description = 'Browse active assembly packages with the declared keyword "' + label + '". Keyword membership does not establish target compatibility or package quality.'
    else:
        page_title, description = page_titles[kind], descriptions[kind]
    body = '<header class="package-heading"><h1>' + escape(title) + '</h1><p>' + escape(caption) + '</p></header>'
    body += package_pages._browse_navigation(route, kind.split('/')[0])
    ranked_keywords = sorted(keywords.values(), key=lambda row: (-len(row["packages"]), row["id"]))
    ranked_categories = sorted(categories, key=lambda row: (-len(row["packages"]), row["id"]))
    depended = sorted((name for name, row in dependents.items() if row["count"] is not None and row["count"] > 0), key=lambda name: (-dependents[name]["count"], name))
    dependent_signals = {name: count_html(dependents[name]["count"], lower_bound=not dependents[name]["exact"]) +
                         (' dependent' if dependents[name]["count"] == 1 else ' dependents') for name in depended}
    indexable = True
    if kind == "explore":
        def group(key, heading, caption, destination, content, note=""):
            return ('<section class="discovery-group" aria-labelledby="explore-' + key + '"><div class="discovery-group-header"><div class="discovery-group-heading"><h2 id="explore-' + key + '">' +
                    package_pages._anchor(heading, prefix + destination, attrs=' class="discovery-heading-link" aria-label="View all ' + heading.lower() + '"') + '</h2></div>'
                    '<p class="discovery-group-caption">' + caption + '</p></div>' + content + note + '</section>')
        groups = []
        for key, heading, feed_caption in (("new", "New packages", "First GitHub release"), ("popular", "Most downloaded", "Last 30 days"), ("updated", "Recently updated", "Latest GitHub release")):
            names, signals = snapshot["feeds"][key], {}
            for name in names:
                if key == "popular":
                    count, exact = facts[name].get("downloads_30d"), facts[name].get("downloads_30d_exact")
                    registry.require(_count(count) > 0 and type(exact) is bool, "invalid positive download ranking")
                    signals[name] = count_html(count, lower_bound=not exact)
                else:
                    value = facts[name].get("first_published_at" if key == "new" else "last_published_at")
                    limit = snapshot.get("publication_observed_at") or snapshot.get("observed_at")
                    registry.require(package_pages._discovery_instant(value) <= (package_pages._discovery_instant(limit) if limit else datetime.now(timezone.utc)), "invalid publication cutoff")
                    signals[name] = package_pages._discovery_date(value)
            if key == "popular":
                empty = ("Download measurements are unavailable." if snapshot.get("observed_at") is None else
                         "No completed downloads were recorded in the observed part of this window." if not snapshot.get("coverage", {}).get("complete") else
                         "No completed downloads were recorded in the last 30 days.")
            else:
                empty = ("No active packages are available." if not active else
                         "No packages have a later published release yet." if key == "updated" and any(facts[name].get("last_published_at") for name in active) else
                         "Publication dates are unavailable for this list.")
            content = _package_cards(prefix, names[:5], active, signals) if names else '<p class="discovery-group-note">' + empty + '</p>'
            groups.append(group(key, heading, feed_caption, 'browse/' + key + '/', content))
        dependency_empty = ("Direct dependency declarations are unavailable." if metadata["dependency_coverage"]["known"] == 0 else
                            "No direct dependents appear in the available declarations.")
        groups.append(group("depended-on", "Most depended on", "Declared direct dependencies", "browse/depended-on/",
                            _package_cards(prefix, depended[:5], active, dependent_signals) if depended else '<p class="discovery-group-note">' + dependency_empty + '</p>'))
        for key, heading, rows in (("keywords", "Top keywords", ranked_keywords), ("categories", "Top categories", ranked_categories)):
            content = _directory_cards(prefix, rows[:5], key) if rows else '<p class="discovery-group-note">No ' + key + ' are declared for active packages.</p>'
            groups.append(group(key, heading, "Active package membership", 'browse/' + key + '/', content))
        architecture_content = (_directory_cards(prefix, architectures, "architectures") if architectures else
                                '<p class="discovery-group-note">No active packages declare a supported architecture.</p>')
        groups.append(group("architectures", "Browse by architecture", "Declared release targets", "browse/architectures/", architecture_content))
        body += ('<div class="discovery-groups">' + ''.join(groups[:3]) + '</div>'
                 '<div class="discovery-groups discovery-secondary">' + ''.join(groups[i] for i in (5, 6, 4, 3)) + '</div>'
                 + _download_note(snapshot, prefix) + _dependency_note(metadata))
    elif kind in {"categories", "keywords", "architectures"}:
        rows = architectures if kind == "architectures" else ranked_categories if kind == "categories" else ranked_keywords
        empty = "No active packages declare a supported architecture." if kind == "architectures" else "No " + kind + " are declared for active packages."
        body += _directory_cards(prefix, rows, kind) if rows else '<p class="package-empty">' + empty + '</p>'
    elif architecture:
        names = architecture_map[architecture]["packages"]
        matching = {name: {**active[name], "targets": [target for target in active[name]["targets"]
                                                    if architecture_for_target(target) == architecture]} for name in names}
        registry.require(all(matching[name]["targets"] for name in names), "architecture membership differs from its active artifacts")
        body += '<p class="package-note">Architecture groups come from declared release targets. Operating systems and artifact formats remain explicit.</p>'
        body += '<p>' + package_pages._anchor("Refine this architecture in search", prefix + "index.html#search?architecture=" + architecture + "&all=1", attrs=' class="text-link"') + '</p>'
        body += _package_cards(prefix, names, matching, {}, architecture=architecture)
    elif keyword:
        body += _package_cards(prefix, sorted(keywords[keyword]["packages"]), active, {})
    elif kind == "depended-on":
        indexable = bool(depended)
        body += _dependency_note(metadata)
        empty = ("Direct dependency declarations are unavailable." if metadata["dependency_coverage"]["known"] == 0 else
                 "No direct dependents appear in the available declarations.")
        body += _package_cards(prefix, depended, active, dependent_signals) if depended else '<p class="package-empty">' + empty + '</p>'
    else:
        body += _download_note(retained, prefix, retained=True)
        values = {}
        for name in active:
            count = retained["packages"].get(name, {}).get("total")
            if count is not None and _count(count) > 0:
                registry.require(retained.get("observed_at") is not None, "retained counts lack a reporting cutoff")
                values[name] = count
        names = sorted(values, key=lambda name: (-values[name], name))
        indexable = bool(names)
        signals = {name: count_html(values[name], lower_bound=not retained["complete"]) +
                   (' download' if values[name] == 1 else ' downloads') for name in names}
        body += _package_cards(prefix, names, active, signals) if names else '<p class="package-empty">No positive completed transfers are available for this observation period.</p>'
        body += '<p class="package-note">These cumulative observations cover configured Asm delivery sources since collection began. Unreported earlier or external transfers are outside this metric. Transfers do not measure people or installations.</p>'
    body += '<p class="package-note">' + package_pages._anchor("Browse all packages", prefix + "packages/") + ' · ' + package_pages._anchor("Discovery data and coverage", prefix + "discovery/") + '. Sponsorship does not influence ranking.</p>'
    html = package_pages._page(route, page_title, description, body, package_pages._chrome(stage),
                               active_nav="Explore", scripts=False, noindex=not indexable)
    return html, indexable


def explore_page(stage: Path, index: dict, snapshot: dict | None, metadata: dict | None, retained: dict | None, kind="explore") -> str:
    """Render a complete native document; unknown discovery identities are 404s."""
    return _render_explore(stage, index, snapshot, metadata, retained, kind)[0]


def write_explore(stage: Path, index: dict, snapshot: dict, metadata: dict, retained: dict) -> list[str]:
    """Write dashboard and directories from one set of cached source snapshots."""
    kinds = list(BASE) + ["keywords/" + row["id"] for row in metadata["keywords"] if row.get("packages")]
    kinds.extend("architectures/" + group["id"] for group in architecture_groups(index))
    outputs = []
    for kind in kinds:
        html, indexable = _render_explore(stage, index, snapshot, metadata, retained, kind)
        route = "explore/" if kind == "explore" else "browse/" + kind + "/"
        outputs.append((route, html.encode("utf-8"), indexable))
    for route, html, _ in outputs: registry.write_atomic(stage / route / "index.html", html)
    return [route for route, _, indexable in outputs if indexable]
