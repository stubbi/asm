"""Exercise the hosted MCP configuration and HTTP boundary."""

import asyncio
from contextlib import asynccontextmanager
import json
import os
from pathlib import Path
import socket
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import httpx2
from mcp import Client

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import mcp_server
import registry

REVISION = "1234567890abcdef1234567890abcdef12345678"
PUBLIC_ORIGIN = "https://api.asm.build"


class HostedConfigurationTests(unittest.TestCase):
    def reject(self, arguments, message):
        result = subprocess.run([sys.executable, str(ROOT / "tools/mcp_server.py"), *arguments],
            cwd=ROOT, capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(message, result.stderr.decode())

    def test_nonloopback_requires_origin_and_explicit_catalog_source(self):
        self.reject(["--transport", "streamable-http", "--host", "0.0.0.0", "--catalog-source", "internal"],
                    "requires --public-origin")
        self.reject(["--transport", "streamable-http", "--host", "0.0.0.0", "--public-origin", PUBLIC_ORIGIN],
                    "requires --catalog-source")

    def test_public_origin_rejects_ambiguous_and_unapproved_origins(self):
        for origin in ("http://asm.build", "https://asm.build/", "https://asm.build/mcp",
                       "https://asm.build?x=1", "https://asm.build#x", "https://asm.build:443",
                       "https://user@asm.build", "https://*.asm.build", "https://asm.build.evil.example",
                       "https://ASM.BUILD", "https://api.asm.build\n"):
            with self.subTest(origin=origin):
                self.reject(["--transport", "streamable-http", "--public-origin", origin],
                            "public-origin must be exactly")

    def test_public_service_refuses_local_catalog_and_unsupported_bind(self):
        self.reject(["--transport", "streamable-http", "--host", "0.0.0.0", "--public-origin", PUBLIC_ORIGIN,
                     "--catalog-source", "internal", "--catalog", "/private/catalog.json"],
                    "local catalog cannot be exposed")
        self.reject(["--transport", "streamable-http", "--host", "192.0.2.1", "--public-origin", PUBLIC_ORIGIN],
                    "host must be")

    def test_revision_rejects_missing_identity_disguised_as_a_commit(self):
        for revision in ("0" * 40, "a" * 39, "A" * 40, "a" * 40 + "/file", ""):
            with self.subTest(revision=revision):
                self.reject(["--source-revision", revision], "source revision must be")


class HostedHTTPTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.catalog = Path(self.temporary.name) / "private-catalog.json"
        self.catalog_bytes = registry.json_bytes(registry.make_indexes(registry.read_records(ROOT / "registry"))[1])
        self.catalog.write_bytes(self.catalog_bytes)

    @asynccontextmanager
    async def running_server(self, arguments=(), *, revision=REVISION, script=None):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        environment = dict(os.environ)
        environment.pop("ASM_SOURCE_REVISION", None)
        if revision is not None:
            environment["ASM_SOURCE_REVISION"] = revision
        command = [sys.executable, "-c", script] if script is not None else [sys.executable, str(ROOT / "tools/mcp_server.py")]
        process = subprocess.Popen([*command,
            "--transport", "streamable-http", "--port", str(port), *arguments],
            cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        listening = False
        try:
            deadline = time.monotonic() + 10
            while True:
                if process.poll() is not None:
                    self.fail("HTTP server exited before listening: " + process.communicate(timeout=2)[1].decode())
                try:
                    connection = socket.create_connection(("127.0.0.1", port), timeout=0.1)
                    connection.close()
                    listening = True
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        self.fail("HTTP server did not listen within ten seconds")
                    await asyncio.sleep(0.02)
            yield f"http://127.0.0.1:{port}"
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                stdout, stderr = await asyncio.to_thread(process.communicate, timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                await asyncio.to_thread(process.communicate, timeout=5)
                raise
            self.assertEqual(stdout, b"", stderr.decode())
            if listening:
                self.assertIn(process.returncode, (0, -signal.SIGTERM), stderr.decode())

    async def test_public_headers_health_and_exact_source_identity(self):
        arguments = ["--public-origin", PUBLIC_ORIGIN, "--catalog", str(self.catalog)]
        async with self.running_server(arguments) as url:
            async with httpx2.AsyncClient(trust_env=False) as http:
                headers = {"Host": "api.asm.build", "Origin": PUBLIC_ORIGIN}
                for path in ("/health/live", "/health/ready", "/api/v2/status"):
                    response = await http.get(url + path, headers=headers)
                    self.assertEqual(response.status_code, 200, response.text)
                    self.assertEqual(response.headers["Cache-Control"], "no-store")
                    self.assertNotIn(str(self.catalog), response.text)
                status = (await http.get(url + "/api/v2/status", headers=headers)).json()
                self.assertEqual(status["source_revision"], REVISION)
                self.assertEqual(status["source_url"], "https://github.com/stubbi/asm/tree/" + REVISION)
                async with Client(url + "/mcp") as client:
                    identity = json.loads((await client.read_resource("asm://service")).contents[0].text)
                    self.assertEqual(identity, status)
                for path in ("/mcp", "/health/live", "/health/ready", "/api/v2/status"):
                    response = await http.get(url + path, headers={"Host": "hostile.example",
                        "X-Forwarded-Host": "api.asm.build", "X-Forwarded-Proto": "https"})
                    self.assertEqual(response.status_code, 421)
                    response = await http.get(url + path, headers={"Host": "api.asm.build",
                        "Origin": "https://hostile.example", "X-Forwarded-Origin": PUBLIC_ORIGIN})
                    self.assertEqual(response.status_code, 403)
                response = await http.get(url + "/health/live", headers={**headers,
                    "X-Forwarded-For": "192.0.2.25", "X-Forwarded-Host": "hostile.example",
                    "X-Forwarded-Proto": "http", "Forwarded": 'host=hostile.example;proto=http'})
                self.assertEqual(response.status_code, 200)
                for host in ("localhost", "asm-mcp.asm.svc.cluster.local:8080"):
                    response = await http.get(url + "/health/live", headers={"Host": host})
                    self.assertEqual(response.status_code, 200)
                response = await http.post(url + "/mcp", headers={**headers, "Content-Type": "application/json"},
                                           content=b" " * (1024 * 1024 + 1))
                self.assertEqual(response.status_code, 413)

    async def test_health_distinguishes_catalog_failure_and_recovery(self):
        async with self.running_server(["--catalog", str(self.catalog)]) as url:
            async with httpx2.AsyncClient(trust_env=False) as http:
                self.assertEqual((await http.get(url + "/health/ready")).status_code, 200)
                self.catalog.write_bytes(b"{not-json")
                response = await http.get(url + "/health/ready")
                self.assertEqual(response.status_code, 503)
                self.assertEqual(response.json()["error"]["code"], "catalog_unavailable")
                self.assertNotIn(str(self.catalog), response.text)
                self.assertEqual((await http.get(url + "/health/live")).status_code, 200)
                self.catalog.write_bytes(self.catalog_bytes)
                self.assertEqual((await http.get(url + "/health/ready")).status_code, 200)

    async def test_nonloopback_service_keeps_real_sdk_clients_and_sigterm(self):
        arguments = ["--host", "0.0.0.0", "--public-origin", PUBLIC_ORIGIN, "--catalog-source", "internal",
                     "--source-revision", REVISION]
        async with self.running_server(arguments, revision=None) as url:
            for mode in ("auto", "legacy"):
                async with Client(url + "/mcp", mode=mode, read_timeout_seconds=5) as client:
                    tools = await client.list_tools()
                    self.assertEqual(len(tools.tools), 6)
                    result = await client.call_tool("asm_list_targets", {})
                    self.assertFalse(result.is_error)
                    self.assertEqual(len(result.structured_content["targets"]), 4)

    async def test_unrecorded_revision_is_visible(self):
        async with self.running_server(["--catalog", str(self.catalog)], revision=None) as url:
            async with httpx2.AsyncClient(trust_env=False) as http:
                response = await http.get(url + "/api/v2/status")
                self.assertEqual(response.status_code, 200)
                status = response.json()
                self.assertEqual(status["source_revision"], "unrecorded")
                self.assertEqual(status["source_url"], "https://github.com/stubbi/asm")

    async def test_sigterm_does_not_wait_for_a_stalled_readiness_worker(self):
        script = ("import sys,time; sys.path.insert(0,'tools'); import mcp_server; "
                  "mcp_server.Catalog.check_ready=lambda self:time.sleep(30); "
                  "raise SystemExit(mcp_server.main())")
        async with self.running_server(["--catalog", str(self.catalog)], script=script) as url:
            async with httpx2.AsyncClient(trust_env=False, timeout=5) as http:
                response = await http.get(url + "/health/ready")
                self.assertEqual(response.status_code, 503)

    async def test_readiness_deadline_keeps_liveness_available_and_bounds_workers(self):
        release = threading.Event()
        entered = threading.Event()
        calls = []

        def stalled_catalog():
            calls.append(1)
            entered.set()
            release.wait(timeout=3)
            return {"source": "/private/catalog", "sha256": "a" * 64, "observed_at": "2026-11-05T00:00:00Z"}

        server = mcp_server.create_server(self.catalog)
        # Block the actual catalog I/O boundary, while keeping route handling real.
        with patch("mcp_server.Catalog.check_ready", side_effect=stalled_catalog), \
             patch.object(mcp_server, "HEALTH_TIMEOUT_SECONDS", 0.05, create=True):
            app = mcp_server.create_http_app(server)
            async with httpx2.AsyncClient(transport=httpx2.ASGITransport(app=app),
                                         base_url="http://localhost", trust_env=False) as http:
                try:
                    started = time.monotonic()
                    for _ in range(3):
                        response = await http.get("/health/ready")
                        self.assertEqual(response.status_code, 503)
                    self.assertLess(time.monotonic() - started, 1)
                    self.assertTrue(entered.is_set())
                    self.assertEqual(len(calls), 1)
                    self.assertEqual((await http.get("/health/live")).status_code, 200)
                finally:
                    release.set()


if __name__ == "__main__":
    unittest.main()
