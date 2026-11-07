"""Render registry size and explicitly scoped Asm transfer observations.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from html import escape
from pathlib import Path

import discovery
import package_activity
import package_pages
import registry
from count_format import count_html


MAX_RANKED = 100


def stats_snapshot(index: dict, observation: dict | None, records: list[dict]) -> dict:
    """Build public aggregate data from a cached observation, without I/O."""
    records = registry.check_records(records)
    registry.require({item["name"] for item in index["packages"]} == {item["name"] for item in records},
                     "statistics catalog differs from accepted records")
    return {"schema": 1, "policy": "asm-deliveries-v1", "source": "asm-delivery-events",
            "catalog": package_pages.catalog_stats(index),
            "transfers": discovery.retained_counts(records, observation),
            "activity": discovery.delivery_activity(records, None, observation)}


def _count(value: int | None, complete: bool) -> str:
    return "Unavailable" if value is None else count_html(value, lower_bound=not complete)


def _ranking(index: dict, transfers: dict) -> str:
    entries = sorted(((name, item["total"]) for name, item in transfers["packages"].items()
                      if item["total"] is not None and item["total"] > 0), key=lambda item: (-item[1], item[0]))
    body = ('<section class="package-section" aria-labelledby="registry-ranking-heading">'
            '<h2 id="registry-ranking-heading">Most downloaded since collection began</h2>'
            '<p class="package-note">Ranked by observed completed transfers across all retained versions. '
            'Missing reports can affect relative order.</p>')
    if not entries:
        message = "Transfer measurements are unavailable." if transfers["total"] is None else "No positive transfer counts have been recorded in the available coverage."
        return body + '<p class="package-note">' + message + '</p></section>'
    indexed = {item["name"]: item for item in index["packages"]}
    body += '<ol class="registry-ranking">'
    for name, count in entries[:MAX_RANKED]:
        item = indexed[name]
        registry.require(isinstance(item["summary"], str) and len(item["summary"]) <= 2000, "invalid statistics summary")
        state = '<span class="release-state">No active release</span>' if item["latest"] is None else ''
        body += ('<li class="registry-ranking-item"><div class="registry-ranking-copy"><h3>'
                 + package_pages._anchor(name, "../" + package_pages.package_route(name), package=True)
                 + '</h3><p>' + escape(item["summary"]) + '</p>' + state + '</div>'
                 '<span class="registry-ranking-count">' + _count(count, transfers["complete"]) + ' transfers</span></li>')
    body += '</ol>'
    if len(entries) > MAX_RANKED:
        body += '<p class="package-note">Showing the first 100 packages. The statistics data contains all package totals.</p>'
    return body + '</section>'


def stats_page(stage: Path, index: dict, snapshot: dict, observation: dict | None, records: list[dict]) -> str:
    """Render the cached cutoff; discovery metadata never supplies counters."""
    data = stats_snapshot(index, observation, records)
    catalog, transfers = data["catalog"], data["transfers"]
    body = ('<header class="package-heading"><h1>Stats</h1>'
            '<p>Registry size and observed Asm download activity.</p></header>'
            '<dl class="registry-totals">')
    for label, value, note in (
        ("Registered packages", count_html(catalog["packages"]), "Unique package identities"),
        ("Retained releases", count_html(catalog["releases"]), "Including yanked history"),
        ("Observed downloads", _count(transfers["total"], transfers["complete"]), "Since collection began"),
    ):
        body += '<div class="registry-total"><dt>' + label + '</dt><dd>' + value + '\n<span class="registry-total-note">' + note + '</span></dd></div>'
    body += ('</dl><dl class="package-facts"><div><dt>Release files</dt><dd>' + count_html(catalog["files"])
             + '</dd></div><div><dt>Package targets</dt><dd>' + count_html(catalog["targets"]) + '</dd></div></dl>')
    if transfers["observed_at"] is not None:
        body += '<p class="package-note">Since collection began ' + package_activity._time(transfers["collection_started_at"]) + ', through ' + package_activity._time(transfers["observed_at"]) + '.</p>'
        body += '<p class="package-note">' + ('Reporting coverage is complete for this collection period.' if transfers["complete"] else 'Reporting coverage is incomplete. The ≥ symbol marks an observed minimum, including a measured zero.') + '</p>'
    else:
        body += '<p class="package-note">Cumulative observations are unavailable. Missing collection history does not establish zero downloads.</p>'
    if transfers["stale"]:
        body += '<p class="package-note">These cumulative observations are stale. The latest activity may be missing.</p>'
    body += ('<details class="registry-definition"><summary>Measurement scope</summary>'
             '<p class="package-note">Counts cover configured Asm delivery sources. They do not measure people, installations, quality, or safety.</p>'
             '<p class="package-note">Package targets describe registered artifacts, not supported CLI hosts. Release files count declared selections, not distinct stored objects.</p>'
             '</details>'
             '<p class="package-note">' + package_pages._anchor("Statistics data (JSON)", "../registry/v1/stats.json")
             + ' · ' + package_pages._anchor("How counts work", "../discovery/") + '</p>')
    body += _ranking(index, transfers)
    body += '<p class="package-note">' + package_pages._anchor("Most downloaded in the last 30 days", "../browse/popular/") + '</p>'
    body += package_activity.render_registry_activity(data["activity"], "../discovery/", "../registry/v1/stats.json")
    return package_pages._page("stats/", "Assembly registry statistics",
                               "Inspect registered packages, retained releases, and Asm transfer observations. Counts retain collection scope, coverage limits, and daily activity when available.",
                               body, package_pages._chrome(stage), active_nav="Stats", scripts=False)


def write_stats(stage: Path, index: dict, snapshot: dict, observation: dict | None, records: list[dict]) -> list[str]:
    """Write the static page and the same public, scoped statistics payload."""
    data = stats_snapshot(index, observation, records)
    registry.write_atomic(stage / "registry/v1/stats.json", registry.json_bytes(data))
    registry.write_atomic(stage / "stats/index.html", stats_page(stage, index, snapshot, observation, records).encode("utf-8"))
    return ["stats/"]
