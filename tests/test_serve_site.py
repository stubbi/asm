"""The local discovery service preserves observations and confines HTTP reads.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import importlib
import io
import json
from http.client import HTTPConnection
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry
from test_site import SiteParser


def accessible_text(body):
    page = SiteParser()
    page.feed(body.decode("utf-8"))
    return " ".join("".join(page.accessible_text).split())


class LocalSiteTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / "tools/serve_site.py").exists(), "The local data server is not implemented.")
        self.module = importlib.import_module("serve_site")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.site = self.root / "site"
        self.site.mkdir()
        (self.site / "index.html").write_text((ROOT / "site/index.html").read_text())
        (self.site / "extra.txt").write_text("A staged public file.")
        (self.site / "404.html").write_text('<!doctype html><main><h1>Missing fixture</h1><a href="/">Home</a></main>')
        (self.root / "secret.txt").write_text("Outside the public site.")
        self.record = {"schema": 1, "name": "stubbi/math", "version": "0.1.0",
                       "summary": "A real registry fixture.", "license": "MIT",
                       "source": {"repository": "https://github.com/stubbi/asm", "commit": "a" * 40, "path": "."},
                       "yanked": False, "artifacts": [{"kind": "source", "target": "x86_64-linux",
                       "sha256": "b" * 64, "bytes": 100,
                       "url": "https://github.com/stubbi/asm/releases/download/v0.1.0/math.tar.gz"}]}
        self.records = [self.record]
        _, self.index = registry.make_indexes(self.records)
        self.state = self.root / "discovery.sqlite"
        published = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat().replace("+00:00", "Z")
        self.publication = {"packages": [{"name": self.record["name"], "first_published_at": published,
                                         "last_published_at": published}]}
        self.event_number = 0
        self.service = self.module.DiscoveryService(self.records, self.state, publication=self.publication)
        self.addCleanup(self.service.stop)
        self.start_server(self.index, self.service)

    def record_deliveries(self, count, *, service=None, record=None, event_type="completed", traffic="public"):
        """Feed genuine Store events, without replacing event validation or storage."""
        service = service or self.service
        record = record or self.record
        if service.session_id is None:
            service.refresh()
        for _ in range(count):
            self.event_number += 1
            artifact = record["artifacts"][0]
            event = {"schema": 1, "event_id": f"fixture-delivery-{self.event_number}",
                     "occurred_at": datetime.now(timezone.utc).isoformat(),
                     "name": record["name"], "version": record["version"],
                     "target": artifact["target"], "kind": artifact["kind"], "sha256": artifact["sha256"],
                     "bytes": artifact["bytes"] if event_type == "completed" else artifact["bytes"] // 2 if event_type == "range" else 0,
                     "event_type": event_type, "traffic": traffic}
            self.assertTrue(service.store.record(service.session_id, event))
        return event if count else None

    def start_server(self, index, service, repository=None):
        self.server = self.module.LoopbackHTTPServer(("127.0.0.1", 0),
                         self.module.build_handler(self.site, index, service, repository=repository))
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()
        self.addCleanup(self.thread.join, 2)
        self.addCleanup(self.server.shutdown)
        self.port = self.server.server_port

    def request(self, path="/api/discovery", *, headers=None, method="GET"):
        connection = HTTPConnection("127.0.0.1", self.port, timeout=2)
        try:
            connection.request(method, path, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def assert_native_navigation_script(self, body, route):
        page = SiteParser()
        page.feed(body.decode("utf-8"))
        scripts = [element for element in page.elements if element["tag"] == "script"]
        prefix = "../" * len([part for part in route.split("/") if part])
        self.assertEqual([element["attrs"] for element in scripts],
                         [{"src": prefix + "navigation.js"}, {"src": prefix + "repository-stars.js", "defer": None}])
        self.assertTrue(all(not "".join(element["text"]).strip() for element in scripts))

    def test_json_aliases_use_one_cached_refresh_and_do_not_mutate_public_files(self):
        original = (self.site / "index.html").read_bytes()
        self.record_deliveries(2)
        self.service.refresh()
        with patch.object(self.service.store, "snapshot", side_effect=AssertionError("HTTP reads must use the cache.")):
            for path in ("/api/discovery", "/registry/v1/discovery.json", "/api/discovery?refresh=1"):
                status, headers, body = self.request(path)
                self.assertEqual(status, 200)
                self.assertEqual(headers["Cache-Control"], "no-store")
                self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
                self.assertTrue(headers["Content-Type"].startswith("application/json"))
                self.assertNotIn("Access-Control-Allow-Origin", headers)
                data = json.loads(body)
                self.assertEqual(data["source"], "asm-delivery-events")
                self.assertEqual(data["packages"][0]["downloads_30d"], 2)
                self.assertEqual(data["feeds"]["popular"], ["stubbi/math"])
        self.assertEqual((self.site / "index.html").read_bytes(), original)
        self.assertEqual(self.request("/extra.txt")[2], b"A staged public file.")

    def test_github_headers_stay_plain_while_json_serves_memory_for_all_page_families(self):
        import repository_stars
        observed = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        value = dict(repository_stars.unknown_snapshot(), stars=1250, observed_at=observed, stale=False)
        snapshots = []
        def snapshot():
            snapshots.append(True)
            return deepcopy(value)
        provider = SimpleNamespace(snapshot=snapshot)
        self.service.refresh()
        marker = repository_stars.START + 'Old stars' + repository_stars.END
        for route in ("docs", "reference", "packages/stubbi/math/0.1.0"):
            directory = self.site / route
            directory.mkdir(parents=True)
            (directory / "index.html").write_text('<header>' + marker + '</header><main>Fixture</main>')
        (self.site / "reference/index.html").write_text('<header>' + marker + '</header><main>' + "Large fixture " * 100000 + '</main>')
        (self.site / "404.html").write_text('<header>' + marker + '</header><main>Missing fixture</main>')
        original = (self.site / "index.html").read_bytes()
        self.start_server(self.index, self.service, provider)
        with patch.object(repository_stars, "collect", side_effect=AssertionError("Visitors must not fetch GitHub.")), \
             patch.object(repository_stars, "load_snapshot", side_effect=AssertionError("Visitors must not read the cache.")):
            for route in ("/", "/docs/", "/reference/", "/packages/stubbi/math/0.1.0/", "/explore/", "/stats/", "/missing"):
                with self.subTest(route=route):
                    status, headers, body = self.request(route)
                    self.assertEqual(status, 404 if route == "/missing" else 200)
                    self.assertEqual(int(headers["Content-Length"]), len(body))
                    self.assertIn(b'Star on GitHub', body)
                    self.assertFalse(b'github-stars-count' in body, "HTML must not freeze a numeric star observation.")
                    self.assertNotIn('1,250', accessible_text(body))
                    self.assertEqual(headers["Cache-Control"], "no-store")
                    head_status, head_headers, head_body = self.request(route, method="HEAD")
                    self.assertEqual(head_status, status)
                    self.assertEqual(head_headers["Content-Length"], headers["Content-Length"])
                    self.assertEqual(head_body, b"")
            self.assertEqual(snapshots, [], "HTML does not need a repository observation.")
            status, _, body = self.request("/registry/v1/github.json")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body), value)
            value.update(stale=True, refresh_error=repository_stars.REFRESH_ERROR)
            self.assertEqual(json.loads(self.request("/registry/v1/github.json")[2]), value)
            stale = self.request("/")[2]
            self.assertIn(b'Star on GitHub', stale)
            self.assertNotIn(b'github-stars-count', stale)
            value.update(stars=None, observed_at=None)
            unknown = self.request("/")[2]
            self.assertIn(b'Star on GitHub', unknown)
            self.assertNotIn(b'github-stars-count', unknown)
            def unavailable():
                raise ValueError("Private optional cache failure")
            provider.snapshot = unavailable
            self.assertEqual(self.request("/")[0], 200)
            self.assertIsNone(json.loads(self.request("/registry/v1/github.json")[2])["stars"])
        self.assertEqual((self.site / "index.html").read_bytes(), original)

    def test_downloads_json_uses_cached_own_source_package_and_version_counts(self):
        later = deepcopy(self.record)
        later["version"] = "0.2.0"
        later["artifacts"][0]["url"] = "https://github.com/stubbi/asm/releases/download/v0.2.0/math.tar.gz"
        records = [self.record, later]
        service = self.module.DiscoveryService(records, self.root / "counts.sqlite", publication=self.publication)
        self.addCleanup(service.stop)
        self.record_deliveries(2, service=service)
        self.record_deliveries(3, service=service, record=later)
        service.refresh()
        _, index = registry.make_indexes(records)
        self.start_server(index, service)
        cached = service.counts_snapshot()
        self.assertEqual(cached["source"], "asm-delivery-events")
        self.assertEqual(cached["packages"]["stubbi/math"], {"total": 5, "versions": {"0.1.0": 2, "0.2.0": 3}})
        self.assertFalse(cached["complete"])
        self.assertIsNotNone(cached["observed_at"])
        self.assertIsNotNone(cached["collection_started_at"])
        cached["packages"]["stubbi/math"]["total"] = 999
        self.record_deliveries(1, service=service)
        with patch.object(service.store, "snapshot", side_effect=AssertionError("HTTP reads must not query the ledger.")):
            status, headers, body = self.request("/registry/v1/downloads.json?q=private-search")
            self.assertEqual(status, 200)
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
            self.assertTrue(headers["Content-Type"].startswith("application/json"))
            data = json.loads(body)
            self.assertEqual(data["packages"]["stubbi/math"]["total"], 5)
            self.assertEqual(data["packages"]["stubbi/math"]["versions"]["0.1.0"], 2)
            self.assertEqual(data["packages"]["stubbi/math"]["versions"]["0.2.0"], 3)
            self.assertEqual(data["source"], "asm-delivery-events")

    def test_activity_sidecars_use_cached_exact_identity_and_reconcile_daily_values(self):
        self.record_deliveries(2)
        self.service.refresh()
        with patch.object(self.service.store, "snapshot", side_effect=AssertionError("Activity reads must use the cached projection.")):
            for suffix, version in (("", None), ("/0.1.0", "0.1.0")):
                path = "/registry/v1/activity/stubbi/math" + suffix + ".json"
                status, headers, body = self.request(path)
                self.assertEqual(status, 200)
                self.assertEqual(headers["Cache-Control"], "no-store")
                data = json.loads(body)
                self.assertEqual((data["name"], data["version"], data["total"]), ("stubbi/math", version, 2))
                self.assertEqual(sum(row["count"] or 0 for row in data["days"]), 2)
                self.assertEqual(data["observed_at"], data["window"]["end"])
                self.assertTrue(any(row["count"] is None for row in data["days"]))
                self.assertEqual(self.request(path, method="HEAD")[2], b"")
        self.record_deliveries(1)
        self.assertEqual(json.loads(self.request("/registry/v1/activity/stubbi/math.json")[2])["total"], 2)
        self.service.refresh()
        self.assertEqual(json.loads(self.request("/registry/v1/activity/stubbi/math.json")[2])["total"], 3)
        self.assertEqual(self.request("/registry/v1/activity/stubbi/math/9.0.0.json")[0], 404)
        self.assertEqual(self.request("/registry/v1/activity/unknown/package.json")[0], 404)

    def test_package_activity_is_current_without_scripts_and_keeps_the_staged_file(self):
        self.record_deliveries(2)
        self.service.refresh()
        directory = self.site / "packages/stubbi/math/0.1.0"
        directory.mkdir(parents=True)
        markup = '<main><!-- package-activity:start stubbi/math 0.1.0 -->Stale graph<!-- package-activity:end --></main>'
        page = directory / "index.html"
        page.write_text(markup)
        status, headers, body = self.request("/packages/stubbi/math/0.1.0/")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertIn('≥ 2 downloads', accessible_text(body))
        self.assertIn(b'stubbi/math@0.1.0', body)
        self.assertIn(b'../../../../registry/v1/activity/stubbi/math/0.1.0.json', body)
        self.assertIn(b'Daily counts and coverage', body)
        self.assertNotIn(b'Stale graph', body)
        self.assertNotIn(b'<script', body)
        self.assertEqual(page.read_text(), markup)

    def test_one_html_response_pins_sidebar_and_chart_during_a_background_refresh(self):
        self.record_deliveries(2)
        self.service.refresh()
        directory = self.site / "packages/stubbi/math/0.1.0"
        directory.mkdir(parents=True)
        markup = ('<main><p class="package-note" data-downloads-name="stubbi/math" data-downloads-version="0.1.0">Old total.</p>'
                  '<!-- package-activity:start stubbi/math 0.1.0 -->Old activity<!-- package-activity:end --></main>')
        (directory / "index.html").write_text(markup)
        original = self.module.package_pages.counts_html
        def refresh_between_views(*args):
            result = original(*args)
            self.record_deliveries(1)
            self.service.refresh()
            return result
        with patch.object(self.module.package_pages, "counts_html", side_effect=refresh_between_views):
            status, _, body = self.request("/packages/stubbi/math/0.1.0/")
        self.assertEqual(status, 200)
        self.assertIn('Asm downloads: ≥ 2', accessible_text(body))
        self.assertIn('≥ 2 downloads', accessible_text(body))
        self.assertNotIn('≥ 3 downloads', accessible_text(body))
        self.assertEqual(self.service.activity_snapshot('stubbi/math', '0.1.0')['total'], 3)

    def test_package_html_receives_current_exact_counts_without_scripts_and_head_has_no_body(self):
        self.record_deliveries(2)
        self.service.refresh()
        directory = self.site / "packages/stubbi/math/0.1.0"
        directory.mkdir(parents=True)
        markup = ('<!doctype html><main><h1>Package fixture</h1>'
                  '<p class="package-note" data-downloads-name="stubbi/math" data-downloads-version="0.1.0">'
                  '<span>A stale staged count.</span></p>'
                  '<p class="package-note" data-downloads-name="stubbi/math" data-downloads-version="9.0.0">'
                  'An unknown version must not borrow package totals.</p></main>')
        page = directory / "index.html"
        page.write_text(markup)
        with patch.object(self.service.store, "snapshot", side_effect=AssertionError("HTML reads must use cached counts.")):
            status, headers, body = self.request("/packages/stubbi/math/0.1.0/")
            self.assertEqual(status, 200)
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertEqual(int(headers["Content-Length"]), len(body))
            self.assertIn("Asm downloads: ≥ 2", accessible_text(body))
            self.assertIn(b"Asm download data is unavailable.", body)
            self.assertNotIn(b"A stale staged count.", body)
            self.assertNotIn(b"An unknown version must not borrow", body)
            self.assertNotIn(b"<script", body)
            self.assertEqual(page.read_text(), markup)
            status, head_headers, head_body = self.request("/packages/stubbi/math/0.1.0/", method="HEAD")
            self.assertEqual(status, 200)
            self.assertEqual(head_body, b"")
            self.assertEqual(head_headers["Content-Length"], headers["Content-Length"])

    def test_changed_counts_survive_restart_and_failure_keeps_the_last_observation(self):
        self.record_deliveries(2)
        self.service.refresh()
        self.record_deliveries(5)
        self.service.refresh()
        with patch.object(self.service.store, "heartbeat", side_effect=OSError("private storage detail must not reach the browser")):
            self.service.refresh()
        snapshot = json.loads(self.request()[2])
        self.assertEqual(snapshot["packages"][0]["downloads_30d"], 7)
        self.assertTrue(snapshot["stale"])
        self.assertTrue(snapshot["refresh_error"])
        self.assertNotIn("private storage detail", json.dumps(snapshot))
        self.service.stop()
        restarted = self.module.DiscoveryService(self.records, self.state, publication=self.publication)
        self.addCleanup(restarted.stop)
        restarted.refresh()
        self.assertEqual(restarted.snapshot()["packages"][0]["downloads_30d"], 7)
        self.assertFalse(restarted.snapshot()["coverage"]["complete"], "A restart cannot manufacture a full observation window.")

    def test_no_observation_and_expired_observation_remain_explicit(self):
        unknown = self.service.snapshot()
        self.assertIsNone(unknown["packages"][0]["downloads_30d"])
        self.assertEqual(unknown["feeds"]["popular"], [])
        self.service.refresh()
        current = self.service.snapshot()
        self.assertIsNotNone(current["observed_at"])
        self.assertEqual(current["packages"][0]["downloads_30d"], 0)
        self.assertFalse(current["packages"][0]["downloads_30d_exact"])
        self.assertEqual(current["feeds"]["popular"], [])
        future = datetime.now(timezone.utc) + timedelta(seconds=1801)
        with patch.object(self.module, "datetime", wraps=datetime) as clock:
            clock.now.return_value = future
            self.assertTrue(self.service.snapshot()["stale"])

    def test_popular_counts_completed_public_deliveries_once(self):
        event = self.record_deliveries(1)
        self.assertFalse(self.service.store.record(self.service.session_id, event))
        for traffic in ("bot", "internal"):
            self.record_deliveries(1, traffic=traffic)
        for event_type in ("range", "redirect", "failed"):
            self.record_deliveries(1, event_type=event_type)
        self.service.refresh()
        data = json.loads(self.request()[2])
        self.assertEqual(data["policy"], "asm-deliveries-v1")
        self.assertEqual(data["packages"][0]["downloads_30d"], 1)
        self.assertEqual(data["feeds"]["popular"], ["stubbi/math"])
        self.assertEqual(data["packages"][0]["downloads_30d_coverage"], "lower-bound")

    def test_parallel_reads_remain_fast_during_one_shared_refresh(self):
        self.record_deliveries(2)
        self.service.refresh()
        self.assertEqual(self.service.snapshot()["packages"][0]["downloads_30d"], 2)
        entered, proceed = threading.Event(), threading.Event()
        heartbeat = self.service.store.heartbeat
        calls = []

        def delayed_heartbeat(*args, **kwargs):
            calls.append(1)
            entered.set()
            if not proceed.wait(3):
                raise TimeoutError("The test heartbeat was not released.")
            return heartbeat(*args, **kwargs)

        with patch.object(self.service.store, "heartbeat", side_effect=delayed_heartbeat):
            worker = threading.Thread(target=self.service.refresh, daemon=True)
            worker.start()
            self.addCleanup(worker.join, 2)
            self.addCleanup(proceed.set)
            self.assertTrue(entered.wait(1))
            try:
                with ThreadPoolExecutor(max_workers=8) as pool:
                    responses = list(pool.map(lambda _: self.request(), range(8)))
                    list(pool.map(lambda _: self.service.refresh(), range(8)))
                self.assertTrue(all(response[0] == 200 for response in responses))
                self.assertTrue(all(json.loads(response[2])["packages"][0]["downloads_30d"] == 2 for response in responses))
                self.assertEqual(len(calls), 1, "Only one refresh can hold the Store heartbeat.")
            finally:
                proceed.set()
                worker.join(2)
            self.assertFalse(worker.is_alive())

    def test_background_refresh_runs_without_a_browser_request(self):
        service = self.module.DiscoveryService(self.records, self.root / "background.sqlite", refresh_seconds=0.05,
                                               publication=self.publication)
        self.addCleanup(service.stop)
        service.start()
        self.assertEqual(service.snapshot()["packages"][0]["downloads_30d"], 0)
        self.record_deliveries(9, service=service)
        deadline = time.monotonic() + 2
        while service.snapshot()["packages"][0]["downloads_30d"] != 9 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(service.snapshot()["packages"][0]["downloads_30d"], 9)

    def test_different_registry_records_cannot_reuse_bound_counts(self):
        self.record_deliveries(2)
        self.service.refresh()
        self.assertEqual(self.service.snapshot()["packages"][0]["downloads_30d"], 2)
        changed = deepcopy(self.record)
        changed["artifacts"][0]["sha256"] = "c" * 64
        other = self.module.DiscoveryService([changed], self.state, publication=self.publication)
        self.addCleanup(other.stop)
        other.refresh()
        self.assertIsNone(other.snapshot()["packages"][0]["downloads_30d"])

    def test_mismatched_built_index_is_rejected_before_serving_release_claims(self):
        changed = deepcopy(self.index)
        changed["packages"][0]["versions"][0]["source"]["commit"] = "c" * 40
        with self.assertRaises(registry.RegistryError):
            self.module.build_handler(self.site, changed, self.service)

    def test_external_control_addresses_and_non_loopback_binding_are_rejected(self):
        for headers in ({"Host": "evil.invalid"}, {"Origin": "https://evil.invalid"},
                        {"Host": "localhost:1"}, {"Origin": "null"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.request(headers=headers)[0], 403)
        self.assertEqual(self.request(headers={"Host": f"localhost:{self.port}",
                         "Origin": f"http://localhost:{self.port}"})[0], 200)
        with self.assertRaises(ValueError):
            self.module.LoopbackHTTPServer(("0.0.0.0", 0), self.module.build_handler(self.site, self.index, self.service))

    def test_traversal_symlinks_and_directory_listing_do_not_expose_private_files(self):
        (self.site / "escape.txt").symlink_to(self.root / "secret.txt")
        (self.site / "empty").mkdir()
        (self.site / "index-escape").mkdir()
        (self.site / "index-escape/index.html").symlink_to(self.root / "secret.txt")
        for path in ("/%2e%2e/secret.txt", "/..%2fsecret.txt", "/%5c..%5csecret.txt", "/escape.txt", "/empty/", "/index-escape/"):
            with self.subTest(path=path):
                status, _, body = self.request(path)
                self.assertIn(status, (400, 403, 404))
                self.assertNotIn(b"Outside the public site.", body)
                self.assertNotIn(b"Directory listing", body)
        status, _, body = self.request("/nested/missing/")
        self.assertEqual(status, 404)
        self.assertIn(b"Missing fixture", body)

    def test_requests_do_not_log_raw_queries_and_head_does_not_send_json(self):
        output = io.StringIO()
        with redirect_stderr(output):
            status, headers, body = self.request("/api/discovery?q=private-search", method="HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertGreater(int(headers["Content-Length"]), 0)
        self.assertNotIn("private-search", output.getvalue())

    def test_browse_pages_use_the_current_observation(self):
        self.record_deliveries(2)
        self.service.refresh()
        for kind in ("popular", "new"):
            status, headers, body = self.request("/browse/" + kind + "/")
            self.assertEqual(status, 200)
            self.assertTrue(headers["Content-Type"].startswith("text/html"))
            self.assertIn(b"stubbi/math", body)
            self.assertIn(b"packages/stubbi/math/", body)
        self.assertEqual(self.service.snapshot()["packages"][0]["downloads_30d"], 2)

    def test_updated_feed_links_a_real_later_release(self):
        later = deepcopy(self.record)
        later["version"] = "0.2.0"
        later["artifacts"][0]["url"] = "https://github.com/stubbi/asm/releases/download/v0.2.0/math.tar.gz"
        publication = deepcopy(self.publication)
        publication["packages"][0]["last_published_at"] = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat().replace("+00:00", "Z")
        records = [self.record, later]
        service = self.module.DiscoveryService(records, self.root / "updated.sqlite", publication=publication)
        self.addCleanup(service.stop)
        service.refresh()
        _, index = registry.make_indexes(records)
        self.start_server(index, service)
        status, _, body = self.request("/browse/updated/")
        self.assertEqual(status, 200)
        self.assertIn(b"stubbi/math", body)
        self.assertIn(b"0.2.0", body)

    def test_metric_page_shows_the_live_window_instead_of_the_built_observation(self):
        (self.site / "discovery").mkdir()
        (self.site / "discovery/index.html").write_text("An older built observation.")
        self.service.refresh()
        status, _, body = self.request("/discovery/")
        self.assertEqual(status, 200)
        cutoff = self.service.snapshot()["window"]["end"]
        self.assertIsInstance(cutoff, str)
        self.assertIn(cutoff.encode(), body)
        self.assertNotIn(b"An older built observation.", body)

    def test_curated_categories_enrich_json_and_unknown_categories_recover(self):
        destination = self.site / "registry/v1/categories.json"
        destination.parent.mkdir(parents=True)
        destination.write_text(json.dumps({"schema": 1, "categories": [
            {"id": "libraries", "name": "Libraries", "packages": ["stubbi/math"]}]}))
        self.service.refresh()
        data = json.loads(self.request()[2])
        self.assertEqual(data["categories"][0]["id"], "libraries")
        status, _, body = self.request("/browse/categories/libraries/")
        self.assertEqual(status, 200)
        self.assertIn(b"stubbi/math", body)
        for category in ("unknown", "bad--id", "bad_id"):
            self.assertEqual(self.request("/browse/categories/" + category + "/")[0], 404)
        destination.write_text('{"schema": 1, "categories": "broken"}')
        status, _, body = self.request()
        self.assertEqual(status, 503)
        self.assertNotIn(b"broken", body)

    def test_explore_and_statistics_use_cached_own_events_without_mutating_staged_pages(self):
        destination = self.site / "registry/v1/discovery-metadata.json"
        destination.parent.mkdir(parents=True)
        destination.write_text(json.dumps({"schema": 1, "packages": [
            {"name": "stubbi/math", "keywords": ["math"]}]}))
        original = (self.site / "index.html").read_bytes()
        self.record_deliveries(2)
        self.record_deliveries(1, traffic="bot")
        self.record_deliveries(1, traffic="internal")
        self.service.refresh()
        with patch.object(self.service.store, "snapshot", side_effect=AssertionError("HTTP reads must use the cache.")):
            status, headers, body = self.request("/registry/v1/stats.json")
            self.assertEqual(status, 200)
            self.assertEqual(headers["Cache-Control"], "no-store")
            data = json.loads(body)
            self.assertEqual(data["transfers"]["total"], 2)
            self.assertEqual(data["activity"]["total"], 2)
            self.assertEqual(data["activity"]["scope"], "registry")
            self.assertEqual(data["transfers"]["observed_at"], data["activity"]["observed_at"])
            self.assertNotIn(b"fixture-delivery", body)
            for route in ("/explore/", "/stats/", "/browse/keywords/", "/browse/keywords/math/",
                          "/browse/architectures/", "/browse/architectures/x86_64/",
                          "/browse/categories/", "/browse/downloaded/", "/browse/depended-on/"):
                with self.subTest(route=route):
                    status, headers, body = self.request(route)
                    self.assertEqual(status, 200)
                    self.assertEqual(headers["Cache-Control"], "no-store")
                    self.assert_native_navigation_script(body, route)
                    if route in {"/explore/", "/browse/downloaded/", "/browse/keywords/math/"}:
                        self.assertIn(b"stubbi/math", body)
            status, headers, body = self.request("/stats/", method="HEAD")
            self.assertEqual(status, 200)
            self.assertEqual(body, b"")
            self.assertGreater(int(headers["Content-Length"]), 0)
        self.assertEqual((self.site / "index.html").read_bytes(), original)

    def test_architecture_routes_use_latest_artifacts_and_unknown_groups_recover(self):
        self.service.refresh()
        with patch.object(self.service.store, "snapshot", side_effect=AssertionError("Architecture reads must not read the ledger.")), \
             patch.object(self.service, "hub_snapshot", side_effect=AssertionError("Architecture reads must not read activity.")), \
             patch.object(self.module.discovery_metadata, "read_metadata", side_effect=AssertionError("Architecture reads must not read relationships.")):
            for route in ("/browse/architectures/", "/browse/architectures/x86_64/"):
                status, headers, body = self.request(route)
                self.assertEqual(status, 200)
                self.assert_native_navigation_script(body, route)
                self.assertIn(b"x86-64", body)
                if route.endswith("x86_64/"):
                    self.assertIn(b'architecture=x86_64', body)
                self.assertEqual(headers["Cache-Control"], "no-store")
                status, head_headers, head_body = self.request(route, method="HEAD")
                self.assertEqual(status, 200)
                self.assertEqual(head_body, b"")
                self.assertEqual(head_headers["Content-Length"], headers["Content-Length"])
            for value in ("aarch64", "unknown", "bad--id", "x86_64-linux", "x86_64/extra", "x86_64.html"):
                self.assertEqual(self.request("/browse/architectures/" + value + "/")[0], 404)

    def test_bad_relationship_metadata_does_not_disable_statistics_or_invent_keywords(self):
        self.service.refresh()
        self.assertEqual(self.request("/browse/keywords/unknown/")[0], 404)
        self.assertEqual(self.request("/browse/keywords/bad--id/")[0], 404)
        destination = self.site / "registry/v1/discovery-metadata.json"
        destination.parent.mkdir(parents=True)
        destination.write_text('{"schema":1,"packages":"broken"}')
        status, _, body = self.request("/explore/")
        self.assertEqual(status, 503)
        self.assertNotIn(b"broken", body)
        self.assertEqual(self.request("/stats/")[0], 200)
        self.assertEqual(self.request("/registry/v1/stats.json")[0], 200)

    def test_one_statistics_response_retains_one_cutoff_during_a_background_refresh(self):
        self.record_deliveries(2)
        self.service.refresh()
        snapshot = self.service.hub_snapshot
        def advance_after_snapshot():
            result = snapshot()
            self.record_deliveries(1)
            self.service.refresh()
            return result
        with patch.object(self.service, "hub_snapshot", side_effect=advance_after_snapshot):
            status, _, body = self.request("/registry/v1/stats.json")
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertEqual(data["transfers"]["total"], 2)
        self.assertEqual(data["activity"]["total"], 2)
        self.assertEqual(data["activity"]["observed_at"], data["transfers"]["observed_at"])
        self.assertEqual(self.service.snapshot()["packages"][0]["downloads_30d"], 3)


if __name__ == "__main__":
    unittest.main()
