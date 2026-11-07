"""First-party ledger fixtures are not evidence of live visitor activity.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from contextlib import closing
import importlib
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry


class DownloadDataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name).resolve() / "downloads.sqlite3"
        self.records = [self.record()]

    def module(self):
        self.assertTrue((ROOT / "tools/download_data.py").exists(), "First-party download ledger is not implemented")
        return importlib.import_module("download_data")

    def record(self, name="owner/math", version="0.1.0"):
        return {"schema": 1, "name": name, "version": version, "summary": "A bounded example.", "license": "MIT",
                "source": {"repository": "https://github.com/stubbi/asm", "commit": "1" * 40, "path": "examples/math"},
                "yanked": False, "artifacts": [{"target": "x86_64-linux", "kind": "source", "sha256": "a" * 64,
                "bytes": 100, "url": "https://github.com/stubbi/asm/releases/download/v" + version + "/" + name.replace("/", "-") + ".tar.gz"}]}

    def store(self): return self.module().Store(self.path, self.records)

    def event(self, identifier="event-1", at="2026-01-01T00:00:01Z", **changes):
        value = {"schema": 1, "event_id": identifier, "occurred_at": at, "name": "owner/math", "version": "0.1.0",
                 "target": "x86_64-linux", "kind": "source", "sha256": "a" * 64, "bytes": 100,
                 "event_type": "completed", "traffic": "public"}
        value.update(changes)
        return value

    def test_only_heartbeat_covered_completed_public_events_count(self):
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        self.assertTrue(store.record(session, self.event()))
        self.assertEqual(store.snapshot("2026-01-01T00:00:02Z")["counts"], {"owner/math": 0})
        store.heartbeat(session, "2026-01-01T00:00:02Z")
        value = store.snapshot("2026-01-01T00:00:03Z")
        self.assertEqual(value["counts"], {"owner/math": 1})
        self.assertEqual(value["version_counts"], {"owner/math@0.1.0": 1})
        self.assertEqual(value["coverage_end"], "2026-01-01T00:00:02Z")
        self.assertFalse(value["complete"])
        self.assertFalse(value["stale"])

    def test_identical_replay_is_idempotent_and_conflicts_do_not_replace_events(self):
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        self.assertTrue(store.record(session, self.event()))
        self.assertFalse(store.record(session, self.event()))
        with self.assertRaises(registry.RegistryError): store.record(session, self.event(traffic="internal"))
        store.heartbeat(session, "2026-01-01T00:00:02Z")
        self.assertEqual(store.snapshot("2026-01-01T00:00:03Z")["counts"]["owner/math"], 1)

    def test_partial_failed_redirect_bot_and_internal_events_are_retained_but_excluded(self):
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        cases = [dict(event_type="range", bytes=50), dict(event_type="failed", bytes=30),
                 dict(event_type="redirect", bytes=0), dict(traffic="bot"), dict(traffic="internal")]
        for number, change in enumerate(cases): store.record(session, self.event("excluded-" + str(number), **change))
        store.heartbeat(session, "2026-01-01T00:00:02Z")
        self.assertEqual(store.snapshot("2026-01-01T00:00:03Z")["counts"]["owner/math"], 0)
        with closing(sqlite3.connect(self.path)) as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM events").fetchone()[0], 5)

    def test_equal_bytes_in_different_packages_keep_their_selection_identity(self):
        self.records.append(self.record("owner/other"))
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        store.record(session, self.event())
        store.record(session, self.event("event-2", name="owner/other"))
        store.heartbeat(session, "2026-01-01T00:00:02Z")
        self.assertEqual(store.snapshot("2026-01-01T00:00:03Z")["counts"], {"owner/math": 1, "owner/other": 1})

    def test_yanked_versions_remain_in_historical_counts(self):
        self.records[0].update(yanked=True, yank_reason="Withdrawn example.")
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        store.record(session, self.event()); store.heartbeat(session, "2026-01-01T00:00:02Z")
        self.assertEqual(store.snapshot("2026-01-01T00:00:03Z")["counts"]["owner/math"], 1)

    def test_bad_events_are_rejected_without_changing_counts(self):
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        changes = [{"extra": "field"}, {"schema": True}, {"name": "other/math"}, {"version": "9.0.0"},
                   {"target": "aarch64-linux"}, {"sha256": "b" * 64}, {"bytes": 99}, {"bytes": True},
                   {"event_type": "install"}, {"traffic": "person"}, {"event_id": "e" * 129},
                   {"occurred_at": "2999-01-01T00:00:00Z"}, {"occurred_at": "2026-01-01T00:00:01"}]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(registry.RegistryError): store.record(session, self.event(**change))
        store.heartbeat(session, "2026-01-01T00:00:02Z")
        self.assertEqual(store.snapshot("2026-01-01T00:00:03Z")["counts"]["owner/math"], 0)

    def test_interruption_starts_a_new_segment_without_erasing_events(self):
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        store.record(session, self.event()); store.heartbeat(session, "2026-01-01T00:00:02Z")
        store.interrupt(session)
        self.assertTrue(store.snapshot("2026-01-01T00:00:03Z")["stale"])
        store.heartbeat(session, "2026-01-01T00:00:04Z")
        value = store.snapshot("2026-01-01T00:00:05Z")
        self.assertEqual(value["collection_started_at"], "2026-01-01T00:00:00Z")
        self.assertEqual(value["coverage_start"], "2026-01-01T00:00:04Z")
        self.assertEqual(value["counts"]["owner/math"], 1)
        self.assertFalse(value["complete"])

    def test_heartbeat_gaps_and_restarts_never_bridge_unknown_time(self):
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        store.heartbeat(session, "2026-01-01T00:01:01Z")
        self.assertEqual(store.snapshot("2026-01-01T00:01:02Z")["coverage_start"], "2026-01-01T00:01:01Z")
        reopened = self.store(); new_session = reopened.begin("2026-01-01T00:01:03Z")
        with self.assertRaises(registry.RegistryError): store.heartbeat(session, "2026-01-01T00:01:04Z")
        reopened.heartbeat(new_session, "2026-01-01T00:01:05Z")
        self.assertEqual(reopened.snapshot("2026-01-01T00:01:06Z")["coverage_start"], "2026-01-01T00:01:03Z")

    def test_restart_replay_and_rebuild_preserve_events_and_identity(self):
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        store.record(session, self.event()); store.finish(session, "2026-01-01T00:00:02Z")
        rebuilt = self.store(); new_session = rebuilt.begin("2026-01-01T00:00:03Z")
        self.assertFalse(rebuilt.record(new_session, self.event()))
        rebuilt.heartbeat(new_session, "2026-01-01T00:00:04Z")
        self.assertEqual(rebuilt.snapshot("2026-01-01T00:00:05Z")["counts"]["owner/math"], 1)
        self.records[0]["artifacts"][0]["sha256"] = "b" * 64
        with self.assertRaises(registry.RegistryError): self.store().begin("2026-01-01T00:00:06Z")

    def test_constructor_is_lazy_and_invalid_state_is_never_overwritten(self):
        self.path.write_bytes(b"retain invalid source evidence")
        store = self.store()
        with self.assertRaises(registry.RegistryError): store.snapshot()
        with self.assertRaises(registry.RegistryError): store.begin()
        self.assertEqual(self.path.read_bytes(), b"retain invalid source evidence")

    def test_symlinks_and_source_rebinding_are_rejected(self):
        outside = self.path.with_name("outside"); outside.write_bytes(b"retain this file")
        self.path.symlink_to(outside)
        with self.assertRaises(registry.RegistryError): self.store().begin()
        self.assertEqual(outside.read_bytes(), b"retain this file")
        self.path.unlink(); self.store().begin("2026-01-01T00:00:00Z")
        with self.assertRaises(registry.RegistryError): self.module().Store(self.path, self.records, source="another-origin").snapshot()
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_old_heartbeat_is_stale_and_future_or_regressing_clocks_are_rejected(self):
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        self.assertTrue(store.snapshot("2026-01-01T00:01:01Z")["stale"])
        with self.assertRaises(registry.RegistryError): store.heartbeat(session, "2025-12-31T23:59:59Z")
        with self.assertRaises(registry.RegistryError): store.snapshot("2025-12-31T23:59:59Z")
        with self.assertRaises(registry.RegistryError): store.begin("2999-01-01T00:00:00Z")

    def test_thirty_day_window_uses_heartbeat_and_excludes_its_left_boundary(self):
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        # A clearly labeled retained-interval fixture tests window boundaries.
        # It does not claim thirty days of live collection. Other tests cover
        # heartbeat admission, gaps, interruptions, and restart behavior.
        from datetime import datetime
        end = "2026-01-31T00:00:00Z"
        for identifier, at in (("left", "2026-01-01T00:00:00Z"), ("inside", "2026-01-01T00:00:01Z")):
            store.record(session, self.event(identifier, at))
        with closing(sqlite3.connect(self.path)) as connection, connection:
            stamp = int(datetime.fromisoformat(end.replace("Z", "+00:00")).timestamp()) * 1000000
            connection.execute("UPDATE sessions SET heartbeat=? WHERE session_id=?", (stamp, session))
            connection.execute("UPDATE intervals SET end_at=? WHERE session_id=?", (stamp, session))
        store.record(session, self.event("right", end))
        store.record(session, self.event("pending", "2026-01-31T00:00:01Z"))
        value = store.snapshot("2026-01-31T00:00:02Z")
        self.assertTrue(value["complete"])
        self.assertEqual(value["counts"]["owner/math"], 2)
        self.assertEqual(value["coverage_end"], end)

    def test_a_symlink_ancestor_cannot_redirect_the_private_store(self):
        outside = self.path.with_name("outside"); outside.mkdir()
        link = self.path.with_name("link"); link.symlink_to(outside, target_is_directory=True)
        store = self.module().Store(link / "nested" / "state.sqlite3", self.records)
        with self.assertRaises(registry.RegistryError): store.begin("2026-01-01T00:00:00Z")
        self.assertFalse((outside / "nested").exists())

    def test_event_capacity_failure_rolls_back_without_replacing_evidence(self):
        from unittest.mock import patch
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        with patch.object(self.module(), "MAX_EVENTS", 0):
            with self.assertRaises(registry.RegistryError): store.record(session, self.event())
            self.assertEqual(store.snapshot("2026-01-01T00:00:02Z")["counts"]["owner/math"], 0)
        store.interrupt(session)
        self.assertTrue(store.snapshot("2026-01-01T00:00:02Z")["stale"])

    def test_daily_counts_preserve_cutoff_replay_classification_and_version_identity(self):
        self.records.append(self.record(version="0.2.0"))
        store = self.store(); session = store.begin("2026-01-01T06:00:00Z")
        rows = [("left", "2026-01-01T06:00:00Z", {}),
                ("inside", "2026-01-01T06:00:00.000001Z", {}),
                ("midnight", "2026-01-02T00:00:00Z", {"version": "0.2.0"}),
                ("right", "2026-01-31T06:00:00Z", {}),
                ("pending", "2026-01-31T06:00:00.000001Z", {}),
                ("bot", "2026-01-02T00:00:00Z", {"traffic": "bot"}),
                ("range", "2026-01-02T00:00:00Z", {"event_type": "range", "bytes": 20})]
        for identifier, at, changes in rows: store.record(session, self.event(identifier, at, **changes))
        self.assertFalse(store.record(session, self.event("inside", "2026-01-01T06:00:00.000001Z")))
        store.heartbeat(session, "2026-01-31T06:00:00Z")
        value = store.snapshot("2026-01-31T06:00:01Z")
        self.assertEqual(value.get("daily_counts"), [
            {"date": "2026-01-01", "name": "owner/math", "version": "0.1.0", "count": 1},
            {"date": "2026-01-02", "name": "owner/math", "version": "0.2.0", "count": 1},
            {"date": "2026-01-31", "name": "owner/math", "version": "0.1.0", "count": 1}])
        self.assertEqual(value["counts"]["owner/math"], 3)
        self.assertEqual(value["version_counts"], {"owner/math@0.1.0": 2, "owner/math@0.2.0": 1})

    def test_snapshot_keeps_earlier_healthy_segments_and_merges_touching_intervals(self):
        store = self.store(); first = store.begin("2026-01-01T00:00:00Z")
        store.finish(first, "2026-01-01T00:00:02Z")
        touching = store.begin("2026-01-01T00:00:02Z")
        store.finish(touching, "2026-01-01T00:00:04Z")
        separate = store.begin("2026-01-01T00:00:06Z")
        store.heartbeat(separate, "2026-01-01T00:00:08Z")
        value = store.snapshot("2026-01-01T00:00:09Z")
        self.assertEqual(value.get("coverage_intervals"), [
            {"start": "2026-01-01T00:00:00Z", "end": "2026-01-01T00:00:04Z"},
            {"start": "2026-01-01T00:00:06Z", "end": "2026-01-01T00:00:08Z"}])
        self.assertEqual(value["coverage_start"], "2026-01-01T00:00:06Z")
        self.assertFalse(value["complete"])

    def test_daily_history_and_coverage_are_clipped_before_the_same_rolling_window(self):
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        store.record(session, self.event("expired", "2026-01-01T00:00:01Z"))
        store.heartbeat(session, "2026-01-01T00:00:02Z")
        store.heartbeat(session, "2026-02-01T00:00:00Z")
        value = store.snapshot("2026-02-01T00:00:01Z")
        self.assertEqual(value["counts"]["owner/math"], 0)
        self.assertEqual(value["daily_counts"], [])
        self.assertEqual(value["coverage_intervals"], [{"start": "2026-02-01T00:00:00Z", "end": "2026-02-01T00:00:00Z"}])

    def test_real_ledger_daily_projection_does_not_fill_precollection_days_with_zero(self):
        import discovery
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        store.record(session, self.event())
        store.heartbeat(session, "2026-01-01T00:00:02Z")
        observation = store.snapshot("2026-01-01T00:00:03Z")
        value = discovery.delivery_activity(self.records, "owner/math", observation, version="0.1.0")
        self.assertEqual(value["total"], 1)
        self.assertEqual(len(value["days"]), 31)
        self.assertTrue(all(day["count"] is None and day["coverage"] == "unavailable" for day in value["days"][:-1]))
        self.assertEqual(value["days"][-1]["count"], 1)
        self.assertEqual(value["days"][-1]["observed_seconds"], 2)
        self.assertEqual(value["days"][-1]["coverage"], "complete", "The clipped two-second final bin is covered; earlier history is not.")
        self.assertFalse(value["complete"])

    def test_retained_counts_keep_expired_events_and_exclude_pending_or_nonpublic_transfers(self):
        self.records.append(self.record(version="0.2.0"))
        store = self.store(); session = store.begin("2026-01-01T00:00:00Z")
        store.record(session, self.event("first", "2026-01-01T00:00:00Z"))
        self.assertFalse(store.record(session, self.event("first", "2026-01-01T00:00:00Z")))
        store.record(session, self.event("older", "2026-01-01T00:00:01Z", version="0.2.0"))
        store.record(session, self.event("internal", "2026-01-01T00:00:01Z", traffic="internal"))
        store.record(session, self.event("bot", "2026-01-01T00:00:01Z", traffic="bot"))
        store.record(session, self.event("range", "2026-01-01T00:00:01Z", event_type="range", bytes=50))
        store.record(session, self.event("pending", "2026-02-01T00:00:01Z"))
        store.heartbeat(session, "2026-02-01T00:00:00Z")
        value = store.snapshot("2026-02-01T00:00:02Z")
        self.assertEqual(value["counts"]["owner/math"], 0)
        self.assertEqual(value["retained_counts"], {"owner/math": 2})
        self.assertEqual(value["retained_version_counts"], {"owner/math@0.1.0": 1, "owner/math@0.2.0": 1})
        self.assertFalse(value["retained_complete"])
        self.assertEqual(value["coverage_end"], "2026-02-01T00:00:00Z")

    def test_retained_coverage_cannot_forget_a_gap_before_a_complete_recent_window(self):
        from datetime import datetime
        store = self.store(); first = store.begin("2026-01-01T00:00:00Z")
        store.finish(first, "2026-01-01T00:00:02Z")
        second = store.begin("2026-01-02T00:00:00Z")
        # Retained healthy-span fixture; not a claim of live month-long collection.
        cutoff = int(datetime.fromisoformat("2026-02-02T00:00:00+00:00").timestamp()) * 1000000
        with closing(sqlite3.connect(self.path)) as connection, connection:
            connection.execute("UPDATE sessions SET heartbeat=? WHERE session_id=?", (cutoff, second))
            connection.execute("UPDATE intervals SET end_at=? WHERE session_id=?", (cutoff, second))
        value = store.snapshot("2026-02-02T00:00:01Z")
        self.assertTrue(value["complete"])
        self.assertFalse(value["retained_complete"])
        self.assertEqual(value["retained_coverage_start"], "2026-01-02T00:00:00Z")
        self.assertEqual(value["collection_started_at"], "2026-01-01T00:00:00Z")

    def test_retained_zero_and_touching_sessions_have_explicit_full_history_coverage(self):
        store = self.store(); first = store.begin("2026-01-01T00:00:00Z")
        store.finish(first, "2026-01-01T00:00:02Z")
        second = store.begin("2026-01-01T00:00:02Z")
        store.heartbeat(second, "2026-01-01T00:00:04Z")
        value = store.snapshot("2026-01-01T00:00:05Z")
        self.assertEqual(value["retained_counts"], {"owner/math": 0})
        self.assertTrue(value["retained_complete"])
        self.assertEqual(value["retained_coverage_start"], value["collection_started_at"])
        self.assertFalse(value["complete"])

    def test_totals_and_daily_coverage_agree_across_contiguous_sessions_but_never_fill_a_gap(self):
        import discovery
        from datetime import datetime
        # These retained-interval fixtures represent coverage history. They
        # do not claim thirty days of live collection in this short test.
        def micros(value):
            return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000000)
        for label, seam, expected_complete in (
                ("touching", "2026-01-16T00:00:00Z", True),
                ("overlapping", "2026-01-15T23:59:59Z", True),
                ("gap", "2026-01-16T00:00:00.000001Z", False)):
            with self.subTest(label=label):
                path = self.path.with_name(label + ".sqlite3")
                store = self.module().Store(path, self.records)
                first = store.begin("2026-01-01T00:00:00Z")
                store.record(first, self.event("first", "2026-01-02T00:00:00Z"))
                with closing(sqlite3.connect(path)) as connection, connection:
                    split = micros("2026-01-16T00:00:00Z")
                    connection.execute("UPDATE sessions SET heartbeat=?,finished_at=? WHERE session_id=?", (split, split, first))
                    connection.execute("UPDATE intervals SET end_at=? WHERE session_id=?", (split, first))
                second = store.begin("2026-01-16T00:00:01Z")
                store.record(second, self.event("second", "2026-01-30T00:00:00Z"))
                with closing(sqlite3.connect(path)) as connection, connection:
                    connection.execute("UPDATE sessions SET started_at=?,heartbeat=? WHERE session_id=?", (micros(seam), micros("2026-01-31T00:00:00Z"), second))
                    connection.execute("UPDATE intervals SET start_at=?,end_at=? WHERE session_id=?", (micros(seam), micros("2026-01-31T00:00:00Z"), second))
                observation = store.snapshot("2026-01-31T00:00:01Z")
                activity = discovery.delivery_activity(self.records, "owner/math", observation)
                counts = discovery.delivery_counts(self.records, observation)
                self.assertEqual(observation["coverage_start"], "2026-01-01T00:00:00Z" if expected_complete else seam)
                self.assertEqual(observation["complete"], expected_complete)
                self.assertEqual(activity["complete"], expected_complete)
                self.assertEqual(counts["complete"], expected_complete)
                self.assertEqual(activity["total"], 2)
                self.assertEqual(counts["packages"]["owner/math"]["total"], 2)
                self.assertEqual(sum(day["count"] or 0 for day in activity["days"]), 2)


if __name__ == "__main__": unittest.main()
