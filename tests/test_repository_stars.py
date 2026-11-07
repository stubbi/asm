"""Fixed-repository star fixtures do not establish live adoption.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from datetime import datetime, timedelta, timezone
import importlib
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry


class RepositoryStarsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name).resolve() / "private" / "github.json"
        self.now = "2026-01-01T12:00:00Z"

    def module(self):
        self.assertTrue((ROOT / "tools/repository_stars.py").exists(), "Repository star cache is not implemented")
        return importlib.import_module("repository_stars")

    def response(self, stars=1200, **changes):
        value = {"full_name": "stubbi/asm", "html_url": "https://github.com/stubbi/asm", "stargazers_count": stars}
        value.update(changes)
        return value

    def collect(self, response=None, at=None):
        module = self.module()
        def fetch(url):
            self.assertEqual(url, "https://api.github.com/repos/stubbi/asm")
            return self.response() if response is None else response
        return module.collect(self.path, fetch, now=at or self.now)

    def test_fixed_repository_success_roundtrips_private_cache_and_zero_is_known(self):
        module = self.module()
        value = self.collect(self.response(0))
        self.assertEqual(value, {"schema": 1, "source": "github", "repository": "stubbi/asm", "observed_at": self.now,
                                 "stars": 0, "stale": False, "refresh_error": None})
        self.assertEqual(module.load_snapshot(self.path, now=self.now), value)
        self.assertEqual(json.loads(self.path.read_bytes()), value)
        self.assertEqual(self.path.stat().st_mode & 0o077, 0)

    def test_missing_corrupt_duplicate_future_and_expired_cache_keep_truthful_states(self):
        module = self.module()
        missing = module.load_snapshot(self.path, now=self.now)
        self.assertIsNone(missing["stars"])
        self.assertIsNone(missing["observed_at"])
        self.assertTrue(missing["stale"])
        self.collect()
        self.assertFalse(module.load_snapshot(self.path, now="2026-01-01T12:04:59Z")["stale"])
        self.assertTrue(module.load_snapshot(self.path, now="2026-01-01T12:05:00Z")["stale"])
        self.assertIsNone(module.load_snapshot(self.path, now="2026-01-01T11:59:59Z")["stars"])
        for raw in (b"broken", b'{"schema":1,"schema":1}', b"x" * 65537):
            self.path.write_bytes(raw)
            value = module.load_snapshot(self.path, now=self.now)
            self.assertIsNone(value["stars"])
            self.assertTrue(value["stale"])
            self.assertIsInstance(value["refresh_error"], str)

    def test_failed_refresh_retains_prior_count_and_bytes_without_exposing_error_detail(self):
        module = self.module()
        self.collect()
        original = self.path.read_bytes()
        def failed(url): raise OSError("private credential must not appear")
        value = module.collect(self.path, failed, now="2026-01-01T13:01:00Z")
        self.assertEqual(value["stars"], 1200)
        self.assertEqual(value["observed_at"], self.now)
        self.assertTrue(value["stale"])
        self.assertNotIn("credential", value["refresh_error"])
        self.assertEqual(self.path.read_bytes(), original)
        self.path.unlink()
        self.assertIsNone(module.collect(self.path, failed, now=self.now)["stars"])

    def test_bad_identity_and_non_safe_counts_never_replace_a_valid_cache(self):
        self.collect()
        original = self.path.read_bytes()
        invalid = [self.response(1, full_name="someone/else"), self.response(1, html_url="https://evil.example/"),
                   self.response(True), self.response(-1), self.response(1.0), self.response("10"),
                   self.response(2 ** 53), {}, []]
        for response in invalid:
            with self.subTest(response=response):
                value = self.collect(response, at="2026-01-01T13:00:00Z")
                self.assertEqual(value["stars"], 1200)
                self.assertTrue(value["stale"])
                self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(self.collect(self.response(2 ** 53 - 1), at="2026-01-01T13:00:00Z")["stars"], 2 ** 53 - 1)

    def test_symlink_file_or_ancestor_is_never_read_or_replaced(self):
        module = self.module()
        target = Path(self.temp.name) / "unrelated"
        target.write_text("preserve")
        self.path.parent.mkdir()
        self.path.symlink_to(target)
        self.assertIsNone(module.load_snapshot(self.path, now=self.now)["stars"])
        self.assertIsNone(self.collect()["stars"])
        self.assertTrue(self.path.is_symlink())
        self.assertEqual(target.read_text(), "preserve")
        self.path.unlink()
        self.path.parent.rmdir()
        target_dir = Path(self.temp.name) / "elsewhere"
        target_dir.mkdir()
        self.path.parent.symlink_to(target_dir, target_is_directory=True)
        self.assertIsNone(self.collect()["stars"])
        self.assertFalse((target_dir / self.path.name).exists())

    def test_header_markers_are_bounded_and_counts_have_exact_accessible_context(self):
        module = self.module()
        start, end = "<!-- github-stars:start -->", "<!-- github-stars:end -->"
        content = "before" + start + "old" + end + "after"
        value = self.collect(self.response(121580))
        rendered = module.render_header(content, value, now=self.now)
        self.assertTrue(rendered.startswith("before" + start))
        self.assertTrue(rendered.endswith(end + "after"))
        self.assertIn('href="https://github.com/stubbi/asm"', rendered)
        self.assertIn('class="github-stars"', rendered)
        self.assertIn("Star on GitHub", rendered)
        self.assertIn("122k", rendered)
        self.assertIn("121,580", rendered)
        self.assertIn(self.now, rendered)
        self.assertLess(rendered.index('class="github-stars-count"'), rendered.index('class="sr-only github-stars-observation"'))
        self.assertIn(' stars</span>', rendered)
        self.assertNotIn("<script", rendered)
        self.assertEqual(module.render_header("unrelated", value), "unrelated")
        self.assertIn('>0</span>', module.render_header(content, self.collect(self.response(0), at="2026-01-01T13:00:00Z"),
                                                      now="2026-01-01T13:00:00Z"))
        for bad in (start, end, end + start, content + start + end):
            with self.subTest(content=bad), self.assertRaises(registry.RegistryError): module.render_header(bad, value)
        hostile = dict(value, stars='<script>alert(1)</script>', observed_at='" onmouseover="bad')
        fallback = module.render_header(content, hostile)
        self.assertNotIn("onmouseover", fallback)
        self.assertNotIn("<script", fallback)
        self.assertIn("Star on GitHub", fallback)
        self.assertNotIn("compact-count", fallback)

    def test_background_refresh_serves_cache_without_file_or_network_work_in_snapshot(self):
        module = self.module()
        self.collect(at=datetime.now(timezone.utc) - timedelta(hours=2))
        entered, release = threading.Event(), threading.Event()
        calls = []
        def fetch(url):
            calls.append(url)
            entered.set()
            release.wait(1)
            return self.response(1300)
        service = module.RepositoryStats(self.path, fetch, refresh_seconds=3600)
        self.addCleanup(service.stop)
        service.start(); service.start()
        self.assertTrue(entered.wait(1))
        self.path.unlink()
        started = time.monotonic()
        for _ in range(100): self.assertEqual(service.snapshot()["stars"], 1200)
        self.assertLess(time.monotonic() - started, 0.2)
        release.set()
        deadline = time.monotonic() + 1
        while service.snapshot()["stars"] != 1300 and time.monotonic() < deadline: threading.Event().wait(0.001)
        self.assertEqual(service.snapshot()["stars"], 1300)
        copied = service.snapshot(); copied["stars"] = 999
        self.assertEqual(service.snapshot()["stars"], 1300)
        self.assertEqual(len(calls), 1)
        service.stop()

    def test_fresh_cache_avoids_repeated_api_calls_and_unknown_helper_has_no_fake_zero(self):
        module = self.module()
        self.collect()
        calls = []
        def forbidden(url):
            calls.append(url)
            raise OSError("Fresh cache must avoid a GitHub request")
        self.assertEqual(module.collect(self.path, forbidden, now="2026-01-01T12:04:59Z")["stars"], 1200)
        self.assertEqual(calls, [])
        self.assertIsNone(module.unknown_snapshot()["stars"])

    def test_expired_observation_is_not_presented_as_a_current_header_count(self):
        module = self.module()
        value = self.collect(self.response(1200))
        content = module.START + "old" + module.END
        self.assertIn('github-stars-count', module.render_header(content, value, now="2026-01-01T12:04:59Z"))
        expired = module.render_header(content, value, now="2026-01-01T12:05:00Z")
        self.assertIn("Star on GitHub", expired)
        self.assertNotIn('github-stars-count', expired)
        self.assertNotIn('1.2k', expired)

    def test_worker_refreshes_when_existing_observation_expires_instead_of_waiting_a_full_interval(self):
        module = self.module()
        self.collect()
        at = datetime(2026, 1, 1, 12, 4, 59, tzinfo=timezone.utc)
        original_clock, waits = module._clock, []
        class StopAfterWait:
            def is_set(self): return False
            def wait(self, seconds): waits.append(seconds); return True
        def forbidden(url): self.fail("A current cache must not fetch GitHub before it expires")
        with patch.object(module, "_clock", side_effect=lambda value=None: at if value is None else original_clock(value)):
            service = module.RepositoryStats(self.path, forbidden)
            service._stop = StopAfterWait()
            service._run()
        self.assertEqual(waits, [1])

    def test_failed_background_refresh_preserves_last_valid_memory_and_waits_for_interval(self):
        module = self.module()
        self.collect(at=datetime.now(timezone.utc) - timedelta(hours=2))
        calls = []
        def failed(url):
            calls.append(url)
            raise OSError("unavailable")
        service = module.RepositoryStats(self.path, failed, refresh_seconds=3600)
        self.addCleanup(service.stop)
        self.path.unlink()
        service.start()
        deadline = time.monotonic() + 1
        while service.snapshot()["refresh_error"] is None and time.monotonic() < deadline: threading.Event().wait(0.001)
        self.assertEqual(service.snapshot()["stars"], 1200)
        self.assertTrue(service.snapshot()["stale"])
        self.assertIsNotNone(service.snapshot()["refresh_error"])
        self.assertEqual(len(calls), 1)

    def test_symlink_created_during_fetch_is_not_replaced(self):
        module = self.module()
        unrelated = Path(self.temp.name) / "unrelated"
        unrelated.write_text("preserve")
        def fetch(url):
            self.path.symlink_to(unrelated)
            return self.response()
        value = module.collect(self.path, fetch, now=self.now)
        self.assertIsNone(value["stars"])
        self.assertTrue(self.path.is_symlink())
        self.assertEqual(unrelated.read_text(), "preserve")

    def test_wallclock_rollback_returns_unknown_without_erasing_the_observation(self):
        module = self.module()
        observed = datetime.now(timezone.utc)
        self.collect(at=observed)
        original = self.path.read_bytes()
        service = module.RepositoryStats(self.path, lambda url: self.fail("No refresh is required"))
        clock = module._clock
        rollback = observed - timedelta(seconds=1)
        content = "<!-- github-stars:start -->old<!-- github-stars:end -->"
        with patch.object(module, "_clock", side_effect=lambda value=None: rollback if value is None else clock(value)):
            value = service.snapshot()
            self.assertIsNone(value["stars"])
            self.assertTrue(value["stale"])
            self.assertIsNotNone(value["refresh_error"])
            self.assertNotIn("compact-count", module.render_header(content, json.loads(original)))
        self.assertEqual(service.snapshot()["stars"], 1200)
        self.assertEqual(self.path.read_bytes(), original)

    def test_permission_and_atomic_finalization_failures_preserve_private_previous_cache(self):
        module = self.module()
        for operation in ("fchmod", "replace"):
            with self.subTest(operation=operation):
                self.path = Path(self.temp.name).resolve() / operation / "github.json"
                self.collect()
                original = self.path.read_bytes()
                with patch.object(module.os, operation, side_effect=OSError("cannot finalize cache")):
                    value = self.collect(self.response(1300), at="2026-01-01T13:00:00Z")
                self.assertTrue(value["stale"])
                self.assertEqual(value["stars"], 1200)
                self.assertEqual(self.path.read_bytes(), original)
                self.assertEqual(self.path.stat().st_mode & 0o077, 0)
                self.assertEqual(list(self.path.parent.iterdir()), [self.path])


if __name__ == "__main__": unittest.main()
