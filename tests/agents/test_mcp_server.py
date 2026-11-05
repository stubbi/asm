"""Exercise the real MCP boundary through the official client."""

import asyncio
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

from mcp import Client
from mcp.client.stdio import StdioServerParameters
import httpx2

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import registry
import mcp_server
from test_catalog import release
from test_workflow import benchmark, candidate, requirements

TOOLS = {"asm_list_targets", "asm_search_packages", "asm_inspect_package", "asm_plan_project",
         "asm_compare_candidates", "asm_get_workflow"}


class MCPTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.catalog = Path(self.temporary.name) / "index.json"
        self.catalog.write_bytes(registry.json_bytes(registry.make_indexes(registry.read_records(ROOT / "registry"))[1]))

    async def exercise(self, client):
        listed = await client.list_tools()
        self.assertEqual({tool.name for tool in listed.tools}, TOOLS)
        for tool in listed.tools:
            self.assertTrue(tool.annotations.read_only_hint)
            self.assertTrue(tool.annotations.idempotent_hint)
            self.assertIsNotNone(tool.output_schema)
            self.assertFalse(tool.input_schema.get("additionalProperties", True))
        result = await client.call_tool("asm_list_targets", {})
        self.assertFalse(result.is_error)
        self.assertEqual({item["id"] for item in result.structured_content["targets"]}, set(registry.TARGETS))
        self.assertEqual({item["id"] for item in result.structured_content["targets"] if item["native_cli"]},
                         {"x86_64-linux", "aarch64-linux", "aarch64-macos"})
        result = await client.call_tool("asm_search_packages", {"query": "math", "target": "x86_64-linux"})
        self.assertFalse(result.is_error, result)
        self.assertEqual(result.structured_content["packages"][0]["name"], "stubbi/math")
        result = await client.call_tool("asm_inspect_package", {"name": "stubbi/math", "version": "0.4.0", "target": "x86_64-linux"})
        self.assertFalse(result.is_error)
        self.assertTrue(result.structured_content["selection"]["selectable"])
        result = await client.call_tool("asm_plan_project", {"requirements": {}})
        self.assertFalse(result.structured_content["ready"])
        spec = requirements()
        context = benchmark(spec)
        result = await client.call_tool("asm_compare_candidates", {
            "requirements": spec.model_dump(), "context": context.model_dump(),
            "candidates": [candidate(context, "baseline", 100).model_dump(), candidate(context, "candidate", 80).model_dump()],
        })
        self.assertFalse(result.is_error, result)
        self.assertEqual(result.structured_content["selected"], "candidate")
        result = await client.call_tool("asm_get_workflow", {"section": "workflow"})
        self.assertIn("sha256", result.structured_content)
        self.assertIn("assembly", result.structured_content["text"])
        resources = await client.list_resources()
        self.assertIn("asm://targets", {str(item.uri) for item in resources.resources})
        resource = await client.read_resource("asm://targets")
        self.assertEqual({item["id"] for item in json.loads(resource.contents[0].text)["targets"]},
                         set(registry.TARGETS))
        identity = json.loads((await client.read_resource("asm://service")).contents[0].text)
        self.assertEqual(identity["service"], "asm-mcp")
        self.assertEqual(identity["source_revision"], "unrecorded")
        self.assertEqual(identity["source_url"], "https://github.com/stubbi/asm")
        prompt = await client.get_prompt("asm_build", {"task": "Create an unsigned minimum routine."})
        self.assertIn("minimum", prompt.messages[0].content.text)

    async def test_in_process_client_uses_complete_surface(self):
        async with Client(mcp_server.create_server(self.catalog)) as client:
            await self.exercise(client)
            for name, arguments in [
                ("asm_search_packages", {"query": "x", "target": "x86_64-freebsd"}),
                ("asm_search_packages", {"query": "x", "target": []}),
                ("asm_inspect_package", {"name": "stubbi/math", "version": "0.4.0", "target": "x86_64-freebsd"}),
                ("asm_inspect_package", {"name": "stubbi/math", "version": "0.4.0", "target": []}),
                ("asm_search_packages", {"query": "x", "registry": "http://localhost/secret"}),
                ("asm_search_packages", {"query": "x", "limit": True}),
                ("asm_get_workflow", {"section": "../../.env"}),
                ("run_command", {"command": "touch unwanted"}),
            ]:
                result = await client.call_tool(name, arguments)
                self.assertTrue(result.is_error, result)

    async def test_windows_search_and_inspection_keep_exact_metadata_without_execution(self):
        # Local metadata fixtures do not represent published packages or runtime evidence.
        targets = ("x86_64-windows", "aarch64-windows")
        record = release(target=targets[0])
        record["artifacts"].append(release(target=targets[1])["artifacts"][0])
        newer = release(version="2.0.0", target=targets[0], license="Apache-2.0")
        original = registry.json_bytes(registry.make_indexes([record, newer])[1])
        self.catalog.write_bytes(original)
        async with Client(mcp_server.create_server(self.catalog)) as client:
            for target in targets:
                with self.subTest(target=target):
                    found = await client.call_tool("asm_search_packages", {
                        "query": "hello", "target": target, "license": "MIT"})
                    self.assertFalse(found.is_error, found)
                    selected = found.structured_content["packages"][0]
                    artifact = next(item for item in record["artifacts"] if item["target"] == target)
                    self.assertEqual(selected["version"], "1.0.0")
                    self.assertEqual(selected["license"], "MIT")
                    self.assertEqual(selected["artifacts"], [artifact])
                    exact = await client.call_tool("asm_inspect_package", {
                        "name": "test/hello", "version": "1.0.0", "target": target})
                    self.assertFalse(exact.is_error, exact)
                    self.assertTrue(exact.structured_content["selection"]["selectable"])
                    self.assertEqual(exact.structured_content["selection"]["artifacts"], [artifact])
                    self.assertEqual(exact.structured_content["package"]["evidence"]["formal"], "not-run")
        self.assertEqual(self.catalog.read_bytes(), original)
        self.assertEqual(list(self.catalog.parent.iterdir()), [self.catalog])

    async def test_real_stdio_client_modern_and_legacy(self):
        for mode in ("auto", "legacy"):
            with self.subTest(mode=mode):
                params = StdioServerParameters(command=sys.executable,
                    args=[str(ROOT / "tools/mcp_server.py"), "--catalog", str(self.catalog)], cwd=ROOT)
                async with Client(params, mode=mode, read_timeout_seconds=10) as client:
                    self.assertEqual(client.protocol_version, "2026-07-28" if mode == "auto" else "2025-11-25")
                    await self.exercise(client)

    async def test_http_client_and_origin_body_limits(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        process = subprocess.Popen([sys.executable, str(ROOT / "tools/mcp_server.py"),
            "--transport", "streamable-http", "--port", str(port), "--catalog", str(self.catalog)],
            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    connection = socket.create_connection(("127.0.0.1", port), timeout=0.1)
                    connection.close()
                    break
                except OSError:
                    if process.poll() is not None or time.monotonic() >= deadline:
                        self.fail("HTTP server failed to listen: " + process.communicate(timeout=2)[1].decode())
                    await asyncio.sleep(0.02)
            url = f"http://127.0.0.1:{port}/mcp"
            for mode in ("auto", "legacy"):
                async with Client(url, mode=mode, read_timeout_seconds=10) as client:
                    self.assertEqual(client.protocol_version, "2026-07-28" if mode == "auto" else "2025-11-25")
                    await self.exercise(client)
            async with httpx2.AsyncClient(trust_env=False) as http:
                response = await http.post(url, headers={"MCP-Protocol-Version": "1900-01-01",
                    "Content-Type": "application/json", "Accept": "application/json, text/event-stream"},
                    content=b'{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
                self.assertEqual(response.status_code, 400)
                response = await http.post(url, headers={"Origin": "https://hostile.example", "Content-Type": "application/json"}, content=b"{}")
                self.assertEqual(response.status_code, 403)
                response = await http.post(url, headers={"Host": "hostile.example", "Content-Type": "application/json"}, content=b"{}")
                self.assertEqual(response.status_code, 421)
                response = await http.post(url, content=b" " * (mcp_server.MAX_REQUEST_BYTES + 1))
                self.assertEqual(response.status_code, 413)
                async def chunks():
                    for _ in range(17):
                        yield b" " * 65536
                response = await http.post(url, content=chunks())
                self.assertEqual(response.status_code, 413)
        finally:
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(stdout, b"", stderr.decode())


if __name__ == "__main__":
    unittest.main()
