"""Render bounded Asm delivery observations without fabricating history.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from datetime import datetime, timedelta, timezone
from html import escape
import math
import re
from urllib.parse import urlsplit

import registry
from count_format import compact_count, count_html, exact_count


MAX_COUNT = 9007199254740991
FIELDS = {"schema", "policy", "source", "name", "version", "observed_at", "collection_started_at",
          "stale", "window", "total", "complete", "days"}
DAY_FIELDS = {"date", "start", "end", "count", "coverage", "observed_seconds"}


def _instant(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)", value):
        raise ValueError("invalid UTC timestamp")
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _count(value):
    return type(value) is int and 0 <= value <= MAX_COUNT


def _validated(activity, *, registry_scope=False):
    fields = (FIELDS - {"name", "version"}) | {"scope"} if registry_scope else FIELDS
    if not isinstance(activity, dict) or set(activity) != fields:
        raise ValueError("invalid activity fields")
    if type(activity["schema"]) is not int or activity["schema"] != 1 or activity["policy"] != "asm-deliveries-v1" or activity["source"] != "asm-delivery-events":
        raise ValueError("unsupported activity source")
    if registry_scope:
        if activity["scope"] != "registry":
            raise ValueError("invalid registry activity scope")
    else:
        registry.package_name(activity["name"])
        if activity["version"] is not None:
            registry.version_tuple(activity["version"])
    if type(activity["complete"]) is not bool or type(activity["stale"]) is not bool:
        raise ValueError("invalid activity state")
    window, days = activity["window"], activity["days"]
    if not isinstance(window, dict) or set(window) != {"days", "start", "end", "basis"} or type(window["days"]) is not int or window["days"] != 30 or window["basis"] != "rolling-observation":
        raise ValueError("invalid activity window")
    if not isinstance(days, list) or len(days) > 31:
        raise ValueError("invalid activity days")
    if activity["total"] is None:
        if days or activity["complete"] or any(value is not None for value in (activity["observed_at"], window["start"], window["end"])):
            raise ValueError("unknown activity has observations")
        if activity["collection_started_at"] is not None:
            _instant(activity["collection_started_at"])
        return activity
    if not _count(activity["total"]) or not days:
        raise ValueError("invalid activity total")
    start, end, observed = _instant(window["start"]), _instant(window["end"]), _instant(activity["observed_at"])
    if end - start != timedelta(days=30) or observed != end:
        raise ValueError("inconsistent activity period")
    if activity["collection_started_at"] is None or _instant(activity["collection_started_at"]) > observed:
        raise ValueError("invalid collection start")
    cursor, total = start, 0
    for day in days:
        if not isinstance(day, dict) or set(day) != DAY_FIELDS or day["date"] != cursor.date().isoformat():
            raise ValueError("invalid daily identity")
        stop = min(end, cursor.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1))
        if _instant(day["start"]) != cursor or _instant(day["end"]) != stop:
            raise ValueError("daily bounds do not cover the window")
        seconds, duration = day["observed_seconds"], (stop - cursor).total_seconds()
        if type(seconds) not in (int, float) or not math.isfinite(seconds) or not 0 <= seconds <= duration:
            raise ValueError("invalid daily coverage")
        coverage, count = day["coverage"], day["count"]
        if coverage == "unavailable":
            if count is not None or seconds != 0:
                raise ValueError("unknown coverage has a count")
        elif coverage in {"complete", "partial"}:
            fully_observed = duration > 0 and seconds == duration
            if not _count(count) or (coverage == "complete") != fully_observed or (seconds == 0 and count == 0):
                raise ValueError("inconsistent daily coverage")
            total += count
        else:
            raise ValueError("unsupported daily coverage")
        cursor = stop
    complete = all(day["coverage"] == "complete" for day in days if day["start"] != day["end"])
    if cursor != end or total != activity["total"] or activity["complete"] != complete:
        raise ValueError("inconsistent activity aggregate")
    return activity


def _link(label, href):
    if not isinstance(href, str) or not 0 < len(href) <= 4096 or any(ord(char) < 33 for char in href):
        return ""
    try:
        url = urlsplit(href)
        if url.scheme not in {"", "https"} or url.netloc and (url.scheme != "https" or url.username or url.password) or href.startswith("\\"):
            return ""
    except ValueError:
        return ""
    return '<a href="' + escape(href, quote=True) + '">' + escape(label) + '</a>'


def _time(value):
    return _instant(value).strftime("%Y-%m-%d at %H:%M UTC")


def _chart(days):
    # Stable HTML axis labels remain readable when the graphic becomes narrow.
    maximum = max(1, max(day["count"] or 0 for day in days))
    step, width = 600 / len(days), 600 / len(days) * .64
    marks = ['<line class="package-activity-grid" x1="0" y1="0" x2="600" y2="0" stroke="currentColor"/>',
             '<line class="package-activity-axis" x1="0" y1="140" x2="600" y2="140" stroke="currentColor"/>']
    for index, day in enumerate(days):
        center = (index + .5) * step
        if day["count"] is None:
            for left, right in ((-3, 3), (3, -3)):
                marks.append(f'<line class="package-activity-gap" x1="{center + left:.3f}" y1="128" x2="{center + right:.3f}" y2="136" stroke="currentColor"/>')
        elif day["count"] == 0:
            marks.append(f'<line class="package-activity-zero" x1="{center - width / 3:.3f}" y1="140" x2="{center + width / 3:.3f}" y2="140" stroke="currentColor" stroke-width="3"/>')
        else:
            height = day["count"] / maximum * 140
            marks.append(f'<rect class="package-activity-bar" data-coverage="{day["coverage"]}" x="{center - width / 2:.3f}" y="{140 - height:.12g}" width="{width:.3f}" height="{height:.12g}" fill="currentColor"/>')
    return ('<div class="package-activity-plot" aria-hidden="true"><div class="package-activity-scale"><span title="' + exact_count(maximum) + '">' + compact_count(maximum) + '</span><span>0</span></div>'
            '<svg class="package-activity-chart" viewBox="0 0 600 144" preserveAspectRatio="none" width="600" height="144" aria-hidden="true" focusable="false">' + ''.join(marks) + '</svg></div>'
            '<div class="package-activity-labels" aria-hidden="true"><span>' + days[0]["date"] + '</span><span>' + days[-1]["date"] + '</span></div>'
            '<p class="package-activity-note">Columns show observed daily transfers. × marks unobserved dates. Short baseline marks show observed zero.</p>')


def _table(days):
    rows = []
    for day in days:
        count = "Unavailable" if day["count"] is None else ("≥ " if day["coverage"] == "partial" else "") + exact_count(day["count"])
        partial = " (partial day)" if (_instant(day["end"]) - _instant(day["start"])).total_seconds() < 86400 else ""
        coverage = {"complete": "Fully observed", "partial": "Partially observed", "unavailable": "Unobserved"}[day["coverage"]]
        rows.append('<tr><th scope="row"><time datetime="' + day["date"] + '">' + day["date"] + '</time>' + partial + '</th><td>' + count + '</td><td>' + coverage + '</td></tr>')
    return ('<details class="package-activity-data"><summary>Daily counts and coverage</summary>'
            '<div class="package-table-scroll" tabindex="0" role="region" aria-label="Daily download data"><table><caption>Daily completed transfers (UTC)</caption>'
            '<thead><tr><th scope="col">Date</th><th scope="col">Count</th><th scope="col">Coverage</th></tr></thead><tbody>' + ''.join(rows) + '</tbody></table></div></details>')


def _render_activity(activity, metric_href, data_href, *, registry_scope=False) -> str:
    """Return a static view, or a useful unavailable state for malformed input.

    The caller binds the payload to the selected package and exact version.
    This renderer performs no collection, network access, or script execution.
    """
    links = [value for value in (_link("Discovery data and coverage", metric_href), _link("Activity data (JSON)", data_href)) if value]
    body = '<section id="activity" class="package-section package-activity"><h2 class="package-activity-heading">Download activity</h2>'
    try:
        data = _validated(activity, registry_scope=registry_scope)
    except (registry.RegistryError, ValueError, TypeError, KeyError, OverflowError):
        data = None
    if data is None:
        body += '<p class="package-activity-state">Download activity is unavailable. Inspect the measurement policy or try again after a refresh.</p>'
    else:
        if registry_scope:
            body += '<p class="package-activity-scope">All packages · All versions · Asm completed transfers</p>'
        else:
            identity = data["name"] + ('@' + data["version"] if data["version"] is not None else '')
            body += '<p class="package-activity-scope"><code>' + escape(identity) + '</code> · ' + ('Exact version' if data["version"] is not None else 'All versions') + ' · Asm completed transfers</p>'
        if data["total"] is None:
            body += '<p class="package-activity-state">Download activity is unavailable. Missing observations do not establish zero downloads.</p>'
        else:
            count = data["total"]
            if not data["complete"] and count == 0:
                body += '<p class="package-activity-total">Collecting downloads</p><p class="package-activity-note">No completed downloads were recorded in the observed part of this window. Coverage is incomplete.</p>'
            else:
                body += '<p class="package-activity-total">' + count_html(count, lower_bound=not data["complete"]) + ' downloads</p>'
                body += '<p class="package-activity-note">' + ('The full window is covered.' if data["complete"] else 'Coverage is incomplete. This count is an observed minimum.') + '</p>'
            body += '<p class="package-activity-period">Last 30 days: ' + _time(data["window"]["start"]) + ' through ' + _time(data["window"]["end"]) + '.</p>'
            body += '<p class="package-activity-note">Reporting cutoff: ' + _time(data["window"]["end"]) + '. Collection started ' + _time(data["collection_started_at"]) + '.</p>'
            observed_days = sum(day["count"] is not None for day in data["days"])
            if observed_days >= 2 or count > 0:
                body += _chart(data["days"])
            body += _table(data["days"])
        if data["stale"]:
            body += '<p class="package-activity-note">These observations are stale. The latest activity may be missing.</p>'
        body += '<p class="package-activity-note">Transfers do not measure people, installations, suitability, or safety. Unreported delivery sources are outside this metric.</p>'
    if links:
        body += '<p class="package-activity-links">' + ' · '.join(links) + '</p>'
    return body + '</section>'


def render_activity(activity, metric_href, data_href) -> str:
    """Render only a package or exact-version activity payload."""
    return _render_activity(activity, metric_href, data_href)


def render_registry_activity(activity, metric_href, data_href) -> str:
    """Render registry-wide data without accepting a package identity payload."""
    return _render_activity(activity, metric_href, data_href, registry_scope=True)
