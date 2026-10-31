"""Static checks for accessible references and local website assets."""

from html.parser import HTMLParser
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"


class SiteParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []
        self.references = []
        self.assets = []
        self.input_ids = []
        self.labels = []
        self.headings = []
        self.scripts = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.append(attrs["id"])
        if tag == "a" and attrs.get("href", "").startswith("#") and attrs["href"] != "#":
            self.references.append(attrs["href"][1:])
        for key in ("aria-labelledby", "aria-controls"):
            self.references.extend(attrs.get(key, "").split())
        if tag in ("script", "img") and "src" in attrs:
            self.assets.append(attrs["src"])
        if tag == "link" and attrs.get("rel") in ("stylesheet", "icon"):
            self.assets.append(attrs["href"])
        if tag in ("input", "select"):
            self.input_ids.append(attrs.get("id"))
        if tag == "label":
            self.labels.append(attrs.get("for"))
        if tag == "h1":
            self.headings.append(tag)
        if tag == "script":
            self.scripts.append(attrs.get("src", ""))


class SiteTests(unittest.TestCase):
    def setUp(self):
        self.page = SiteParser()
        self.page.feed((SITE / "index.html").read_text())

    def test_unique_ids_and_existing_accessible_references(self):
        self.assertEqual(len(self.page.ids), len(set(self.page.ids)))
        self.assertTrue(set(self.page.references).issubset(set(self.page.ids)))
        self.assertEqual(len(self.page.headings), 1)

    def test_search_controls_have_visible_labels(self):
        self.assertTrue(self.page.input_ids)
        self.assertTrue(set(self.page.input_ids).issubset(set(self.page.labels)))

    def test_static_assets_exist_and_stay_local(self):
        for asset in self.page.assets:
            self.assertNotIn(":", asset)
            self.assertTrue((SITE / asset).is_file(), asset)

    def test_no_external_script_dependency(self):
        self.assertTrue(self.page.scripts)
        for script in self.page.scripts:
            self.assertFalse(script.startswith(("http:", "https:", "//")))


if __name__ == "__main__":
    unittest.main()
