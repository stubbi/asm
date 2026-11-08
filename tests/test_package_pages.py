"""Package pages retain exact release facts and treat source text as untrusted.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
from html.parser import HTMLParser
import importlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from xml.etree import ElementTree
from urllib.parse import urljoin, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry
from test_count_format import accessible_text
from test_site import HierarchyParser, SiteParser


class Page(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.links, self.scripts, self.assets, self.ids, self.text = [], [], [], [], []
        self.forms, self.script_attributes = [], []
        self.catalog_links = []
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "a": self.links.append(attrs.get("href", ""))
        if tag == "a" and 'package-catalog-name' in attrs.get('class', '').split():
            self.catalog_links.append(attrs.get('href', ''))
        if tag == "script" and "src" in attrs: self.scripts.append(attrs["src"])
        if tag == "script": self.script_attributes.append(attrs)
        if tag == "form": self.forms.append(attrs)
        if tag in ("script", "img") and "src" in attrs: self.assets.append(attrs["src"])
        if tag == "link" and attrs.get("rel") in ("stylesheet", "icon"): self.assets.append(attrs.get("href", ""))
        if "id" in attrs: self.ids.append(attrs["id"])

    def handle_data(self, data): self.text.append(data)


class PackagePageTests(unittest.TestCase):
    def test_repeated_readme_architecture_links_have_destination_specific_names(self):
        module = importlib.import_module("package_pages")
        source = self.records[0]["source"]
        rendered = module._inline('[ARM64](examples/hello-aarch64) and [ARM64](cli/aarch64/asm.s)', source, "README.md")
        self.assertIn('ARM64<span class="sr-only"> hello example</span>', rendered)
        self.assertIn('ARM64<span class="sr-only"> CLI source</span>', rendered)
        self.assertNotEqual(Page(rendered).links[0], Page(rendered).links[1])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.stage = Path(self.temp.name) / "stage"
        self.repo.mkdir(); self.stage.mkdir()
        self.git("init", "-q")
        self.git("remote", "add", "origin", "https://github.com/stubbi/asm")
        self.readme = self.repo / "examples/math/README.md"
        self.readme.parent.mkdir(parents=True)
        self.readme.write_text("# Old guide\n\nOld exact body.\n\n[Routine](src/min.s)\n")
        (self.readme.parent / "LICENSE").write_text("MIT fixture license\n")
        (self.repo / "examples/hello").mkdir()
        (self.repo / "examples/hello/README.md").write_text("Nested README must not be guessed.\n")
        self.old_commit = self.commit()
        self.readme.write_text("# New guide\n\nNew exact body.\n")
        self.new_commit = self.commit()
        self.records = [self.record("0.2.0", self.old_commit, "Old summary", "MIT", "x86_64-linux"),
                        self.record("0.10.0", self.new_commit, "New summary", "AGPL-3.0-or-later", "aarch64-macos")]
        (self.stage / "index.html").write_text((ROOT / "site/index.html").read_text())
        self.counts = {"schema": 1, "source": "github-release-assets", "observed_at": "2026-11-07T00:00:00Z",
                       "packages": {"stubbi/math": {"total": 0, "versions": {"0.2.0": 0, "0.10.0": None}}}}

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True).stdout.decode().strip()

    def commit(self):
        self.git("add", ".")
        self.git("-c", "user.name=Package page test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Save fixture")
        return self.git("rev-parse", "HEAD")

    def record(self, version, commit, summary, license_id, target, *, name="stubbi/math", source_path="examples/math"):
        return {"schema": 1, "name": name, "version": version, "summary": summary, "license": license_id,
                "source": {"repository": "https://github.com/stubbi/asm", "commit": commit, "path": source_path},
                "yanked": False, "artifacts": [{"kind": "source", "target": target, "sha256": "b" * 64,
                "bytes": 100, "url": f"https://github.com/stubbi/asm/releases/download/packages-v{version}/{name.split('/')[1]}-{version}-{target}.tar.gz"}]}

    def generate(self, checked=None, dependency_metadata=None):
        self.assertTrue((ROOT / "tools/package_pages.py").exists(), "Package page generator is not implemented")
        self.module = importlib.import_module("package_pages")
        _, self.index = registry.make_indexes(self.records, checked or set())
        options = {} if dependency_metadata is None else {"dependency_metadata": dependency_metadata}
        return self.module.write_package_pages(self.repo, self.stage, self.records, self.index, self.counts, **options)

    def declarations(self, record=None, *, dependencies=None, features=None):
        record = record or self.records[0]
        return {"schema": 1, "sources": [{"name": record["name"], "version": record["version"],
            "target": record["artifacts"][0]["target"], "metadata": {"schema": 1,
            "source_sha256": record["artifacts"][0]["sha256"],
            "dependencies": dependencies or [], "features": features or {}}}]}

    def read(self, route): return (self.stage / route / "index.html").read_text()

    def schema(self, content):
        page = SiteParser(); page.feed(content)
        data = [item for item in page.elements if item["tag"] == "script"
                and item["attrs"].get("type") == "application/ld+json"]
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["attrs"], {"type": "application/ld+json"})
        return json.loads("".join(data[0]["text"]))

    def test_structured_data_bound_includes_script_escape_expansion(self):
        module = importlib.import_module("package_pages")
        value = {"description": "<" * (22 * 1024)}
        self.assertLess(len(json.dumps(value)), 128 * 1024)
        with self.assertRaisesRegex(registry.RegistryError, "structured data exceeds"):
            module._json_ld(value)

    def test_structured_source_uses_exact_version_license_commit_and_clean_identity(self):
        original = deepcopy(self.records)
        self.generate()
        for version, license_id, commit in (("0.2.0", "MIT", self.old_commit), ("0.10.0", "AGPL-3.0-or-later", self.new_commit)):
            html = self.read("packages/stubbi/math/" + version)
            schema = self.schema(html)
            canonical = "https://asm.build/packages/stubbi/math/" + version
            self.assertEqual(schema["url"], canonical)
            self.assertEqual(schema["@id"], canonical + "#webpage")
            source = schema["mainEntity"]
            self.assertEqual(source["@type"], "SoftwareSourceCode")
            self.assertEqual(source["@id"], canonical + "#source")
            self.assertEqual(source["version"], version)
            self.assertEqual(source["license"], "https://spdx.org/licenses/" + license_id + ".html")
            self.assertEqual(source["url"], "https://github.com/stubbi/asm/tree/" + commit + "/examples/math")
            self.assertEqual(source["codeRepository"], "https://github.com/stubbi/asm")
            self.assertIn({"@type": "PropertyValue", "propertyID": "Git commit", "value": commit}, source["identifier"])
            record_url = "https://asm.build/registry/v1/packages/stubbi/math/" + version + ".json"
            self.assertEqual(source["subjectOf"]["url"], record_url)
            page = SiteParser(); page.feed(html)
            links = [item["attrs"] for item in page.elements if item["tag"] == "link" and item["attrs"].get("rel") == "describedby"]
            self.assertEqual(len(links), 1)
            self.assertEqual(urljoin(canonical + "/", links[0]["href"]), record_url)
            self.assertEqual(links[0]["type"], "application/json")
            for unsupported in ("author", "publisher", "datePublished", "programmingLanguage", "targetProduct", "aggregateRating", "offers", "softwareVersion"):
                self.assertNotIn(unsupported, source)
        overview = self.schema(self.read("packages/stubbi/math"))
        self.assertEqual(overview["mainEntity"]["@id"], "https://asm.build/packages/stubbi/math/0.10.0#source")
        self.assertEqual(self.records, original)

    def test_structured_data_does_not_execute_hostile_metadata_or_invent_an_active_release(self):
        hostile = '</script><img src=x onerror=alert(1)><!-- & "quoted"'
        self.records[1]["summary"] = hostile
        self.generate()
        html = self.read("packages/stubbi/math")
        self.assertEqual(self.schema(html)["mainEntity"]["description"], hostile)
        page = SiteParser(); page.feed(html)
        self.assertEqual([item for item in page.elements if item["tag"] == "img" and item["attrs"].get("src") == "x"], [])
        self.assertIn('\\u003c/script\\u003e', html)
        for record in self.records:
            record.update(yanked=True, yank_reason="Retained fixture.")
        self.generate()
        inactive = self.read("packages/stubbi/math")
        self.assertNotIn("mainEntity", self.schema(inactive))
        self.assertNotIn('rel="describedby"', inactive)
        exact = self.schema(self.read("packages/stubbi/math/0.10.0"))
        self.assertEqual(exact["mainEntity"]["creativeWorkStatus"], "Yanked release")
        self.assertNotIn("contentUrl", json.dumps(exact))

    def test_current_topic_links_are_native_and_do_not_relabel_historical_versions(self):
        root = self.stage / "registry/v1"
        root.mkdir(parents=True)
        (root / "discovery-metadata.json").write_text(json.dumps({"schema": 1, "packages": [{"name": "stubbi/math", "keywords": ["integers", "math"]}]}))
        (root / "categories.json").write_text(json.dumps({"schema": 1, "categories": [{"id": "math", "name": "Math", "packages": ["stubbi/math"]}]}))
        self.generate()
        overview = self.read("packages/stubbi/math")
        self.assertIn("Browse related", overview)
        links = {urljoin("https://asm.build/packages/stubbi/math/", href) for href in Page(overview).links}
        self.assertTrue({"https://asm.build/browse/categories/math/", "https://asm.build/browse/keywords/math/",
                         "https://asm.build/browse/keywords/integers/", "https://asm.build/browse/architectures/aarch64/"} <= links)
        self.assertNotIn("https://asm.build/browse/architectures/x86_64/", links)
        self.assertEqual(self.schema(overview)["keywords"], ["integers", "math"])
        page = SiteParser(); page.feed(overview)
        related = [item for item in page.elements if item["tag"] == "a"
                   and any("browse/" + group + "/" in item["attrs"].get("href", "")
                           for group in ("categories", "keywords", "architectures"))]
        self.assertEqual([item["attrs"].get("aria-label") for item in related],
                         ["Math category", "integers keyword", "math keyword", "ARM64 (aarch64) architecture"])
        self.assertEqual(["".join(item["text"]) for item in related],
                         ["Math", "integers", "math", "ARM64 (aarch64)"])
        groups = [item["attrs"].get("aria-labelledby") for item in page.elements if item["tag"] == "ul"
                  and item["attrs"].get("aria-labelledby", "").startswith("package-topics-")]
        self.assertEqual(groups, ["package-topics-categories", "package-topics-keywords", "package-topics-architectures"])
        self.assertTrue(set(groups) <= {item["attrs"].get("id") for item in page.elements if item["tag"] == "dt"})
        for version in ("0.2.0", "0.10.0"):
            exact = self.read("packages/stubbi/math/" + version)
            self.assertNotIn("Browse related", exact)
            self.assertNotIn("keywords", self.schema(exact))

    def test_search_metadata_uses_each_exact_record_without_changing_its_bytes(self):
        original = deepcopy(self.records)
        self.generate()
        descriptions = []
        for version in (None, "0.2.0", "0.10.0"):
            route = "packages/stubbi/math" + ("/" + version if version else "")
            page = SiteParser(); page.feed(self.read(route))
            description = next(item["content"] for item in page.metadata if item.get("name") == "description")
            selected = self.records[0] if version == "0.2.0" else self.records[1]
            for expected in (selected["summary"], selected["license"], selected["artifacts"][0]["target"]):
                self.assertIn(expected, description)
            if version: self.assertIn("stubbi/math " + version, description)
            descriptions.append(description)
            title = next("".join(item["text"]) for item in page.elements if item["tag"] == "title")
            self.assertEqual(title, "stubbi/math" + ("@" + version if version else "") + " assembly package | Asm")
            self.assertEqual([item["content"] for item in page.metadata if item.get("property") == "og:site_name"], ["Asm"])
        self.assertEqual(len(set(descriptions)), 3)
        self.assertEqual(self.records, original)

    def test_technical_readme_metadata_identifies_only_the_available_exact_source_document(self):
        self.generate()
        old = self.schema(self.read("packages/stubbi/math/0.2.0"))
        document = old["hasPart"]
        self.assertEqual(document["@type"], "TechArticle")
        self.assertEqual(document["url"], "https://asm.build/packages/stubbi/math/0.2.0#readme")
        self.assertIn("stubbi/math@0.2.0", document["headline"])
        self.assertEqual(document["isBasedOn"], "https://github.com/stubbi/asm/blob/" + self.old_commit + "/examples/math/README.md")
        self.assertEqual(document["about"]["@id"], old["mainEntity"]["@id"])
        for invented in ("author", "publisher", "datePublished", "dateModified", "aggregateRating", "offers"):
            self.assertNotIn(invented, document)
        self.records[0]["source"]["commit"] = "d" * 40
        self.generate()
        self.assertNotIn("hasPart", self.schema(self.read("packages/stubbi/math/0.2.0")))

    def test_markdown_disclosures_render_only_balanced_attribute_free_blocks_outside_fences(self):
        module = importlib.import_module("package_pages")
        source = self.records[0]["source"]
        text = ('# Installation\n\n<details>\n<summary>Set **PATH**</summary>\n\n'
                'Keep this explanation.\n\n```sh\nexport PATH="$HOME/.local/bin:$PATH"\n```\n\n</details>\n\n'
                '```html\n<details>\n<summary>Literal code</summary>\n</details>\n```\n')
        rendered = module._markdown(text, source, "README.md")
        tree = ElementTree.fromstring("<div>" + rendered + "</div>")
        disclosures = tree.findall(".//details")
        self.assertEqual(len(disclosures), 1)
        self.assertEqual(disclosures[0][0].tag, "summary")
        self.assertEqual("".join(disclosures[0][0].itertext()), "Set PATH")
        self.assertIn('export PATH="$HOME/.local/bin:$PATH"', "".join(disclosures[0].itertext()))
        self.assertIn("&lt;summary&gt;Literal code&lt;/summary&gt;", rendered)
        self.assertNotIn("open", disclosures[0].attrib)
        for unsafe in ('<details open>\n<summary>Open</summary>\nBody\n</details>',
                       '    <details>\n    <summary>Code example</summary>\n    </details>',
                       '<details onclick="bad">\n<summary>Bad</summary>\nBody\n</details>',
                       '<details>\n<summary onclick="bad">Bad</summary>\nBody\n</details>',
                       '<details>\n<summary>Unclosed</summary>\nBody',
                       '<details>\nBody before summary\n<summary>Late</summary>\n</details>',
                       '<details>\n<summary>Outer</summary>\n<details>\n<summary>Inner</summary>\n</details>\n</details>'):
            with self.subTest(markup=unsafe):
                fragment = module._markdown(unsafe, source, "README.md")
                self.assertEqual(ElementTree.fromstring("<div>" + fragment + "</div>").findall(".//details"), [])
                self.assertIn("&lt;details", fragment)

    def test_readme_sections_follow_heading_hierarchy_and_close_inside_disclosures(self):
        module = importlib.import_module("package_pages")
        text = ('# Guide\n\nIntro.\n\n## Setup\n\nSetup body.\n\n<details>\n<summary>Advanced</summary>\n\n'
                '## Options\n\nOption body.\n\n</details>\n\n## Usage\n\nUsage body.\n\n# Other\n\nOther body.\n')
        rendered = module._markdown(text, self.records[0]["source"], "README.md")
        tree = ElementTree.fromstring("<div>" + rendered + "</div>")
        sections = tree.findall("section")
        self.assertEqual([item.attrib["aria-labelledby"] for item in sections], ["readme-guide", "readme-other"])
        self.assertEqual(sections[0].find("h3").attrib["id"], "readme-guide")
        self.assertEqual([item.attrib["aria-labelledby"] for item in sections[0].findall("section")], ["readme-setup", "readme-usage"])
        disclosure = sections[0].find("section/details")
        self.assertEqual(disclosure.find("section").attrib["aria-labelledby"], "readme-options")
        self.assertEqual(disclosure[0].tag, "summary")
        self.assertIn("Other body.", "".join(sections[1].itertext()))

    def test_disclosure_content_is_escaped_and_cannot_add_scripts_events_images_or_unsafe_links(self):
        module = importlib.import_module("package_pages")
        text = ('<details>\n<summary><img src=x onerror="bad">Details</summary>\n\n'
                '<script>bad()</script>\n\n[Bad](javascript:alert) ![Remote](https://example.com/a.png)\n\n</details>\n')
        rendered = module._markdown(text, self.records[0]["source"], "README.md")
        page = SiteParser(); page.feed(rendered)
        self.assertEqual(sum(item["tag"] == "details" for item in page.elements), 1)
        self.assertFalse(any(item["tag"] in {"script", "img", "iframe", "style"} for item in page.elements))
        self.assertFalse(any(key.startswith("on") for item in page.elements for key in item["attrs"]))
        self.assertFalse(any(item["attrs"].get("href", "").startswith("javascript:") for item in page.elements))
        self.assertIn("&lt;script&gt;bad()&lt;/script&gt;", rendered)

    def test_maximum_hostile_disclosure_input_remains_bounded_and_literal(self):
        script = '''import sys
sys.path.insert(0, sys.argv[1])
import package_pages
source = {"repository": "https://github.com/stubbi/asm", "commit": "a" * 40, "path": "."}
for fragment in ("<details>\\n", "<summary>", "<details>\\n<summary>label</summary>\\n"):
    text = fragment * (package_pages.MAX_README_BYTES // len(fragment))
    result = package_pages._markdown(text, source, "README.md")
    assert '<details class=' not in result and '&lt;' in result
'''
        result = subprocess.run([sys.executable, "-c", script, str(ROOT / "tools")],
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))

    def test_artifact_cards_have_unique_target_specific_names_and_download_labels(self):
        self.records[0]["artifacts"].append({**self.records[0]["artifacts"][0], "target": "aarch64-linux",
            "url": self.records[0]["artifacts"][0]["url"].replace("x86_64-linux", "aarch64-linux")})
        self.generate({("stubbi/math", "0.2.0")})
        page = HierarchyParser(); page.feed(self.read("packages/stubbi/math/0.2.0"))
        cards = [item for item in page.elements if item["tag"] == "article" and "package-artifact" in item["attrs"].get("class", "").split()]
        self.assertEqual(len(cards), 2)
        names = []
        for card in cards:
            name = card["attrs"]["aria-labelledby"]
            heading = next(item for item in page.elements if item["attrs"].get("id") == name)
            text = "".join(heading["text"])
            self.assertIn("Source archive", text)
            self.assertIn(card["attrs"]["data-artifact-target"], text)
            names.append(name)
        self.assertEqual(len(set(names)), 2)
        downloads = [item for item in page.elements if item["tag"] == "a" and "".join(item["text"]).startswith("Download source")]
        self.assertEqual(sorted(item["attrs"]["aria-label"] for item in downloads),
                         ["Download source archive for aarch64-linux", "Download source archive for x86_64-linux"])

    def test_static_discovery_and_missing_pages_omit_package_scripts_but_catalog_return_links_keep_them(self):
        import discovery
        self.generate()
        routes = self.module.write_discovery_pages(self.stage, self.index, discovery.delivery_snapshot(self.records))
        for route in routes:
            page = Page(self.read(route.rstrip("/")))
            self.assertTrue(all(url.endswith(("navigation.js", "repository-stars.js")) for url in page.scripts))
        missing = Page((self.stage / "404.html").read_text())
        self.assertTrue(all(url.endswith(("navigation.js", "repository-stars.js")) for url in missing.scripts))
        for route in ("packages", "packages/stubbi"):
            page = Page(self.read(route))
            self.assertTrue(any(url.endswith("package-page.js") for url in page.scripts))

    def test_breadcrumb_schema_describes_visible_hierarchy_and_retains_native_links(self):
        self.generate()
        page = SiteParser(); page.feed(self.read("packages/stubbi/math/0.2.0"))
        lists = [item for item in page.elements if item["attrs"].get("itemtype") == "https://schema.org/BreadcrumbList"]
        self.assertEqual(len(lists), 1)
        names = ["".join(item["text"]) for item in page.elements if item["attrs"].get("itemprop") == "name"]
        self.assertEqual(names, ["Packages", "stubbi", "stubbi/math", "0.2.0"])
        positions = [item["attrs"]["content"] for item in page.elements if item["attrs"].get("itemprop") == "position"]
        self.assertEqual(positions, ["1", "2", "3", "4"])
        parents = [item["attrs"]["href"] for item in page.elements if item["tag"] == "a" and item["attrs"].get("itemprop") == "item"]
        self.assertEqual([urljoin("https://asm.build/packages/stubbi/math/0.2.0/", path) for path in parents],
                         ["https://asm.build/packages/", "https://asm.build/packages/stubbi/", "https://asm.build/packages/stubbi/math/"])
        self.assertIn("Back to search", " ".join(page.text))

    def test_readme_tables_have_distinct_accessible_names_from_the_source_section(self):
        self.readme.write_text('# Host "support"\n\n| Host | State |\n| --- | --- |\n| Linux | Supported |\n\n| Tool | Version |\n| --- | --- |\n| binutils | 2 |\n')
        self.records[1]["source"]["commit"] = self.commit()
        self.generate()
        page = SiteParser(); page.feed(self.read("packages/stubbi/math"))
        tables = [item for item in page.elements if item["tag"] == "table"]
        self.assertEqual([item["attrs"].get("aria-label") for item in tables],
                         ['Host "support", table 1', 'Host "support", table 2'])

    def test_source_declarations_keep_requirements_features_and_native_package_links(self):
        self.records.append(self.record("1.2.0", self.old_commit, "Core fixture", "MIT", "x86_64-linux", name="stubbi/core"))
        metadata = self.declarations(dependencies=[
            {"name": "stubbi/core", "requirement": "^1.2.0", "optional": False,
             "default_features": True, "features": ["checked"]},
            {"name": "stubbi/vector", "requirement": "~2.3.0", "optional": True,
             "default_features": False, "features": ["portable"]}],
            features={"default": ["vectors"], "vectors": ["dep:stubbi/vector", "stubbi/core/checked"], "portable": []})
        original = deepcopy(metadata)
        self.generate({("stubbi/math", "0.2.0")}, metadata)
        html = self.read("packages/stubbi/math/0.2.0")
        text = " ".join(Page(html).text)
        for value in ("Declared dependencies", "^1.2.0", "~2.3.0", "Required", "Optional",
                      "Default features requested", "Default features disabled", "Requested features: portable",
                      "Enabled by: vectors", "Feature options", "Enabled unless disabled", "Not in this catalog",
                      "Enable dependency", "Request", "No additional package requirements."):
            self.assertIn(value, text)
        self.assertIn("https://asm.build/packages/stubbi/core/", [urljoin("https://asm.build/packages/stubbi/math/0.2.0/", href) for href in Page(html).links])
        self.assertNotIn("https://asm.build/packages/stubbi/vector/", [urljoin("https://asm.build/packages/stubbi/math/0.2.0/", href) for href in Page(html).links])
        self.assertIn("Direct declarations", text)
        self.assertNotIn("ABI, required CPU features, or dependencies", text)
        self.assertEqual(metadata, original)
        overview = self.read("packages/stubbi/math")
        self.assertNotIn("^1.2.0", overview)
        self.assertIn("Dependency information unavailable for this source archive.", overview)

    def test_known_empty_source_declarations_are_distinct_from_unavailable(self):
        self.generate({("stubbi/math", "0.2.0")}, self.declarations())
        old = self.read("packages/stubbi/math/0.2.0")
        self.assertIn("No package dependencies declared.", old)
        self.assertIn("No feature options declared.", old)
        self.assertNotIn("Dependency information unavailable for this source archive.", old)
        self.assertIn("Dependency information unavailable for this source archive.", self.read("packages/stubbi/math/0.10.0"))

    def test_missing_corrupt_unchecked_and_mismatched_declarations_remain_unavailable(self):
        valid = self.declarations()
        cases = [None, {"schema": 99, "sources": []}, {"schema": 1, "sources": valid["sources"] * 2}]
        for field, value in (("name", "stubbi/other"), ("version", "0.10.0"), ("target", "aarch64-macos")):
            changed = deepcopy(valid); changed["sources"][0][field] = value; cases.append(changed)
        for field, value in (("source_sha256", "c" * 64), ("schema", True),
                             ("dependencies", [{"name": "<script>alert(1)</script>"}]),
                             ("features", {"default": ["default"]})):
            changed = deepcopy(valid); changed["sources"][0]["metadata"][field] = value; cases.append(changed)
        dependency = {"name": "stubbi/core", "requirement": "1.0.0", "optional": False,
                      "default_features": True, "features": []}
        for field, value in (("requirement", "javascript:alert(1)"), ("optional", 1),
                             ("features", ["checked", "checked"])):
            changed = deepcopy(valid)
            changed["sources"][0]["metadata"]["dependencies"] = [dict(dependency, **{field: value})]
            cases.append(changed)
        changed = deepcopy(valid)
        changed["sources"][0]["metadata"]["features"] = {"default": ["dep:stubbi/core"]}
        changed["sources"][0]["metadata"]["dependencies"] = [dependency]
        cases.append(changed)
        cases.append({"schema": 1, "sources": valid["sources"] * (registry.MAX_ROWS + 1)})
        for metadata in cases:
            with self.subTest(metadata=metadata):
                self.generate({("stubbi/math", "0.2.0")}, metadata)
                html = self.read("packages/stubbi/math/0.2.0")
                self.assertIn("Dependency information unavailable for this source archive.", html)
                self.assertNotIn("No package dependencies declared.", html)
                self.assertNotIn("<script>alert(1)</script>", html)
        self.generate(dependency_metadata=valid)
        self.assertIn("Dependency information unavailable for this source archive.", self.read("packages/stubbi/math/0.2.0"))

    def test_shared_source_bytes_retain_target_specific_metadata_without_executable_inheritance(self):
        record = self.records[0]
        second = deepcopy(record["artifacts"][0]); second["target"] = "aarch64-linux"
        second["url"] = second["url"].replace("x86_64-linux", "aarch64-linux")
        record["artifacts"].append(second)
        executable = deepcopy(record["artifacts"][0]); executable["kind"] = "executable"
        executable["url"] += ".bin"; record["artifacts"].append(executable)
        metadata = self.declarations()
        arm = deepcopy(metadata["sources"][0]); arm["target"] = "aarch64-linux"
        arm["metadata"]["dependencies"] = [{"name": "stubbi/arm", "requirement": "1.0.0",
            "optional": False, "default_features": True, "features": []}]
        metadata["sources"].append(arm)
        self.generate({("stubbi/math", "0.2.0")}, metadata)
        html = self.read("packages/stubbi/math/0.2.0")
        x86 = html.split('id="artifact-source-x86_64-linux"', 1)[1].split('</article>', 1)[0]
        arm = html.split('id="artifact-source-aarch64-linux"', 1)[1].split('</article>', 1)[0]
        exe = html.split('id="artifact-executable-x86_64-linux"', 1)[1].split('</article>', 1)[0]
        self.assertIn("No package dependencies declared.", x86)
        self.assertNotIn("stubbi/arm", x86)
        self.assertIn("stubbi/arm", arm)
        self.assertNotIn("Declared dependencies", exe)

    def test_static_routes_canonical_chrome_and_plain_catalog_links(self):
        routes = self.generate()
        self.assertEqual(set(routes), {"packages/", "packages/stubbi/", "packages/stubbi/math/",
                                      "packages/stubbi/math/0.2.0/", "packages/stubbi/math/0.10.0/", "404.html"})
        catalog = self.read("packages")
        self.assertIn("https://asm.build/packages/stubbi/math/", [urljoin("https://asm.build/packages/", link) for link in Page(catalog).links])
        self.assertIn('https://asm.build/packages/', catalog)
        overview = self.read("packages/stubbi/math")
        self.assertIn('href="../../../styles.css"', overview)
        self.assertIn('href="../../../packages.css"', overview)
        self.assertIn('src="../../../package-page.js"', overview)
        self.assertIn('href="https://github.com/stubbi/asm#install-the-command"', overview)
        self.assertEqual(overview.count('class="site-header"'), 1)
        self.assertEqual(overview.count('<footer '), 1)
        self.assertNotIn('aria-current="page">Sponsor', overview)
        self.assertIn("namespace", self.read("packages/stubbi").lower())
        missing = (self.stage / "404.html").read_text()
        self.assertIn('content="noindex"', missing)
        self.assertIn('href="https://asm.build/404.html"', missing)

    def test_native_catalog_previews_use_only_the_selected_active_release(self):
        self.generate()
        catalog = self.read('packages')
        self.assertIn('Source targets', catalog)
        self.assertIn('aarch64-macos', catalog)
        self.assertNotIn('x86_64-linux', catalog)
        self.assertIn('<dd>AGPL-3.0-or-later</dd>', catalog)
        self.assertNotIn('<dd>MIT</dd>', catalog)
        self.assertIn('stubbi/math/0.10.0/', catalog)

    def test_native_catalog_pages_are_bounded_sorted_and_keep_withdrawn_packages(self):
        self.records = [self.record('0.2.0', self.old_commit, 'Package ' + str(number), 'MIT',
                                    'x86_64-linux', name=f'stubbi/item-{number:02d}')
                        for number in reversed(range(53))]
        self.records[0].update(yanked=True, yank_reason='Withdrawn fixture')
        routes = self.generate()
        self.assertIn('packages/page/2/', routes)
        self.assertNotIn('packages/page/3/', routes)
        names = []
        for route, expected_count, expected_range in (
                ('packages/', 50, 'Showing 1–50 of 53 packages.'),
                ('packages/page/2/', 3, 'Showing 51–53 of 53 packages.')):
            page = self.read(route)
            parsed = Page(page)
            identities = [urlsplit(urljoin('https://asm.build/' + route, link)).path
                          for link in parsed.catalog_links]
            self.assertEqual(len(identities), expected_count)
            names.extend(identities)
            self.assertIn(expected_range, page)
            self.assertIn('aria-label="Catalog pages"', page)
        self.assertEqual(names, [f'/packages/stubbi/item-{number:02d}/' for number in range(53)])
        first, second = self.read('packages'), self.read('packages/page/2')
        self.assertIn('href="../packages/" aria-current="page">All packages</a>', first)
        self.assertIn('href="../../../packages/" aria-current="location">All packages</a>', second)
        self.assertIn('Page 1 of 2', first)
        self.assertIn('Assembly package catalog and releases — page 2', second)
        self.assertIn('href="../packages/page/2/" rel="next"', first)
        self.assertNotIn('rel="prev"', first)
        self.assertIn('href="../../../packages/" rel="prev"', second)
        self.assertNotIn('rel="next"', second)
        self.assertIn('No active release', second)
        self.assertNotIn('item-52/0.2.0/', second)
        self.assertIn('href="../../../explore/"', second)
        self.assertIn('href="../../../index.html#search?all=1"', second)


    def test_namespace_pagination_does_not_collide_with_page_namespace_or_package(self):
        self.records = [self.record('0.2.0', self.old_commit, 'Package ' + str(number), 'MIT',
                                    'x86_64-linux', name=f'page/item-{number:02d}')
                        for number in range(52)]
        self.records.append(self.record('0.2.0', self.old_commit, 'A package named page', 'MIT',
                                        'x86_64-linux', name='page/page'))
        routes = self.generate()
        for route in ('packages/page/', 'packages/page/2/', 'packages/page/page/',
                      'packages/page/page/0.2.0/', 'packages/page/page/2/'):
            self.assertIn(route, routes)
        first, second = self.read('packages/page'), self.read('packages/page/page/2')
        self.assertIn('href="../../packages/" aria-current="location">All packages</a>', first)
        self.assertIn('Showing 1–50 of 53 packages.', first)
        self.assertIn('href="../../packages/page/page/2/" rel="next"', first)
        self.assertIn('href="../../../../packages/page/" rel="prev"', second)
        self.assertIn('Showing 51–53 of 53 packages.', second)
        self.assertIn('A package named page', self.read('packages/page/page'))
        self.assertEqual(len(routes), len(set(routes)))


    def test_empty_native_catalog_has_no_pagination(self):
        self.records = []
        routes = self.generate()
        catalog = self.read('packages')
        self.assertIn('The registry has no published packages yet.', catalog)
        self.assertNotIn('aria-label="Catalog pages"', catalog)
        self.assertEqual(set(routes), {'packages/', '404.html'})


    def test_missing_page_recovery_and_assets_resolve_from_nested_unknown_address(self):
        self.generate()
        page = Page((self.stage / "404.html").read_text())
        requested = "https://asm.build/packages/unknown/deep/"
        resolved = [urljoin(requested, link) for link in page.links]
        self.assertIn("https://asm.build/packages/", resolved)
        self.assertIn("https://asm.build/index.html", resolved)
        self.assertTrue(all(urlsplit(urljoin(requested, asset)).path.count("/") == 1 for asset in page.assets))
        self.assertIn(requested + "#main", resolved)

    def test_shared_header_search_and_navigation_resolve_from_nested_and_missing_routes(self):
        self.generate()
        for filename, address in (("packages/stubbi/math/index.html", "https://asm.build/packages/stubbi/math/"),
                                  ("404.html", "https://asm.build/unknown/deep/")):
            with self.subTest(filename=filename):
                html = (self.stage / filename).read_text()
                page = Page(html)
                forms = [form for form in page.forms if "data-header-search" in form]
                self.assertEqual(len(forms), 1)
                self.assertEqual(forms[0]["method"], "get")
                self.assertIn("hidden", forms[0])
                self.assertEqual(urljoin(address, forms[0]["action"]), "https://asm.build/index.html")
                self.assertIn('class="header-search-fallback"', html)
                navigation = [attrs for attrs in page.script_attributes if attrs.get("src", "").endswith("navigation.js")]
                self.assertEqual(len(navigation), 1)
                self.assertNotIn("defer", navigation[0])
                self.assertNotIn("async", navigation[0])
                self.assertEqual(urljoin(address, navigation[0]["src"]), "https://asm.build/navigation.js")
                stars = [attrs for attrs in page.script_attributes if attrs.get("src", "").endswith("repository-stars.js")]
                self.assertEqual(len(stars), 1)
                self.assertEqual(set(stars[0]), {"src", "defer"})
                self.assertEqual(urljoin(address, stars[0]["src"]), "https://asm.build/repository-stars.js")

    def test_exact_release_uses_canonical_old_summary_license_source_and_readme(self):
        self.generate()
        old = self.read("packages/stubbi/math/0.2.0")
        self.assertIn("Old summary", old); self.assertNotIn("New summary", old)
        self.assertIn("Old exact body.", old); self.assertNotIn("New exact body.", old)
        self.assertIn("<dd>MIT</dd>", old)
        self.assertIn(self.old_commit, old)
        self.assertIn("/blob/" + self.old_commit + "/examples/math/src/min.s", old)
        self.assertIn("Source snapshot", old)
        self.assertIn("aarch64-macos", self.read("packages/stubbi/math"))
        links = [urljoin("https://asm.build/packages/stubbi/math/0.2.0/", link) for link in Page(old).links]
        self.assertIn("https://asm.build/packages/stubbi/math/", links)
        self.assertLess(links.index("https://asm.build/packages/stubbi/math/0.10.0/"), links.index("https://asm.build/packages/stubbi/math/0.2.0/"))
        self.assertIn("registry/v1/packages/stubbi/math/0.2.0.json", old)
        self.assertLess(old.index('id="use"'), old.index('id="files"'))
        page = Page(old)
        self.assertEqual(len(page.ids), len(set(page.ids)))

    def test_only_byte_checked_artifacts_become_download_links(self):
        self.generate({("stubbi/math", "0.2.0")})
        old, new = self.read("packages/stubbi/math/0.2.0"), self.read("packages/stubbi/math/0.10.0")
        self.assertIn(self.records[0]["artifacts"][0]["url"], Page(old).links)
        self.assertNotIn(self.records[1]["artifacts"][0]["url"], Page(new).links)
        self.assertIn(self.records[1]["artifacts"][0]["url"], "".join(Page(new).text))
        self.assertIn("Not run", new)
        self.assertIn("asm fetch stubbi/math@0.10.0 --target aarch64-macos --kind source", new)
        self.assertNotIn("asm add ", new); self.assertNotIn("asm install ", new)
        self.assertIn("asm doctor", new)
        self.assertIn("identity", new); self.assertIn("safety", new)
        self.assertIn('id="fetch-source-aarch64-macos"', new)
        self.assertIn('data-artifact-target="aarch64-macos"', new)
        self.assertIn('data-artifact-architecture="aarch64"', new)
        self.assertIn('<label for="artifact-architecture">Architecture</label>', new)
        self.assertIn('ARM64 (aarch64)', new)

    def test_use_precedes_long_documentation_and_selects_an_exact_file(self):
        self.generate()
        page = self.read("packages/stubbi/math")
        self.assertLess(page.index('id="use"'), page.index('id="readme"'))
        use = page.split('id="use"', 1)[1].split('</section>', 1)[0]
        self.assertIn('aria-label="Filter release files"', use)
        self.assertIn('id="selected-fetch-command"', use)
        self.assertIn('asm fetch stubbi/math@0.10.0 --target aarch64-macos --kind source', use)
        self.assertIn('Source archive · aarch64-macos', use)
        self.assertIn('<dt>Formats</dt><dd>Source archive</dd>', page)
        self.assertNotIn('asm add ', use)

    def test_quick_fetch_does_not_choose_one_of_multiple_targets(self):
        extra = deepcopy(self.records[1]['artifacts'][0])
        extra.update(target='x86_64-linux', url=extra['url'].replace('aarch64-macos','x86_64-linux'))
        self.records[1]['artifacts'].append(extra)
        self.generate()
        page = self.read('packages/stubbi/math')
        use = page.split('id="use"', 1)[1].split('</section>', 1)[0]
        self.assertIn('data-selected-fetch hidden', use)
        self.assertIn('Choose a release file below', use)
        self.assertNotIn('asm fetch ', use)

    def test_failed_byte_evidence_stays_failed_and_does_not_enable_download(self):
        self.generate()
        self.index["packages"][0]["versions"][1]["evidence"]["artifacts"] = "fail"
        self.module.write_package_pages(self.repo, self.stage, self.records, self.index, self.counts)
        page = self.read("packages/stubbi/math/0.10.0")
        self.assertIn("Artifact byte check: Fail.", page)
        self.assertNotIn(self.records[1]["artifacts"][0]["url"], Page(page).links)

    def test_yanked_release_keeps_reason_and_metadata_without_fetch_or_download(self):
        self.records[1].update(yanked=True, yank_reason="Broken <target> fixture.")
        self.generate({("stubbi/math", "0.10.0")}, self.declarations(self.records[1]))
        yanked = self.read("packages/stubbi/math/0.10.0")
        self.assertIn("Yanked", yanked); self.assertIn("Broken &lt;target&gt; fixture", yanked)
        self.assertNotIn("fixture..", yanked)
        self.assertNotIn("asm fetch", yanked)
        self.assertNotIn(self.records[1]["artifacts"][0]["url"], Page(yanked).links)
        self.assertIn("No package dependencies declared.", yanked)
        self.assertIn("Old summary", self.read("packages/stubbi/math"))

    def test_no_active_release_does_not_select_yanked_release(self):
        for record in self.records: record.update(yanked=True, yank_reason="Withdrawn fixture")
        self.generate()
        page = self.read("packages/stubbi/math")
        self.assertIn("No active release", page)
        self.assertNotIn("asm fetch", page)
        self.assertNotIn("New exact body.", page)
        self.assertIn("0.10.0/", page)

    def test_optional_counts_distinguish_unknown_and_measured_zero(self):
        self.generate()
        self.assertIn("GitHub asset downloads: 0", accessible_text(self.read("packages/stubbi/math")))
        old = self.read("packages/stubbi/math/0.2.0")
        self.assertIn("GitHub asset downloads: 0", accessible_text(old))
        self.assertIn("observed 2026-11-07", old)
        self.assertIn("GitHub asset downloads: unavailable", self.read("packages/stubbi/math/0.10.0"))

    def test_missing_root_readme_wrong_repository_commit_and_oversize_are_explicit(self):
        self.records = [self.record("0.1.0", self.new_commit, "Hello fixture", "MIT", "x86_64-linux", name="stubbi/hello", source_path="examples")]
        self.generate()
        hello = self.read("packages/stubbi/hello")
        self.assertIn("README is unavailable", hello)
        self.assertNotIn("Nested README must not be guessed", hello)
        self.records[0]["source"]["path"] = "examples/math"
        self.git("remote", "set-url", "origin", "https://github.com/another/repository")
        self.generate()
        self.assertNotIn("New exact body", self.read("packages/stubbi/hello"))
        self.git("remote", "set-url", "origin", "https://github.com/stubbi/asm")
        self.readme.write_bytes(b"x" * (128 * 1024 + 1))
        self.records[0]["source"]["commit"] = self.commit()
        self.generate()
        self.assertIn("README is unavailable", self.read("packages/stubbi/hello"))
        self.records[0]["source"]["commit"] = "f" * 40
        self.generate()
        self.assertIn("README is unavailable", self.read("packages/stubbi/hello"))

    def test_supported_root_readme_names_use_the_recorded_snapshot(self):
        for filename in ("README", "README.txt"):
            with self.subTest(filename=filename):
                for candidate in ("README.md", "README", "README.txt"):
                    (self.readme.parent / candidate).unlink(missing_ok=True)
                selected = self.readme.parent / filename
                selected.write_text("# Accepted root document\n\nRecorded " + filename + " body.\n\n[This document](#accepted-root-document)\n")
                commit = self.commit()
                self.records[1]["source"]["commit"] = commit
                selected.write_text("Uncommitted text must not appear.\n")
                self.generate()
                page = self.read("packages/stubbi/math/0.10.0")
                links = Page(page).links
                pinned = "https://github.com/stubbi/asm/blob/" + commit + "/examples/math/" + filename
                self.assertIn(pinned, links)
                self.assertIn(pinned + "#accepted-root-document", links)
                self.assertIn("Recorded " + filename + " body.", page)
                self.assertNotIn("Uncommitted text", page)
                self.assertIn("Old exact body.", self.read("packages/stubbi/math/0.2.0"))

    def test_root_readme_selection_has_a_deterministic_priority(self):
        (self.readme.parent / "README").write_text("Plain README fallback.\n")
        (self.readme.parent / "README.txt").write_text("Text README fallback.\n")
        self.records[1]["source"]["commit"] = self.commit()
        self.generate()
        page = self.read("packages/stubbi/math/0.10.0")
        self.assertIn("New exact body.", page)
        self.assertNotIn("Plain README fallback.", page)
        self.assertNotIn("Text README fallback.", page)
        self.readme.unlink()
        self.records[1]["source"]["commit"] = self.commit()
        self.generate()
        page = self.read("packages/stubbi/math/0.10.0")
        self.assertIn("Plain README fallback.", page)
        self.assertNotIn("Text README fallback.", page)

    def test_readme_hostile_markup_links_images_and_invalid_encoding_do_not_execute(self):
        self.readme.write_text('# Readme\n\n<script>alert("bad")</script>\n\n[Bad](javascript:alert)\n\n[Escape](../../private)\n\n![remote](https://example.com/x.png)\n\n| Value | Result |\n| --- | --- |\n| `one` | **two** |\n\n```asm\nmov rax, 1\n```\n')
        self.records[1]["source"]["commit"] = self.commit()
        self.generate()
        page = self.read("packages/stubbi/math")
        parsed = Page(page)
        self.assertEqual(sorted(parsed.scripts), ["../../../app.js", "../../../navigation.js", "../../../package-page.js", "../../../repository-stars.js"])
        self.assertEqual(len(parsed.script_attributes), 5)
        self.assertEqual([attrs for attrs in parsed.script_attributes if "src" not in attrs],
                         [{"type": "application/ld+json"}])
        self.assertEqual(self.schema(page)["mainEntity"]["version"], "0.10.0")
        self.assertFalse(any(url.startswith("javascript:") or "private" in url for url in parsed.links))
        self.assertNotIn('<img src="https://example.com', page)
        self.assertIn("&lt;script&gt;", page)
        self.assertIn("package-table-scroll", page)
        self.assertIn('<pre tabindex="0"><code>', page)
        self.readme.write_bytes(b"\xff\xfe")
        self.records[1]["source"]["commit"] = self.commit()
        self.generate()
        self.assertIn("README is unavailable", self.read("packages/stubbi/math"))

    def test_maximum_readme_with_unfinished_links_remains_bounded(self):
        # Run hostile inputs outside the suite process so a regression cannot
        # occupy the entire site check indefinitely.
        script = '''import sys
sys.path.insert(0, sys.argv[1])
import package_pages
source = {"repository": "https://github.com/stubbi/asm", "commit": "a" * 40, "path": "."}
for fragment in ("[", "[a]("):
    text = fragment * (package_pages.MAX_README_BYTES // len(fragment))
    result = package_pages._markdown(text, source, "README.md")
    assert result == "<p>" + text + "</p>"
'''
        result = subprocess.run([sys.executable, "-c", script, str(ROOT / "tools")],
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))

    def test_readme_heading_ids_do_not_collide_with_numbered_titles(self):
        self.readme.write_text("# Part\n\n## Part\n\n# Part-2\n\n# Part\n")
        self.records[1]["source"]["commit"] = self.commit()
        self.generate()
        page = Page(self.read("packages/stubbi/math"))
        self.assertEqual(len(page.ids), len(set(page.ids)))

    def test_invalid_package_route_is_rejected_before_writing_pages(self):
        self.records[0]["name"] = "../escape"
        with self.assertRaises(registry.RegistryError): self.generate()
        self.assertFalse((self.stage / "packages").exists())


if __name__ == "__main__": unittest.main()


class DiscoveryPageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.stage = Path(self.temp.name)
        (self.stage / "index.html").write_text((ROOT / "site/index.html").read_text())
        self.records = registry.read_records(ROOT / "registry")
        _, self.index = registry.make_indexes(self.records, set())
        self.module = importlib.import_module("package_pages")
        import discovery
        self.snapshot = discovery.delivery_snapshot(self.records)

    def test_architecture_browsing_remains_in_explore_without_homepage_panels(self):
        import registry_explore
        before = deepcopy(self.index)
        home = (self.stage / "index.html").read_text()
        self.assertNotIn("architecture-browse:start", home)
        self.assertNotIn("discovery-directory", home)
        html = registry_explore.explore_page(self.stage, self.index, self.snapshot, None, None, "architectures")
        self.assertEqual(self.index, before)
        page = Page(html)
        self.assertIn("Architectures", "".join(page.text))
        expected = {"aarch64", "x86_64", "riscv64"}
        self.assertTrue(all(any("browse/architectures/" + key + "/" in href for href in page.links) for key in expected))
        for key in expected:
            detail = registry_explore.explore_page(self.stage, self.index, self.snapshot, None, None, "architectures/" + key)
            self.assertIn("stubbi/", detail)
            self.assertIn(key, detail)
        self.assertEqual(len(page.ids), len(set(page.ids)))

    def write_categories(self, value):
        registry.write_atomic(self.stage / "registry/v1/categories.json", registry.json_bytes(value))

    def test_native_pages_keep_unknown_counts_and_do_not_relabel_totals(self):
        routes = self.module.write_discovery_pages(self.stage, self.index, self.snapshot)
        self.assertEqual(set(routes), {"browse/popular/", "browse/new/", "browse/updated/", "discovery/"})
        page = (self.stage / "browse/popular/index.html").read_text()
        self.assertIn("Download data is unavailable", page)
        self.assertNotIn("1 downloads", page)
        metrics = (self.stage / "discovery/index.html").read_text()
        self.assertIn("known bots, and internal validation do not enter Popular", metrics)
        self.assertIn("Historical imports do not invent those events", metrics)
        self.assertIn("≥", metrics)

    def test_real_snapshot_order_dates_zero_and_lower_bounds_reach_native_html(self):
        self.snapshot["observed_at"] = "2026-11-07T08:00:00Z"
        self.snapshot["stale"] = False
        for i, fact in enumerate(self.snapshot["packages"]):
            fact.update(first_published_at="2026-11-01T00:29:24Z", last_published_at="2026-11-01T19:08:39Z",
                        downloads_30d=i + 1, downloads_30d_exact=(i == 0),
                        downloads_30d_coverage="complete" if i == 0 else "lower-bound")
        names = [fact["name"] for fact in self.snapshot["packages"]]
        self.snapshot["feeds"] = {"popular": names[::-1], "new": names, "updated": names}
        page = self.module.discovery_page(self.stage, self.index, self.snapshot, "popular")
        self.assertLess(page.index('>' + names[-1] + '</a>'), page.index('>' + names[0] + '</a>'))
        self.assertIn("≥ 3 downloads", accessible_text(page))
        self.assertIn("1 downloads", accessible_text(page))
        new = self.module.discovery_page(self.stage, self.index, self.snapshot, "new")
        self.assertIn('datetime="2026-11-01T00:29:24Z"', new)
        self.assertIn("First GitHub release", new)
        self.assertNotIn("first entered the registry", new)

    def test_explicit_purpose_categories_join_active_packages_and_reject_typos(self):
        value = {"schema": 1, "categories": [{"id": "math", "name": "Math", "packages": ["stubbi/math"]}]}
        self.write_categories(value)
        enriched = self.module.with_discovery_categories(self.stage, self.index, self.snapshot)
        self.assertEqual(enriched["categories"], value["categories"])
        page = self.module.discovery_page(self.stage, self.index, self.snapshot, "categories/math")
        self.assertIn('stubbi/math</a>', page)
        self.assertNotIn('stubbi/hello</a>', page)
        self.assertIn('Math</h1>', page)
        with self.assertRaises(KeyError):
            self.module.discovery_page(self.stage, self.index, self.snapshot, "categories/unknown")
        index = deepcopy(self.index)
        next(item for item in index["packages"] if item["name"] == "stubbi/math")["latest"] = None
        self.assertEqual(self.module.with_discovery_categories(self.stage, index, self.snapshot)["categories"], [])
        value["categories"][0]["packages"] = ["stubbi/typo"]
        self.write_categories(value)
        with self.assertRaises(registry.RegistryError):
            self.module.with_discovery_categories(self.stage, self.index, self.snapshot)

    def test_category_paths_and_duplicate_feed_members_fail_closed(self):
        for identifier in ("../math", "math/evil", "math--code", "math-", "Math"):
            self.write_categories({"schema": 1, "categories": [{"id": identifier, "name": "Math", "packages": ["stubbi/math"]}]})
            with self.subTest(identifier=identifier), self.assertRaises(registry.RegistryError):
                self.module.with_discovery_categories(self.stage, self.index, self.snapshot)
        (self.stage / "registry/v1/categories.json").unlink()
        self.snapshot["feeds"]["popular"] = ["stubbi/math", "stubbi/math"]
        with self.assertRaises(registry.RegistryError):
            self.module.discovery_page(self.stage, self.index, self.snapshot, "popular")

    def test_same_second_publication_precedes_a_fractional_observation(self):
        self.snapshot["observed_at"] = "2026-11-07T07:00:00.123456Z"
        for fact in self.snapshot["packages"]:
            fact.update(first_published_at="2026-11-07T07:00:00Z", last_published_at="2026-11-07T07:00:00Z")
        self.snapshot["feeds"]["new"] = ["stubbi/math"]
        page = self.module.discovery_page(self.stage, self.index, self.snapshot, "new")
        self.assertIn('datetime="2026-11-07T07:00:00Z"', page)
        next(fact for fact in self.snapshot["packages"] if fact["name"] == "stubbi/math")["first_published_at"] = "2026-11-07T07:00:00.234567Z"
        with self.assertRaises(registry.RegistryError):
            self.module.discovery_page(self.stage, self.index, self.snapshot, "new")

    def test_publication_date_is_not_presented_as_the_highest_version_date(self):
        self.snapshot["observed_at"] = "2026-11-07T08:00:00Z"
        for fact in self.snapshot["packages"]:
            fact.update(first_published_at="2026-11-01T00:00:00Z", last_published_at="2026-11-06T00:00:00Z")
        self.snapshot["feeds"]["updated"] = ["stubbi/math"]
        page = self.module.discovery_page(self.stage, self.index, self.snapshot, "updated")
        latest = next(package["latest"] for package in self.index["packages"] if package["name"] == "stubbi/math")
        self.assertIn("Latest version " + latest, page)
        self.assertIn('Latest GitHub release <time datetime="2026-11-06T00:00:00Z"', page)
        self.assertIn("Package release activity, newest publication first.", page)

    def test_discovery_targets_describe_the_latest_active_release(self):
        math = next(item for item in self.index["packages"] if item["name"] == "stubbi/math")
        math["versions"][0]["artifacts"][0]["target"] = "aarch64-macos"
        math["targets"].append("aarch64-macos")
        self.write_categories({"schema": 1, "categories": [{"id": "math", "name": "Math", "packages": ["stubbi/math"]}]})
        page = self.module.discovery_page(self.stage, self.index, self.snapshot, "categories/math")
        self.assertIn("x86_64-linux", page)
        self.assertNotIn("aarch64-macos", page)

    def test_historical_publication_does_not_require_download_observations(self):
        self.snapshot["publication_observed_at"] = "2026-11-07T08:00:00Z"
        for fact in self.snapshot["packages"]:
            fact.update(first_published_at="2026-11-01T00:00:00Z", last_published_at="2026-11-06T00:00:00Z")
        self.snapshot["feeds"]["new"] = ["stubbi/math"]
        self.assertIsNone(self.snapshot["observed_at"])
        page = self.module.discovery_page(self.stage, self.index, self.snapshot, "new")
        self.assertIn('datetime="2026-11-01T00:00:00Z"', page)

    def test_zero_window_does_not_deny_downloads_before_the_window(self):
        counts = {"schema": 1, "source": "asm-delivery-events", "complete": False,
                  "collection_started_at": "2026-01-01T00:00:00Z", "observed_at": "2026-11-07T08:00:00Z",
                  "packages": {"stubbi/math": {"total": 0, "versions": {"0.4.0": 0}}}}
        message = self.module._counts(counts, "stubbi/math", None)
        self.assertIn("observed part of this window", message)
        self.assertNotIn("since", message)
        self.assertNotIn("2026-01-01", message)
        counts["stale"] = True
        self.assertIn("Observations are stale", self.module._counts(counts, "stubbi/math", None))

    def test_catalog_stats_retain_history_without_counting_duplicates_or_storage_objects(self):
        expected = self.module.catalog_stats(self.index)
        index = deepcopy(self.index)
        index["packages"].append(deepcopy(index["packages"][0]))
        for package in index["packages"]:
            package["versions"].append(deepcopy(package["versions"][0]))
            package["targets"] = ["not-a-published-target"]
            for release in package["versions"]:
                release["yanked"] = True
                release["artifacts"].append(deepcopy(release["artifacts"][0]))
        self.assertEqual(self.module.catalog_stats(index), expected)
        self.assertEqual(self.module.catalog_stats({"schema": 1, "packages": []}),
                         {"packages": 0, "releases": 0, "files": 0, "targets": 0})
