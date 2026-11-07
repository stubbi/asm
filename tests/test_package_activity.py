"""Activity views distinguish retained observations from missing coverage.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
import importlib
from pathlib import Path
import sys
import unittest
from xml.etree import ElementTree
from test_count_format import accessible_text

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))


def fixture():
    """Private rendering fixture; these are not live Asm observations."""
    start = datetime(2026, 10, 8, 12, tzinfo=timezone.utc)
    end = start + timedelta(days=30)
    stamp = lambda value: value.isoformat().replace("+00:00", "Z")
    days, cursor = [], start
    while cursor < end:
        stop = min(end, cursor.replace(hour=0) + timedelta(days=1))
        days.append({"date": cursor.date().isoformat(), "start": stamp(cursor), "end": stamp(stop),
                     "count": None, "coverage": "unavailable", "observed_seconds": 0})
        cursor = stop
    days[-3].update(count=0, coverage="complete", observed_seconds=86400)
    days[-2].update(count=3, coverage="complete", observed_seconds=86400)
    days[-1].update(count=0, coverage="partial", observed_seconds=3600)
    return {"schema": 1, "policy": "asm-deliveries-v1", "source": "asm-delivery-events",
            "name": "stubbi/math", "version": None, "observed_at": stamp(end),
            "collection_started_at": days[-3]["start"], "stale": False,
            "window": {"days": 30, "start": stamp(start), "end": stamp(end), "basis": "rolling-observation"},
            "total": 3, "complete": False, "days": days}


class Page(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.tags, self.text, self.links = [], [], []
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if tag == "a": self.links.append(attrs["href"])

    def handle_data(self, data): self.text.append(data)


class ActivityTests(unittest.TestCase):
    def render(self, data=None, metric="../../discovery/", raw="../../registry/v1/activity.json"):
        self.assertTrue((ROOT / "tools/package_activity.py").is_file(), "Activity renderer is not implemented")
        module = importlib.import_module("package_activity")
        return module.render_activity(fixture() if data is None else data, metric, raw)

    def test_scoped_period_total_table_and_unknown_gaps(self):
        data = fixture()
        html = self.render(data)
        page = Page(html)
        text = " ".join(page.text)
        self.assertIn(("section", {"id": "activity", "class": "package-section package-activity"}), page.tags)
        self.assertIn("≥ 3", text)
        self.assertIn("All versions", text)
        self.assertIn("2026-10-08", text)
        self.assertIn("2026-11-07", text)
        self.assertIn("12:00 UTC", text)
        self.assertIn("Asm", text)
        self.assertIn("Unavailable", text)
        self.assertIn("≥ 0", text)
        self.assertIn("partial day", text)
        self.assertEqual(sum(tag == "tr" for tag, _ in page.tags), 32)
        self.assertTrue(any(tag == "details" for tag, _ in page.tags))
        svg = ElementTree.fromstring(html[html.index("<svg"):html.index("</svg>") + 6])
        self.assertEqual(svg.attrib["aria-hidden"], "true")
        self.assertFalse(svg.findall(".//path"), "Missing observations must not be joined by a line")
        bars = [node for node in svg.iter("rect") if "package-activity-bar" in node.attrib.get("class", "").split()]
        self.assertEqual(len(bars), 1)
        self.assertTrue(any("package-activity-gap" in node.attrib.get("class", "") for node in svg.iter()))
        for bar in bars:
            self.assertGreater(float(bar.attrib["height"]), 0)
            self.assertGreaterEqual(float(bar.attrib["y"]), 0)
            self.assertLessEqual(float(bar.attrib["y"]) + float(bar.attrib["height"]), 140)

    def test_exact_version_and_stale_state_remain_explicit(self):
        data = fixture()
        data.update(version="0.4.0", stale=True)
        text = " ".join(Page(self.render(data)).text)
        self.assertIn("stubbi/math@0.4.0", text)
        self.assertNotIn("All versions", text)
        self.assertIn("stale", text.lower())
        self.assertIn("incomplete", text.lower())

    def test_collecting_zero_has_no_invented_flatline(self):
        data = fixture()
        for day in data["days"]: day.update(count=None, coverage="unavailable", observed_seconds=0)
        data["days"][-1].update(count=0, coverage="partial", observed_seconds=1)
        data["total"] = 0
        html = self.render(data)
        self.assertNotIn("<svg", html)
        text = " ".join(Page(html).text)
        self.assertIn("Collecting", text)
        self.assertIn("observed part", text)
        self.assertNotIn("0 downloads in the last 30 days", text)

    def test_fully_observed_zero_is_a_real_chart_and_exact_count(self):
        data = fixture()
        for day in data["days"]:
            seconds = (datetime.fromisoformat(day["end"]) - datetime.fromisoformat(day["start"])).total_seconds()
            day.update(count=0, coverage="complete", observed_seconds=seconds)
        data.update(total=0, complete=True, collection_started_at=data["window"]["start"])
        html = self.render(data)
        self.assertIn("<svg", html)
        text = accessible_text(html)
        self.assertIn("0 downloads", text)
        self.assertNotIn("≥", text)

    def test_unknown_payload_does_not_claim_zero(self):
        data = fixture()
        data.update(total=None, observed_at=None, collection_started_at=None, stale=True, days=[])
        data["window"].update(start=None, end=None)
        html = self.render(data)
        self.assertNotIn("<svg", html)
        text = " ".join(Page(html).text)
        self.assertIn("unavailable", text.lower())
        self.assertNotIn("0 downloads", text)

    def test_small_positive_counts_do_not_round_to_zero_beside_a_large_count(self):
        data = fixture()
        data["days"][-3]["count"] = 1
        data["days"][-2]["count"] = 9007199254740990
        data["total"] = 9007199254740991
        html = self.render(data)
        svg = ElementTree.fromstring(html[html.index("<svg"):html.index("</svg>") + 6])
        bars = list(svg.iter("rect"))
        self.assertEqual(len(bars), 2)
        self.assertTrue(all(float(bar.attrib["height"]) > 0 for bar in bars))

    def test_one_positive_observation_is_enough_to_show_activity(self):
        data = fixture()
        for day in data["days"]: day.update(count=None, coverage="unavailable", observed_seconds=0)
        data["days"][-1].update(count=1, coverage="partial", observed_seconds=1)
        data["total"] = 1
        self.assertIn("<svg", self.render(data))

    def test_delivery_projection_preserves_gap_events_and_midnight_endpoint(self):
        import discovery
        import registry
        records = registry.read_records(ROOT / "registry")
        name, version = records[0]["name"], records[0]["version"]
        # Controlled projection fixture, separate from live delivery data.
        observation = {"coverage_end": "2026-11-07T00:00:00Z", "stale": False,
                       "collection_started_at": "2026-11-05T00:00:00Z",
                       "counts": {name: 3}, "version_counts": {name + "@" + version: 3},
                       "daily_counts": [{"date": "2026-11-05", "name": name, "version": version, "count": 1},
                                        {"date": "2026-11-07", "name": name, "version": version, "count": 2}],
                       "coverage_intervals": [{"start": "2026-11-06T23:59:00Z", "end": "2026-11-07T00:00:00Z"}]}
        activity = discovery.delivery_activity(records, name, observation, version)
        self.assertEqual(activity["days"][-1]["observed_seconds"], 0)
        self.assertEqual(activity["days"][-1]["coverage"], "partial")
        html = self.render(activity)
        self.assertIn("<svg", html)
        self.assertIn("≥ 3", html)
        self.assertIn("≥ 2", html)

    def test_reporting_cutoff_matches_its_observation(self):
        data = fixture()
        data["observed_at"] = "2026-11-07T12:00:01Z"
        html = self.render(data)
        self.assertNotIn("<svg", html)
        self.assertIn("unavailable", html.lower())

    def test_registry_and_package_activity_fields_cannot_be_interchanged(self):
        self.render()
        module = importlib.import_module("package_activity")
        self.assertTrue(hasattr(module, "render_registry_activity"), "Registry renderer is not implemented")
        global_data = fixture()
        del global_data["name"], global_data["version"]
        global_data["scope"] = "registry"
        html = module.render_registry_activity(global_data, "../discovery/", "../registry/v1/stats.json")
        self.assertIn("<svg", html)
        self.assertIn("All packages · All versions · Asm completed transfers", html)
        self.assertNotIn("stubbi/math", html)
        self.assertNotIn("<svg", module.render_registry_activity(fixture(), "../discovery/", "stats.json"))
        self.assertNotIn("<svg", module.render_activity(global_data, "../discovery/", "stats.json"))
        global_data["name"] = "stubbi/math"
        self.assertNotIn("<svg", module.render_registry_activity(global_data, "../discovery/", "stats.json"))

    def test_full_window_at_midnight_does_not_require_duration_after_its_cutoff(self):
        import discovery
        import registry
        records = registry.read_records(ROOT / 'registry')
        name, version = records[0]['name'], records[0]['version']
        observation = {'coverage_end': '2026-11-07T00:00:00Z', 'stale': False,
                       'collection_started_at': '2026-10-08T00:00:00Z',
                       'counts': {name: 1}, 'version_counts': {name+'@'+version: 1},
                       'daily_counts': [{'date':'2026-11-07','name':name,'version':version,'count':1}],
                       'coverage_intervals': [{'start':'2026-10-08T00:00:00Z','end':'2026-11-07T00:00:00Z'}]}
        activity = discovery.delivery_activity(records, name, observation, version)
        self.assertTrue(activity['complete'])
        html = self.render(activity)
        self.assertIn('The full window is covered.', html)
        self.assertIn('<svg', html)

    def test_malformed_activity_fails_closed(self):
        changes = [lambda x: x.update(schema=True), lambda x: x.update(policy="other"),
                   lambda x: x.update(total=True), lambda x: x.update(total=9007199254740992),
                   lambda x: x.update(total=4), lambda x: x.update(stale="false"),
                   lambda x: x["days"].reverse(), lambda x: x["days"].append(deepcopy(x["days"][-1])),
                   lambda x: x["days"][-1].update(count=-1),
                   lambda x: x["days"][-1].update(observed_seconds=float("nan")),
                   lambda x: x["days"][-1].update(coverage="complete"),
                   lambda x: x["days"][0].update(count=0),
                   lambda x: x["days"][-1].update(date='2026-11-07<script>'),
                   lambda x: x["window"].update(end="2026-11-07T12:00:00+02:00")]
        for change in changes:
            data = fixture()
            change(data)
            with self.subTest(change=change):
                html = self.render(data)
                self.assertNotIn("<svg", html)
                self.assertIn("unavailable", html.lower())
                self.assertNotIn("≥ 3", html)

    def test_hostile_links_and_labels_cannot_create_markup_or_executable_urls(self):
        html = self.render(metric='../../discovery/?q="<script>alert(1)</script>', raw="javascript:alert(1)")
        page = Page(html)
        self.assertFalse(any(tag in {"script", "img"} for tag, _ in page.tags))
        self.assertNotIn("javascript:", html)
        self.assertIn("&lt;script&gt;", html)
        data = fixture()
        data["name"] = '<img src=x onerror=alert(1)>'
        html = self.render(data)
        self.assertNotIn("<img", html)
        self.assertIn("unavailable", html.lower())


if __name__ == "__main__": unittest.main()
