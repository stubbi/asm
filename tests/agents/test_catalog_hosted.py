"""Fixed catalog sources exercised through a local HTTP backend."""

from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.request import HTTPHandler, HTTPSHandler


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import agent_catalog
import registry


EMPTY = b'{"schema":1,"packages":[]}'
SOURCES = (
    ("alpha", "https://asm.build/registry/v1/index.json", "asm.build"),
    ("hosted", "https://api.asm.build/registry/v1/index.json", "api.asm.build"),
    ("internal", "http://asm-hub.asm.svc.cluster.local:8080/registry/v1/index.json",
     "asm-hub.asm.svc.cluster.local:8080"),
)


@contextmanager
def backend(*, status=200, body=EMPTY, redirect=None):
    """Keep urllib and HTTP real; connect the fixed hosts to a loopback server."""
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append((self.headers.get("Host"), self.path))
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            if redirect is not None:
                self.send_header("Location", redirect)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *arguments):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
    worker.start()

    def connect(handler, request):
        return handler.do_open(lambda host, **kwargs: http.client.HTTPConnection(
            "127.0.0.1", server.server_port, timeout=kwargs["timeout"]), request)

    try:
        with patch.object(HTTPHandler, "http_open", connect), \
                patch.object(HTTPSHandler, "https_open", connect):
            yield requests
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)


class HostedCatalogTests(unittest.TestCase):
    def test_each_source_fetches_only_its_fixed_url_and_reports_its_bytes(self):
        for source, url, host in SOURCES:
            with self.subTest(source=source), backend() as requests:
                catalog = agent_catalog.Catalog(source=source)
                result = catalog.search("")
                self.assertEqual(result["packages"], [])
                self.assertEqual(result["catalog"]["source"], url)
                self.assertEqual(result["catalog"]["sha256"], hashlib.sha256(EMPTY).hexdigest())
                self.assertEqual(requests, [(host, "/registry/v1/index.json")])

    def test_source_is_operator_configuration_and_rejects_arbitrary_urls(self):
        for source in ("https://evil.test/catalog", "http://127.0.0.1/catalog", "HOSTED", "", None, True, [], {}):
            with self.subTest(source=source), self.assertRaises(registry.RegistryError):
                agent_catalog.Catalog(source=source)
        catalog = agent_catalog.Catalog()
        with self.assertRaises(TypeError):
            catalog.search("", source="hosted")
        with self.assertRaises(TypeError):
            catalog.inspect("test/hello", "1.0.0", source="hosted")

    def test_local_catalog_and_nonalpha_source_are_mutually_exclusive(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "index.json"
            path.write_bytes(EMPTY)
            for source in ("hosted", "internal"):
                with self.subTest(source=source), self.assertRaises(registry.RegistryError):
                    agent_catalog.Catalog(path, source=source)
            with backend() as requests:
                result = agent_catalog.Catalog(path, source="alpha").search("")
                self.assertEqual(result["catalog"]["source"], str(path.resolve()))
                self.assertEqual(requests, [])

    def test_default_download_hook_still_accepts_only_deadline(self):
        def download(deadline):
            self.assertGreater(deadline, time.monotonic())
            return EMPTY

        with patch.object(agent_catalog, "_download", download):
            ready = agent_catalog.Catalog().check_ready()
        self.assertEqual(ready["source"], "https://asm.build/registry/v1/index.json")
        self.assertEqual(ready["sha256"], hashlib.sha256(EMPTY).hexdigest())

    def test_unavailable_selected_source_does_not_try_another_source(self):
        for source, unused_url, host in SOURCES:
            with self.subTest(source=source), backend(status=503) as requests:
                with self.assertRaisesRegex(registry.RegistryError, "Retry|retry"):
                    agent_catalog.Catalog(source=source).search("")
                self.assertEqual(requests, [(host, "/registry/v1/index.json")])

    def test_invalid_selected_catalog_is_not_an_empty_result_or_fallback(self):
        for source, unused_url, host in SOURCES:
            with self.subTest(source=source), backend(body=b'{"schema":2,"packages":[]}') as requests:
                with self.assertRaisesRegex(registry.RegistryError, "Unsupported catalog schema"):
                    agent_catalog.Catalog(source=source).check_ready()
                self.assertEqual(requests, [(host, "/registry/v1/index.json")])

    def test_every_source_refuses_redirects_before_a_second_http_request(self):
        for source, unused_url, host in SOURCES:
            for status in (301, 302, 303, 307, 308):
                with self.subTest(source=source, status=status), \
                        backend(status=status, body=b"", redirect="http://evil.test/redirected") as requests:
                    with self.assertRaisesRegex(registry.RegistryError, "redirects are refused"):
                        agent_catalog.Catalog(source=source).check_ready()
                    self.assertEqual(requests, [(host, "/registry/v1/index.json")])

    def test_ambient_proxy_settings_cannot_reroute_any_source(self):
        proxies = {key: "http://127.0.0.1:1" for key in
                   ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")}
        proxies.update(NO_PROXY="", no_proxy="")
        with patch.dict("os.environ", proxies):
            for source, url, host in SOURCES:
                with self.subTest(source=source), backend() as requests:
                    result = agent_catalog.Catalog(source=source).check_ready()
                    self.assertEqual(result["source"], url)
                    self.assertEqual(requests, [(host, "/registry/v1/index.json")])

    def test_readiness_preserves_original_cached_observation_and_returns_a_copy(self):
        first_time = datetime(2026, 11, 5, 1, 2, 3, tzinfo=timezone.utc)
        later_time = datetime(2026, 11, 5, 1, 2, 30, tzinfo=timezone.utc)
        with backend() as requests, patch.object(agent_catalog, "datetime") as clock:
            clock.now.return_value = first_time
            catalog = agent_catalog.Catalog(source="hosted")
            first = catalog.check_ready()
            clock.now.return_value = later_time
            second = catalog.search("")["catalog"]
            third = catalog.check_ready()
            self.assertEqual(set(first), {"source", "sha256", "observed_at"})
            self.assertEqual(first["observed_at"], "2026-11-05T01:02:03Z")
            self.assertEqual(first, second)
            self.assertEqual(first, third)
            first["source"] = "https://evil.test/catalog"
            third["observed_at"] = "changed"
            self.assertEqual(catalog.check_ready(), second)
            self.assertEqual(requests, [("api.asm.build", "/registry/v1/index.json")])

    def test_ready_after_cache_expiry_does_not_hide_selected_source_failure(self):
        catalog = agent_catalog.Catalog(source="hosted")
        with backend():
            catalog.check_ready()
        with backend(status=503) as requests, \
                patch.object(agent_catalog.time, "monotonic", return_value=time.monotonic() + 61):
            with self.assertRaises(registry.RegistryError):
                catalog.check_ready()
            self.assertEqual(requests, [("api.asm.build", "/registry/v1/index.json")])


if __name__ == "__main__":
    unittest.main()
