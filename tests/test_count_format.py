"""Count labels shorten without changing exact observations or lower bounds.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from html.parser import HTMLParser
from copy import deepcopy
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
CASES = json.loads((ROOT / "tests/count-format-cases.json").read_text())


def accessible_text(html):
    """Read one text stream, excluding hidden visual duplicates of counts."""
    class Text(HTMLParser):
        def __init__(self):
            super().__init__()
            self.stack, self.parts = [], []

        def handle_starttag(self, tag, attrs):
            attrs = dict(attrs)
            hidden = bool(self.stack and self.stack[-1][1]) or attrs.get("aria-hidden") == "true" or "hidden" in attrs or tag in {"script", "style"}
            if tag not in {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}:
                self.stack.append((tag, hidden))

        def handle_endtag(self, tag):
            for index in range(len(self.stack) - 1, -1, -1):
                if self.stack[index][0] == tag:
                    del self.stack[index:]
                    break

        def handle_data(self, text):
            if not self.stack or not self.stack[-1][1]: self.parts.append(text)
    parser = Text()
    parser.feed(html)
    return " ".join("".join(parser.parts).split())


class Count(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.tags, self.values = [], []
        self.feed(html)

    def handle_starttag(self, tag, attrs): self.tags.append((tag, dict(attrs)))
    def handle_data(self, text): self.values.append(text)


class CountFormatTests(unittest.TestCase):
    def module(self):
        self.assertTrue((ROOT / "tools/count_format.py").is_file(), "Shared count formatting is not implemented.")
        return importlib.import_module("count_format")

    def test_shared_github_boundary_vectors_and_lower_bounds(self):
        module = self.module()
        for row in CASES["valid"]:
            with self.subTest(row=row):
                lower = row.get("lower_bound", False)
                self.assertEqual(module.compact_count(row["value"], lower_bound=lower), row["compact"])
                self.assertEqual(module.exact_count(row["value"]), row["exact"])

    def test_invalid_values_cannot_become_count_labels_or_markup(self):
        module = self.module()
        for value in CASES["invalid"] + [1000.0, float("nan"), float("inf"), -float("inf")]:
            for helper in (module.compact_count, module.exact_count, module.count_html):
                with self.subTest(value=value, helper=helper.__name__), self.assertRaises(ValueError): helper(value)

    def test_compact_markup_retains_exact_title_and_accessible_text(self):
        module = self.module()
        for value, lower, expected in ((1200, False, "1.2k"), (1250, True, "≥ 1.2k"), (5, False, "5"), (0, True, "≥ 0")):
            with self.subTest(value=value, lower=lower):
                page = Count(module.count_html(value, lower_bound=lower))
                exact = ("≥ " if lower else "") + module.exact_count(value)
                self.assertEqual(page.tags[0], ("span", {"class": "compact-count", "title": exact}))
                self.assertIn(("span", {"aria-hidden": "true"}), page.tags)
                self.assertIn(("span", {"class": "sr-only"}), page.tags)
                self.assertEqual(page.values, [expected, exact])
                self.assertTrue(all(tag == "span" for tag, _ in page.tags))
                self.assertEqual(accessible_text(module.count_html(value, lower_bound=lower) + ' downloads'), exact + ' downloads')

    def test_lower_bound_labels_never_round_above_the_observed_minimum(self):
        module = self.module()
        scales = {"k": 1000, "M": 10 ** 6, "B": 10 ** 9, "T": 10 ** 12, "Q": 10 ** 15}
        for value in (1000, 1049, 1050, 1250, 1999, 999949, 999950, 999999, 1200000, 9007199254740991):
            label = module.compact_count(value, lower_bound=True)
            whole, _, fraction = label[:-1].partition(".")
            represented = (int(whole) * 10 + int(fraction or "0")) * scales[label[-1]] // 10
            self.assertLessEqual(represented, value)

    def test_lower_bound_mode_is_boolean_not_a_truthy_untrusted_value(self):
        module = self.module()
        for kwargs in ({"lower_bound": "true"}, {"lower_bound": 1}):
            for helper in (module.compact_count, module.count_html):
                with self.subTest(kwargs=kwargs, helper=helper.__name__), self.assertRaises(ValueError): helper(1200, **kwargs)

    def test_activity_total_and_axis_shorten_while_daily_values_and_raw_data_stay_exact(self):
        from test_package_activity import fixture
        import package_activity
        data = fixture()
        data["days"][-2]["count"] = 1250
        data["total"] = 1250
        before = deepcopy(data)
        html = package_activity.render_activity(data, "../../discovery/", "../../registry/v1/activity/example.json")
        parsed = Count(html)
        self.assertIn(("span", {"class": "compact-count", "title": "≥ 1,250"}), parsed.tags)
        self.assertIn("≥ 1.2k", parsed.values)
        self.assertIn('<span title="1,250">1.3k</span>', html)
        self.assertIn('<td>1,250</td>', html)
        self.assertNotIn('<td>1.2k</td>', html)
        self.assertEqual(data, before)

    def test_package_counts_keep_exact_version_scope_and_unknown_state(self):
        import package_pages
        counts = {"schema": 1, "source": "asm-delivery-events", "complete": False, "stale": False,
                  "observed_at": "2026-11-07T00:00:00Z", "packages": {"owner/math": {
                      "total": 1200000, "versions": {"0.1.0": 1250, "0.2.0": None}}}}
        before = deepcopy(counts)
        package = package_pages.counts_html(counts, "owner/math", None)
        exact = package_pages.counts_html(counts, "owner/math", "0.1.0")
        unknown = package_pages.counts_html(counts, "owner/math", "0.2.0")
        self.assertIn('title="≥ 1,200,000"', package)
        self.assertIn('aria-hidden="true">≥ 1.2M', package)
        self.assertIn('title="≥ 1,250"', exact)
        self.assertIn('aria-hidden="true">≥ 1.2k', exact)
        self.assertNotIn('1.2M', exact)
        self.assertIn("unavailable", unknown)
        self.assertNotIn('compact-count', unknown)
        self.assertNotIn('<span', package_pages._counts(counts, "owner/math", None))
        self.assertEqual(counts, before)

    def test_catalog_totals_remain_compact_and_exact_after_repeated_static_generation(self):
        import package_pages
        index = {"schema": 1, "packages": [{"name": "owner/package" + str(number), "versions": [{"version": "0.1.0",
                 "artifacts": [{"target": "x86_64-linux", "kind": "source"}]}]} for number in range(1200)]}
        before = deepcopy(index)
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary)
            page = stage / "index.html"
            page.write_text(''.join('<dd data-catalog-stat="' + name + '">0</dd>' for name in ("packages", "releases", "files", "targets")))
            package_pages.write_catalog_stats(stage, index)
            first = page.read_bytes()
            package_pages.write_catalog_stats(stage, index)
            self.assertEqual(page.read_bytes(), first)
            self.assertEqual(first.count(b'title="1,200"'), 3)
            self.assertEqual(first.count(b'aria-hidden="true">1.2k'), 3)
        self.assertEqual(index, before)


if __name__ == "__main__": unittest.main()
