"""Bounded agent catalog tests. Remote responses use fixed, local fixtures."""

import copy
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, HTTPServer
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.request import HTTPSHandler


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import registry
import agent_catalog


def release(name="test/hello", version="1.0.0", target="x86_64-linux", license="MIT", yanked=False):
    record = {
        "schema": 1, "name": name, "version": version, "summary": "Small assembly example.",
        "license": license,
        "source": {"repository": "https://github.com/test/asm", "commit": "a" * 40, "path": "."},
        "yanked": yanked,
        "artifacts": [{"target": target, "kind": "source", "sha256": "b" * 64, "bytes": 123,
                       "url": f"https://github.com/test/asm/releases/download/{name.replace('/', '-')}-{version}/source-{target}.tar.gz"}],
    }
    if yanked:
        record["yank_reason"] = "Incorrect output."
    return record


def index(*records):
    return registry.make_indexes(list(records))[1]


class Response(io.BytesIO):
    def __init__(self, data, *, status=200, url="https://asm.build/registry/v1/index.json", headers=None):
        super().__init__(data)
        self.status = status
        self.url = url
        self.headers = headers or {}

    def geturl(self):
        return self.url


class Opener:
    def __init__(self, response=None, error=None):
        self.response, self.error = response, error
        self.requests = []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        if self.error:
            raise self.error
        return self.response


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "index.json"

    def catalog(self, value):
        self.path.write_bytes(registry.json_bytes(value))
        return agent_catalog.Catalog(self.path)

    def test_real_repository_catalog_retains_exact_release_license_and_evidence(self):
        records = registry.read_records(ROOT / "registry")
        catalog = self.catalog(registry.make_indexes(records)[1])
        result = catalog.search("HELLO", target="x86_64-linux")
        self.assertGreater(result["total"], 0)
        exact = catalog.inspect("stubbi/hello", "0.2.0", target="x86_64-linux")
        record = next(r for r in records if r["name"] == "stubbi/hello" and r["version"] == "0.2.0")
        self.assertEqual(exact["package"]["license"], record["license"])
        self.assertEqual(exact["package"]["source"], record["source"])
        self.assertEqual(exact["package"]["evidence"]["formal"], "not-run")
        self.assertTrue(exact["selection"]["selectable"])
        self.assertEqual(exact["catalog"]["sha256"], hashlib.sha256(self.path.read_bytes()).hexdigest())
        self.assertTrue(exact["catalog"]["observed_at"].endswith("Z"))
        self.assertIn("HTTPS", " ".join(exact["trust_limits"]))
        json.dumps(exact, allow_nan=False)

    def test_search_matches_target_and_license_on_the_same_active_release(self):
        catalog = self.catalog(index(release(version="1.0.0", license="MIT"),
                                     release(version="2.0.0", target="aarch64-linux", license="Apache-2.0")))
        self.assertEqual(catalog.search("hello", target="aarch64-linux", license="MIT")["packages"], [])
        selected = catalog.search("assembly", target="x86_64-linux", license="MIT")["packages"][0]
        self.assertEqual(selected["version"], "1.0.0")
        self.assertEqual(selected["license"], "MIT")
        self.assertEqual(selected["artifacts"][0]["target"], "x86_64-linux")

    def test_search_uses_numeric_versions_excludes_yanks_and_paginates_stably(self):
        catalog = self.catalog(index(release(version="2.0.0"), release(version="10.0.0"),
                                     release(version="11.0.0", yanked=True), release(name="test/alpha"),
                                     release(name="test/zulu")))
        page = catalog.search("", limit=1, offset=1)
        self.assertEqual(page["total"], 3)
        self.assertEqual(page["packages"][0]["name"], "test/hello")
        self.assertEqual(page["packages"][0]["version"], "10.0.0")
        self.assertEqual(page["next_offset"], 2)
        self.assertIsNone(catalog.search("", limit=1, offset=3)["next_offset"])
        self.assertEqual(catalog.search("", limit=1, offset=3)["packages"], [])

    def test_inspection_is_exact_and_keeps_yanked_metadata_without_selection(self):
        catalog = self.catalog(index(release(), release(version="2.0.0", license="Apache-2.0", yanked=True)))
        exact = catalog.inspect("test/hello", "2.0.0", target="x86_64-linux")
        self.assertEqual(exact["package"]["license"], "Apache-2.0")
        self.assertEqual(exact["package"]["yank_reason"], "Incorrect output.")
        self.assertFalse(exact["selection"]["selectable"])
        self.assertEqual(exact["selection"]["artifacts"], [])
        self.assertEqual(catalog.search("hello")["packages"][0]["version"], "1.0.0")
        for name, version in (("test/hello", "3.0.0"), ("test/other", "1.0.0")):
            with self.subTest(name=name, version=version), self.assertRaises(registry.RegistryError):
                catalog.inspect(name, version)

    def test_inspection_requires_an_explicit_available_target_for_selection(self):
        catalog = self.catalog(index(release()))
        for target in (None, "aarch64-linux"):
            result = catalog.inspect("test/hello", "1.0.0", target=target)
            self.assertFalse(result["selection"]["selectable"])
            self.assertEqual(result["selection"]["artifacts"], [])
            self.assertTrue(result["selection"]["reasons"])

    def test_results_cannot_mutate_cached_release_metadata(self):
        catalog = self.catalog(index(release()))
        result = catalog.inspect("test/hello", "1.0.0", target="x86_64-linux")
        result["package"]["artifacts"][0]["sha256"] = "0" * 64
        self.assertEqual(catalog.inspect("test/hello", "1.0.0")["package"]["artifacts"][0]["sha256"], "b" * 64)

    def test_tool_arguments_are_bounded_and_never_accept_urls(self):
        catalog = self.catalog(index(release()))
        cases = [dict(query=None), dict(query="x" * 257), dict(query="hello\n"),
                 dict(query="", limit=0), dict(query="", limit=21), dict(query="", limit=True),
                 dict(query="", offset=-1), dict(query="", offset=4097), dict(query="", offset=True),
                 dict(query="", target="https://evil.test/catalog"), dict(query="", target=[]),
                 dict(query="", license="MIT OR Apache-2.0"), dict(query="", license=[])]
        for arguments in cases:
            with self.subTest(arguments=arguments), self.assertRaises(registry.RegistryError):
                catalog.search(**arguments)
        for name, version in (("../hello", "1.0.0"), ("test/hello", "latest")):
            with self.subTest(name=name, version=version), self.assertRaises(registry.RegistryError):
                catalog.inspect(name, version)

    def test_rejects_duplicate_json_keys_nonfinite_and_deep_nesting(self):
        for data in (b'{"schema":1,"schema":1,"packages":[]}', b'{"schema":NaN,"packages":[]}',
                     b'{"schema":1,"packages":' + b'[' * 2000 + b']' * 2000 + b'}'):
            self.path.write_bytes(data)
            with self.subTest(data=data[:50]), self.assertRaises(registry.RegistryError):
                agent_catalog.Catalog(self.path).search("")

    def test_catalog_encoding_is_utf8_without_an_ambiguous_byte_order_mark(self):
        text = '{"schema":1,"packages":[]}'
        for data in (text.encode("utf-16"), text.encode("utf-8-sig"), b"\xff\xfe"):
            self.path.write_bytes(data)
            with self.subTest(data=data[:20]), self.assertRaises(registry.RegistryError):
                agent_catalog.Catalog(self.path).search("")

    def test_hostile_catalog_keys_cannot_expand_error_output(self):
        key = "x" * 10000
        self.path.write_text('{"' + key + '":1,"' + key + '":2}')
        with self.assertRaises(registry.RegistryError) as caught:
            agent_catalog.Catalog(self.path).search("")
        self.assertLess(len(str(caught.exception)), 1000)

    def test_rejects_missing_unknown_and_inconsistent_canonical_fields(self):
        base = index(release())
        mutations = [lambda v: v.update(schema=True), lambda v: v.update(extra=1),
                     lambda v: v.pop("packages"), lambda v: v["packages"][0].pop("latest"),
                     lambda v: v["packages"][0].update(latest="9.0.0"),
                     lambda v: v["packages"][0].update(license="Apache-2.0"),
                     lambda v: v["packages"][0].update(repository="https://github.com/other/repo"),
                     lambda v: v["packages"][0].update(targets=["aarch64-linux"]),
                     lambda v: v["packages"][0]["versions"][0].pop("license"),
                     lambda v: v["packages"][0]["versions"][0].update(extra=1),
                     lambda v: v["packages"][0]["versions"][0]["source"].pop("commit"),
                     lambda v: v["packages"][0]["versions"][0]["evidence"].pop("formal"),
                     lambda v: v["packages"][0]["versions"][0]["evidence"].update(formal="pass"),
                     lambda v: v["packages"].append(copy.deepcopy(v["packages"][0])),
                     lambda v: v["packages"][0]["versions"].append(copy.deepcopy(v["packages"][0]["versions"][0]))]
        for mutation in mutations:
            value = copy.deepcopy(base)
            mutation(value)
            with self.subTest(value=value), self.assertRaises(registry.RegistryError):
                self.catalog(value).search("")

    def test_rejects_forged_artifacts_before_returning_any_matches(self):
        for url in ("file:///etc/passwd", "https://github.com.evil.test/a/b/releases/download/v1/a.tar.gz",
                    "https://user@github.com/a/b/releases/download/v1/a.tar.gz",
                    "https://github.com/a/b/releases/download/%2e%2e/a.tar.gz",
                    "https://github.com/a/b/releases/download/v1/a.tar.gz?token=1"):
            value = index(release(name="test/alpha"), release(name="test/zulu"))
            value["packages"][1]["versions"][0]["artifacts"][0]["url"] = url
            with self.subTest(url=url), self.assertRaises(registry.RegistryError):
                self.catalog(value).search("alpha", limit=1)

    def test_rejects_reused_artifact_urls_across_releases(self):
        value = index(release(), release(version="2.0.0"))
        value["packages"][0]["versions"][1]["artifacts"][0]["url"] = value["packages"][0]["versions"][0]["artifacts"][0]["url"]
        with self.assertRaises(registry.RegistryError):
            self.catalog(value).search("")

    def test_local_catalog_refuses_symlinks_nonregular_files_and_oversize(self):
        self.path.write_bytes(b" " * (4 * 1024 * 1024 + 1))
        with self.assertRaises(registry.RegistryError):
            agent_catalog.Catalog(self.path).search("")
        link = self.path.with_name("link.json")
        link.symlink_to(self.path)
        for path in (link, self.path.parent, self.path.with_name("missing.json")):
            with self.subTest(path=path), self.assertRaises(registry.RegistryError):
                agent_catalog.Catalog(path).search("")

    def test_catalog_has_a_finite_release_count(self):
        value = index(release())
        template = value["packages"][0]["versions"][0]
        value["packages"][0]["versions"] = []
        for number in range(4097):
            version = copy.deepcopy(template)
            version["version"] = f"1.0.{number}"
            version["artifacts"][0]["url"] = f"https://github.com/test/asm/releases/download/v{number}/a.tar.gz"
            value["packages"][0]["versions"].append(version)
        value["packages"][0]["latest"] = "1.0.4096"
        with self.assertRaises(registry.RegistryError):
            self.catalog(value).search("")

    def test_remote_uses_fixed_origin_and_a_fresh_bounded_cache(self):
        data = registry.json_bytes(index(release()))
        opener = Opener(Response(data))
        with patch.object(agent_catalog, "build_opener", return_value=opener):
            catalog = agent_catalog.Catalog()
            first = catalog.search("hello")
            second = catalog.inspect("test/hello", "1.0.0", target="x86_64-linux")
        self.assertEqual(len(opener.requests), 1)
        self.assertEqual(opener.requests[0][0].full_url, "https://asm.build/registry/v1/index.json")
        self.assertGreater(opener.requests[0][1], 0)
        self.assertEqual(first["catalog"], second["catalog"])
        self.assertEqual(first["catalog"]["source"], "https://asm.build/registry/v1/index.json")

    def test_unavailable_remote_is_an_actionable_error_without_local_fallback(self):
        opener = Opener(error=URLError("offline"))
        with patch.object(agent_catalog, "build_opener", return_value=opener):
            with self.assertRaisesRegex(registry.RegistryError, "Retry|retry"):
                agent_catalog.Catalog().search("hello")

    def test_expired_cache_does_not_hide_remote_failure(self):
        opener = Opener(Response(registry.json_bytes(index(release()))))
        with patch.object(agent_catalog, "build_opener", return_value=opener):
            catalog = agent_catalog.Catalog()
            catalog.search("")
            opener.error = URLError("offline")
            expired_time = time.monotonic() + 61
            with patch.object(agent_catalog.time, "monotonic", return_value=expired_time):
                with self.assertRaises(registry.RegistryError):
                    catalog.search("")

    def test_redirects_changed_final_urls_non200_and_oversize_remote_fail(self):
        fixtures = [Opener(error=HTTPError("https://asm.build/registry/v1/index.json", 302, "redirect", {}, None)),
                    Opener(Response(b"{}", url="https://evil.test/catalog")),
                    Opener(Response(b"{}", status=204)),
                    Opener(Response(b"{}", headers={"Content-Length": "4194305"})),
                    Opener(Response(b" " * (4 * 1024 * 1024 + 1))),
                    Opener(Response(b"{}", headers={"Content-Encoding": "gzip"}))]
        for opener in fixtures:
            with self.subTest(opener=opener), patch.object(agent_catalog, "build_opener", return_value=opener):
                with self.assertRaises(registry.RegistryError):
                    agent_catalog.Catalog().search("")

    def test_real_http_redirect_is_refused_before_the_second_request(self):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/redirected")
                self.send_header("Content-Length", "0")
                self.end_headers()
            def log_message(self, *arguments):
                pass
        server = HTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        def local_https(handler, request):
            return handler.do_open(lambda host, **kwargs: http.client.HTTPConnection(
                "127.0.0.1", server.server_port, timeout=kwargs["timeout"]), request)
        try:
            with patch.object(HTTPSHandler, "https_open", local_https):
                with self.assertRaises(registry.RegistryError):
                    agent_catalog.Catalog().search("")
            self.assertEqual(requests, ["/registry/v1/index.json"])
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)

    def test_remote_caller_deadline_does_not_start_unbounded_download_workers(self):
        release_worker = threading.Event()
        started = []
        class SlowOpener:
            def open(self, request, timeout):
                started.append(request.full_url)
                release_worker.wait(2)
                return Response(registry.json_bytes(index(release())))
        try:
            with patch.object(agent_catalog, "build_opener", return_value=SlowOpener()), \
                    patch.object(agent_catalog, "DEADLINE_SECONDS", 0.05):
                catalog = agent_catalog.Catalog()
                begin = time.monotonic()
                with self.assertRaises(registry.RegistryError):
                    catalog.search("")
                self.assertLess(time.monotonic() - begin, 0.5)
                with self.assertRaises(registry.RegistryError):
                    catalog.search("")
                self.assertEqual(len(started), 1)
        finally:
            release_worker.set()


if __name__ == "__main__":
    unittest.main()
