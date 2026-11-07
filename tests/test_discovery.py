"""Discovery uses source-bound observations without inventing missing windows.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
from contextlib import closing
import importlib
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name).resolve() / "discovery.sqlite3"
        self.responses, self.calls = {}, []
        self.records = [self.record()]

    def module(self):
        self.assertTrue((ROOT / "tools/discovery.py").exists(), "Discovery collector is not implemented")
        return importlib.import_module("discovery")

    def record(self, name="owner/math", version="0.1.0", *, created="2026-01-31T00:00:00Z",
               published="2025-12-01T00:00:00Z", count=0):
        tag = "v" + version
        api = "https://api.github.com/repos/stubbi/asm/releases/tags/" + tag
        url = "https://github.com/stubbi/asm/releases/download/" + tag + "/" + name.replace("/", "-") + ".tar.gz"
        release_id = sum(part * scale for part, scale in zip(registry.version_tuple(version), (1000000, 1000, 1))) + 1
        response = self.responses.setdefault(api, {"id": release_id,
                    "tag_name": tag, "draft": False, "created_at": "2025-01-01T00:00:00Z",
                    "published_at": published, "assets": []})
        response["assets"].append({"id": len(response["assets"]) + 100 * response["id"],
                    "state": "uploaded", "browser_download_url": url, "size": 100,
                    "digest": "sha256:" + "a" * 64, "created_at": created, "download_count": count})
        return {"schema": 1, "name": name, "version": version, "summary": "A bounded example.",
                "license": "MIT", "source": {"repository": "https://github.com/stubbi/asm",
                "commit": "1" * 40, "path": "examples/math"}, "yanked": False,
                "artifacts": [{"kind": "source", "target": "x86_64-linux", "bytes": 100,
                "sha256": "a" * 64, "url": url}]}

    def fetch(self, url):
        self.calls.append(url)
        self.assertIn(url, self.responses)
        return deepcopy(self.responses[url])

    def asset(self, version="0.1.0", index=0):
        return self.responses["https://api.github.com/repos/stubbi/asm/releases/tags/v" + version]["assets"][index]

    def collect(self, at="2026-02-01T00:00:00Z"):
        return self.module().collect(self.records, self.state, fetch=self.fetch, observed_at=at)

    def package(self, snapshot): return snapshot["packages"][0]

    def test_young_asset_has_a_real_zero_and_one_source_fetch_per_release(self):
        self.records.append(self.record("owner/other"))
        value = self.collect()
        self.assertEqual(self.calls, ["https://api.github.com/repos/stubbi/asm/releases/tags/v0.1.0"])
        self.assertEqual(value["window"], {"days": 30, "start": "2026-01-02T00:00:00Z",
                         "end": "2026-02-01T00:00:00Z", "basis": "rolling-observation"})
        self.assertEqual(self.package(value)["downloads_30d"], 0)
        self.assertTrue(self.package(value)["downloads_30d_exact"])
        self.assertEqual(self.package(value)["downloads_30d_coverage"], "complete")
        self.assertEqual(value["feeds"]["popular"], ["owner/math", "owner/other"])
        self.assertEqual(value["feeds"]["new"], ["owner/math", "owner/other"])

    def test_unknown_snapshot_has_no_invented_dates_counts_or_feeds(self):
        value = self.module().unknown_snapshot(self.records)
        self.assertIsNone(value["observed_at"])
        self.assertIsNone(self.package(value)["first_published_at"])
        self.assertIsNone(self.package(value)["downloads_30d"])
        self.assertEqual(self.package(value)["downloads_30d_coverage"], "unavailable")
        self.assertEqual(value["feeds"], {"popular": [], "new": [], "updated": []})
        self.assertEqual(self.module().load_snapshot(self.state, self.records), value)

    def test_exact_release_dates_use_each_bound_artifacts_later_availability(self):
        self.records.append(self.record(version="0.2.0", created="2026-01-30T00:00:00Z",
                                        published="2026-02-01T00:00:00Z"))
        self.collect()
        calls = list(self.calls)
        before = self.state.read_bytes()
        dates = self.module().release_dates(self.state, self.records, now="2026-02-02T00:00:00Z")
        self.assertEqual(dates, {"owner/math@0.1.0": "2026-01-31T00:00:00Z",
                                 "owner/math@0.2.0": "2026-02-01T00:00:00Z"})
        self.assertEqual(self.calls, calls)
        self.assertEqual(self.state.read_bytes(), before)

    def test_exact_release_date_waits_for_every_registered_asset_and_rejects_changed_binding(self):
        import sqlite3
        second = deepcopy(self.records[0]["artifacts"][0])
        second.update(target="aarch64-linux", url=second["url"].replace("owner-math", "owner-math-arm"))
        self.records[0]["artifacts"].append(second)
        asset = deepcopy(self.asset())
        asset.update(id=asset["id"] + 1, browser_download_url=second["url"], created_at="2026-02-01T00:00:00Z")
        self.responses["https://api.github.com/repos/stubbi/asm/releases/tags/v0.1.0"]["assets"].append(asset)
        self.collect()
        self.assertEqual(self.module().release_dates(self.state, self.records),
                         {"owner/math@0.1.0": "2026-02-01T00:00:00Z"})
        with closing(sqlite3.connect(self.state)) as connection, connection:
            connection.execute("UPDATE assets SET size=101 WHERE url=?", (second["url"],))
        before = self.state.read_bytes()
        self.assertEqual(self.module().release_dates(self.state, self.records), {"owner/math@0.1.0": None})
        self.assertEqual(self.state.read_bytes(), before)

    def test_exact_release_dates_do_not_borrow_dates_for_changed_or_missing_bindings(self):
        self.collect()
        changed = deepcopy(self.records)
        changed[0]["artifacts"][0]["sha256"] = "b" * 64
        self.assertEqual(self.module().release_dates(self.state, changed, now="2026-02-02T00:00:00Z"),
                         {"owner/math@0.1.0": None})
        self.assertEqual(self.module().release_dates(self.state.with_name("missing.sqlite3"), self.records),
                         {"owner/math@0.1.0": None})
        self.assertFalse(self.state.with_name("missing.sqlite3").exists())

    def test_exact_release_dates_keep_yanked_history_and_fail_closed_on_corruption(self):
        self.records[0].update(yanked=True, yank_reason="Retained fixture.")
        self.collect()
        self.assertEqual(self.module().release_dates(self.state, self.records, now="2026-02-02T00:00:00Z"),
                         {"owner/math@0.1.0": "2026-01-31T00:00:00Z"})
        self.state.write_bytes(b"corrupt state")
        self.assertEqual(self.module().release_dates(self.state, self.records), {"owner/math@0.1.0": None})
        self.assertEqual(self.state.read_bytes(), b"corrupt state")

    def test_older_asset_without_a_window_baseline_is_unknown(self):
        self.asset().update(created_at="2025-12-01T00:00:00Z", download_count=120)
        value = self.collect()
        self.assertIsNone(self.package(value)["downloads_30d"])
        self.assertEqual(value["feeds"]["popular"], [])

    def test_boundary_observation_makes_an_exact_window(self):
        self.asset().update(created_at="2025-12-01T00:00:00Z", download_count=10)
        self.collect("2026-01-02T00:00:00Z")
        self.asset()["download_count"] = 25
        value = self.collect()
        self.assertEqual(self.package(value)["downloads_30d"], 15)
        self.assertTrue(self.package(value)["downloads_30d_exact"])

    def test_nearby_later_baseline_is_a_ranked_lower_bound(self):
        self.asset().update(created_at="2025-12-01T00:00:00Z", download_count=10)
        self.collect("2026-01-02T12:00:00Z")
        self.asset()["download_count"] = 25
        value = self.collect()
        self.assertEqual(self.package(value)["downloads_30d"], 15)
        self.assertFalse(self.package(value)["downloads_30d_exact"])
        self.assertEqual(self.package(value)["downloads_30d_coverage"], "lower-bound")
        self.assertEqual(value["feeds"]["popular"], ["owner/math"])

    def test_equal_counts_bracketing_the_boundary_establish_exactness(self):
        self.asset().update(created_at="2025-12-01T00:00:00Z", download_count=10)
        self.collect("2026-01-01T23:00:00Z")
        self.collect("2026-01-02T12:00:00Z")
        self.asset()["download_count"] = 25
        value = self.collect()
        self.assertEqual(self.package(value)["downloads_30d"], 15)
        self.assertTrue(self.package(value)["downloads_30d_exact"])

    def test_a_baseline_more_than_one_day_after_start_cannot_supply_a_window(self):
        self.asset().update(created_at="2025-12-01T00:00:00Z", download_count=10)
        self.collect("2026-01-03T00:00:01Z")
        self.asset()["download_count"] = 25
        self.assertIsNone(self.package(self.collect())["downloads_30d"])

    def test_a_baseline_before_the_start_is_not_used_as_a_lower_bound(self):
        self.asset().update(created_at="2025-12-01T00:00:00Z", download_count=10)
        self.collect("2026-01-01T23:00:00Z")
        self.asset()["download_count"] = 25
        self.assertIsNone(self.package(self.collect())["downloads_30d"])

    def test_source_publication_ignores_commit_creation_and_accounts_for_late_assets(self):
        self.responses.clear()
        self.records = [self.record(version="0.1.0", created="2026-01-21T00:00:00Z", published="2026-01-20T00:00:00Z"),
                        self.record(version="0.2.0", created="2026-01-10T00:00:00Z", published="2026-01-10T00:00:00Z")]
        value = self.package(self.collect())
        self.assertEqual(value["first_published_at"], "2026-01-10T00:00:00Z")
        self.assertEqual(value["last_published_at"], "2026-01-21T00:00:00Z")
        self.assertEqual(value["publication_source"], "github-release")

    def test_yanked_history_does_not_reset_first_date_or_replace_active_last_date(self):
        self.responses.clear()
        self.records = [self.record(version="0.1.0", created="2026-01-01T00:00:00Z", published="2026-01-01T00:00:00Z"),
                        self.record(version="0.2.0", created="2026-01-10T00:00:00Z", published="2026-01-10T00:00:00Z"),
                        self.record(version="0.3.0", created="2026-01-20T00:00:00Z", published="2026-01-20T00:00:00Z")]
        for item in (self.records[0], self.records[2]): item.update(yanked=True, yank_reason="Withdrawn example.")
        value = self.collect()
        self.assertEqual(self.package(value)["first_published_at"], "2026-01-01T00:00:00Z")
        self.assertEqual(self.package(value)["last_published_at"], "2026-01-10T00:00:00Z")
        self.assertEqual(value["feeds"]["updated"], ["owner/math"])
        self.records[1].update(yanked=True, yank_reason="Withdrawn example.")
        value = self.collect("2026-02-01T01:00:00Z")
        self.assertIsNone(self.package(value)["last_published_at"])
        self.assertTrue(all(not feed for feed in value["feeds"].values()))

    def test_downloads_include_all_registered_versions_and_rank_deterministically(self):
        self.asset()["download_count"] = 8
        self.records.append(self.record("owner/other", count=8))
        self.records.append(self.record(version="0.2.0", count=4))
        value = self.collect()
        self.assertEqual(self.package(value)["downloads_30d"], 12)
        self.assertEqual(value["feeds"]["popular"], ["owner/math", "owner/other"])

    def test_fetch_failure_retains_last_valid_snapshot_and_marks_it_stale(self):
        good = self.collect()
        def fail(_): raise OSError("secret token and untrusted upstream body")
        with self.assertRaises(registry.RegistryError):
            self.module().collect(self.records, self.state, fetch=fail, observed_at="2026-02-01T01:00:00Z")
        loaded = self.module().load_snapshot(self.state, self.records, now="2026-02-01T02:00:00Z")
        self.assertEqual(loaded["observed_at"], good["observed_at"])
        self.assertEqual(loaded["packages"], good["packages"])
        self.assertTrue(loaded["stale"])
        self.assertTrue(loaded["refresh_error"])
        self.assertNotIn("secret", loaded["refresh_error"])
        self.collect("2026-02-01T03:00:00Z")
        self.assertFalse(self.module().load_snapshot(self.state, self.records, now="2026-02-01T04:00:00Z")["stale"])

    def test_reset_or_replaced_identity_does_not_overwrite_valid_evidence(self):
        self.asset()["download_count"] = 10
        good = self.collect()
        for change in ({"download_count": 1}, {"id": 9000}):
            with self.subTest(change=change):
                original = deepcopy(self.asset())
                self.asset().update(change)
                with self.assertRaises(registry.RegistryError): self.collect("2026-02-01T01:00:00Z")
                loaded = self.module().load_snapshot(self.state, self.records, now="2026-02-01T02:00:00Z")
                self.assertEqual(loaded["packages"], good["packages"])
                self.assertTrue(loaded["stale"])
                self.asset().clear(); self.asset().update(original)

    def test_changed_release_publication_binding_cannot_rewrite_history(self):
        good = self.collect()
        response = next(iter(self.responses.values()))
        for key, changed in (("published_at", "2026-01-30T00:00:00Z"), ("id", 999)):
            original = response[key]; response[key] = changed
            with self.subTest(key=key), self.assertRaises(registry.RegistryError): self.collect("2026-02-01T01:00:00Z")
            response[key] = original
        self.assertEqual(self.module().load_snapshot(self.state, self.records)["packages"], good["packages"])

    def test_invalid_upstream_metadata_is_rejected_before_a_snapshot_is_written(self):
        mutations = [{"digest": None}, {"digest": "sha256:" + "b" * 64}, {"size": 101},
                     {"id": True}, {"state": "new"}, {"created_at": "2026-02-02T00:00:00Z"},
                     {"created_at": "invalid"}, {"download_count": True}, {"download_count": -1},
                     {"download_count": 2 ** 53}]
        for change in mutations:
            with self.subTest(change=change):
                original = deepcopy(self.asset()); self.asset().update(change)
                with self.assertRaises(registry.RegistryError): self.collect()
                self.assertFalse(self.state.exists())
                self.asset().clear(); self.asset().update(original)
        response = next(iter(self.responses.values()))
        for key, value in (("draft", True), ("published_at", "2026-02-02T00:00:00Z"), ("published_at", None)):
            original = response[key]; response[key] = value
            with self.subTest(key=key), self.assertRaises(registry.RegistryError): self.collect()
            response[key] = original

    def test_partial_version_history_is_not_presented_as_first_publication(self):
        self.records.append(self.record(version="0.2.0"))
        del self.responses["https://api.github.com/repos/stubbi/asm/releases/tags/v0.1.0"]["assets"]
        with self.assertRaises(registry.RegistryError): self.collect()
        self.assertIsNone(self.package(self.module().load_snapshot(self.state, self.records))["first_published_at"])

    def test_changed_catalog_does_not_reuse_incomplete_snapshot_coverage(self):
        self.collect()
        self.records.append(self.record(version="0.2.0"))
        value = self.module().load_snapshot(self.state, self.records)
        self.assertIsNone(self.package(value)["first_published_at"])
        self.assertTrue(value["stale"])

    def test_corrupt_future_and_symlink_state_are_rejected(self):
        self.state.write_bytes(b"not a SQLite database")
        loaded = self.module().load_snapshot(self.state, self.records)
        self.assertTrue(loaded["stale"])
        self.assertIsNone(self.package(loaded)["downloads_30d"])
        with self.assertRaises(registry.RegistryError): self.collect()
        self.assertEqual(self.state.read_bytes(), b"not a SQLite database")
        self.state.unlink()
        self.collect()
        loaded = self.module().load_snapshot(self.state, self.records, now="2026-01-31T00:00:00Z")
        self.assertTrue(loaded["stale"])
        self.assertIsNone(self.package(loaded)["first_published_at"])
        with self.assertRaises(registry.RegistryError): self.collect("2026-01-31T00:00:00Z")
        outside = self.state.with_name("outside")
        outside.write_bytes(b"leave this file intact")
        self.state.unlink(); self.state.symlink_to(outside)
        self.assertTrue(self.module().load_snapshot(self.state, self.records)["stale"])
        with self.assertRaises(registry.RegistryError): self.collect()
        self.assertEqual(outside.read_bytes(), b"leave this file intact")

    def test_missing_database_cannot_follow_a_sidecar_symlink(self):
        outside = self.state.with_name("outside")
        outside.write_bytes(b"leave this file intact")
        self.state.with_name(self.state.name + "-journal").symlink_to(outside)
        with self.assertRaises(registry.RegistryError): self.collect()
        self.assertFalse(self.state.exists())
        self.assertTrue(self.module().load_snapshot(self.state, self.records)["stale"])
        self.assertEqual(outside.read_bytes(), b"leave this file intact")

    def test_loaded_observations_older_than_one_day_are_stale(self):
        good = self.collect()
        loaded = self.module().load_snapshot(self.state, self.records, now="2026-02-02T00:00:01Z")
        self.assertTrue(loaded["stale"])
        self.assertEqual(loaded["packages"], good["packages"])
        self.assertIn("24 hours", loaded["refresh_error"])

    def test_naive_future_and_invalid_observation_times_are_rejected(self):
        for at in ("2026-02-01T00:00:00", "invalid", "2999-01-01T00:00:00Z", "2026-02-01 00:00:00+00:00"):
            with self.subTest(at=at), self.assertRaises(registry.RegistryError): self.collect(at)

    def test_aggregate_counts_cannot_exceed_the_javascript_safe_integer_limit(self):
        self.asset()["download_count"] = 2 ** 53 - 1
        self.records.append(self.record(version="0.2.0", count=1))
        with self.assertRaises(registry.RegistryError): self.collect()
        value = self.module().load_snapshot(self.state, self.records)
        self.assertIsNone(value["observed_at"])
        self.assertIsNone(self.package(value)["downloads_30d"])

    def test_oversized_api_metadata_and_asset_lists_are_rejected(self):
        response = next(iter(self.responses.values()))
        response["assets"] *= 1001
        with self.assertRaises(registry.RegistryError): self.collect()
        self.assertFalse(self.state.exists())
        response["assets"] = response["assets"][:1]
        response["body"] = "x" * (2 * 1024 * 1024)
        with self.assertRaises(registry.RegistryError): self.collect()
        self.assertFalse(self.state.exists())

    def test_hourly_history_older_than_thirty_five_days_is_pruned(self):
        import sqlite3
        self.asset().update(created_at="2025-12-01T00:00:00Z", download_count=10)
        self.collect("2026-01-01T00:00:00Z")
        self.asset()["download_count"] = 20
        self.collect("2026-02-06T01:00:00Z")
        with closing(sqlite3.connect(self.state)) as connection:
            count = connection.execute("SELECT count(*) FROM observations").fetchone()[0]
        self.assertEqual(count, 1)

    def test_frequent_observations_remain_bounded_within_one_hour(self):
        for second in range(60):
            self.asset()["download_count"] = second
            self.collect(f"2026-02-01T00:00:{second:02d}Z")
        self.assertLess(self.state.stat().st_size, 128 * 1024)
        value = self.module().load_snapshot(self.state, self.records, now="2026-02-01T01:00:00Z")
        self.assertEqual(self.package(value)["downloads_30d"], 59)


if __name__ == "__main__": unittest.main()


class AsmDeliveryProjectionTests(unittest.TestCase):
    def setUp(self):
        self.module = importlib.import_module("discovery")
        self.records = registry.read_records(ROOT / "registry")
        self.publication = self.module.unknown_snapshot(self.records)
        for item in self.publication["packages"]:
            item.update(first_published_at="2026-11-01T00:29:24Z", last_published_at="2026-11-01T19:08:39Z",
                        downloads_30d=9000000, downloads_30d_exact=True, downloads_30d_coverage="complete")

    def observation(self, *, complete=False):
        return {"observed_at": "2026-11-07T08:00:05Z", "coverage_end": "2026-11-07T08:00:00Z",
                "coverage_start": "2026-11-01T00:00:00Z", "collection_started_at": "2026-11-01T00:00:00Z",
                "complete": complete, "stale": False,
                "counts": {"stubbi/math": 2, "stubbi/hello": 0, "stubbi/asm": 1},
                "version_counts": {"stubbi/math@0.4.0": 2}}

    def test_github_counters_never_substitute_for_asm_delivery_events(self):
        value = self.module.delivery_snapshot(self.records, self.publication)
        self.assertEqual(value["source"], "asm-delivery-events")
        self.assertEqual(value["policy"], "asm-deliveries-v1")
        self.assertEqual(value["feeds"]["popular"], [])
        self.assertTrue(all(item["downloads_30d"] is None for item in value["packages"]))
        self.assertEqual(value["feeds"]["new"], ["stubbi/asm", "stubbi/hello", "stubbi/math"])

    def test_first_party_watermark_and_positive_counts_drive_popular(self):
        value = self.module.delivery_snapshot(self.records, self.publication, self.observation())
        self.assertEqual(value["feeds"]["popular"], ["stubbi/math", "stubbi/asm"])
        self.assertEqual(value["observed_at"], "2026-11-07T08:00:00Z")
        self.assertEqual(value["window"]["end"], value["observed_at"])
        self.assertTrue(all(not item["downloads_30d_exact"] for item in value["packages"]))
        self.assertEqual(value["coverage"], {"start": "2026-11-01T00:00:00Z", "end": value["observed_at"], "complete": False})

    def test_yanked_packages_leave_ranking_without_erasing_count_records(self):
        for item in self.records:
            if item["name"] == "stubbi/math": item.update(yanked=True, yank_reason="Fixture withdrawal.")
        value = self.module.delivery_snapshot(self.records, self.publication, self.observation())
        self.assertNotIn("stubbi/math", value["feeds"]["popular"])
        self.assertEqual(next(item for item in value["packages"] if item["name"] == "stubbi/math")["downloads_30d"], 2)

    def test_package_and_version_counts_use_the_same_asm_window(self):
        value = self.module.delivery_counts(self.records, self.observation())
        self.assertEqual(value["source"], "asm-delivery-events")
        self.assertEqual(value["packages"]["stubbi/math"]["total"], 2)
        self.assertEqual(value["packages"]["stubbi/math"]["versions"]["0.4.0"], 2)

    def retained_observation(self):
        value = self.observation(complete=True)
        value.update(retained_counts={name: 0 for name in {record["name"] for record in self.records}},
                     retained_version_counts={record["name"] + "@" + record["version"]: 0 for record in self.records},
                     retained_complete=False, retained_coverage_start="2026-11-02T00:00:00Z")
        value["retained_counts"]["stubbi/math"] = 7
        value["retained_version_counts"]["stubbi/math@0.1.0"] = 5
        value["retained_version_counts"]["stubbi/math@0.4.0"] = 2
        return value

    def test_retained_projection_uses_own_cumulative_counts_and_independent_coverage(self):
        value = self.module.retained_counts(self.records, self.retained_observation())
        self.assertEqual(value["source"], "asm-delivery-events")
        self.assertEqual(value["policy"], "asm-deliveries-v1")
        self.assertEqual(value["scope"], "since-collection")
        self.assertEqual(value["observed_at"], "2026-11-07T08:00:00Z")
        self.assertEqual(value["window"], {"start": "2026-11-01T00:00:00Z", "end": value["observed_at"], "basis": "since-collection"})
        self.assertEqual(value["packages"]["stubbi/math"]["total"], 7)
        self.assertEqual(value["packages"]["stubbi/math"]["versions"]["0.1.0"], 5)
        self.assertEqual(value["total"], 7)
        self.assertFalse(value["complete"])
        self.assertFalse(value["coverage"]["complete"])
        self.assertFalse(value["stale"])

    def test_retained_projection_keeps_unknown_distinct_from_observed_zero_and_stale(self):
        unknown = self.module.retained_counts(self.records, None)
        self.assertIsNone(unknown["total"])
        self.assertIsNone(unknown["packages"]["stubbi/math"]["total"])
        self.assertTrue(unknown["stale"])
        observation = self.retained_observation()
        observation.update(stale=True, retained_complete=True,
                           retained_coverage_start=observation["collection_started_at"])
        value = self.module.retained_counts(self.records, observation)
        self.assertEqual(value["packages"]["stubbi/hello"]["total"], 0)
        self.assertTrue(value["complete"])
        self.assertTrue(value["stale"])
        # Old projections cannot relabel a rolling30-day value as cumulative.
        unavailable = self.module.retained_counts(self.records, self.observation())
        self.assertIsNone(unavailable["total"])

    def test_retained_projection_rejects_inconsistent_counts_scope_and_coverage(self):
        for change in ({"retained_counts": {"stubbi/math": 7}}, {"retained_complete": "yes"},
                       {"retained_coverage_start": "2026-11-08T00:00:00Z"},
                       {"retained_complete": True}, {"stale": 0}):
            observation = self.retained_observation()
            observation.update(change)
            with self.subTest(change=change), self.assertRaises(registry.RegistryError):
                self.module.retained_counts(self.records, observation)
        for count in (-1, True, 2 ** 53, 6):
            observation = self.retained_observation()
            observation["retained_counts"]["stubbi/math"] = count
            with self.subTest(count=count), self.assertRaises(registry.RegistryError):
                self.module.retained_counts(self.records, observation)

    def activity_observation(self):
        return {"observed_at": "2026-01-31T06:00:05Z", "coverage_end": "2026-01-31T06:00:00Z",
                "coverage_start": "2026-01-01T00:00:00Z", "collection_started_at": "2026-01-01T00:00:00Z",
                "complete": True, "stale": False, "counts": {"stubbi/math": 4},
                "version_counts": {"stubbi/math@0.1.0": 3, "stubbi/math@0.4.0": 1},
                "daily_counts": [{"date": "2026-01-01", "name": "stubbi/math", "version": "0.1.0", "count": 1},
                                 {"date": "2026-01-02", "name": "stubbi/math", "version": "0.4.0", "count": 1},
                                 {"date": "2026-01-31", "name": "stubbi/math", "version": "0.1.0", "count": 2}],
                "coverage_intervals": [{"start": "2026-01-01T06:00:00Z", "end": "2026-01-31T06:00:00Z"}]}

    def test_activity_unknown_history_has_no_fabricated_dates_or_daily_zeroes(self):
        value = self.module.delivery_activity(self.records, "stubbi/math", None)
        self.assertEqual(value["source"], "asm-delivery-events")
        self.assertEqual(value["policy"], "asm-deliveries-v1")
        self.assertEqual(value["name"], "stubbi/math")
        self.assertIsNone(value["version"])
        self.assertIsNone(value["total"])
        self.assertIsNone(value["window"]["start"])
        self.assertIsNone(value["observed_at"])
        self.assertEqual(value["days"], [])
        self.assertFalse(value["complete"])
        self.assertTrue(value["stale"])

    def test_registry_activity_aggregates_accepted_packages_at_one_cutoff_without_identity_fields(self):
        observation = self.activity_observation()
        observation["counts"]["stubbi/hello"] = 2
        observation["daily_counts"].append({"date": "2026-01-02", "name": "stubbi/hello", "version": "0.4.0", "count": 2})
        value = self.module.delivery_activity(self.records, None, observation)
        self.assertEqual(value["scope"], "registry")
        self.assertNotIn("name", value)
        self.assertNotIn("version", value)
        self.assertEqual(value["total"], 6)
        self.assertEqual(value["observed_at"], "2026-01-31T06:00:00Z")
        self.assertEqual(sum(day["count"] or 0 for day in value["days"]), 6)
        self.assertEqual(value["days"][1]["count"], 3)
        self.assertTrue(value["complete"])

    def test_registry_activity_unknown_gaps_and_invalid_version_scope_remain_explicit(self):
        unknown = self.module.delivery_activity(self.records, None, None)
        self.assertEqual(unknown["scope"], "registry")
        self.assertIsNone(unknown["total"])
        self.assertEqual(unknown["days"], [])
        with self.assertRaises(registry.RegistryError): self.module.delivery_activity(self.records, None, None, version="0.4.0")
        observation = self.activity_observation()
        observation.update(complete=False, stale=True,
                           coverage_intervals=[{"start": "2026-01-30T00:00:00Z", "end": "2026-01-31T06:00:00Z"}])
        value = self.module.delivery_activity(self.records, None, observation)
        self.assertTrue(value["stale"])
        self.assertFalse(value["complete"])
        self.assertEqual(value["days"][0]["coverage"], "partial")
        self.assertIsNone(value["days"][2]["count"])
        observation["counts"].update({"stubbi/math": 2 ** 53 - 1, "stubbi/hello": 1})
        with self.assertRaises(registry.RegistryError): self.module.delivery_activity(self.records, None, observation)

    def test_activity_uses_31_clipped_utc_bins_and_reconciles_package_and_exact_version_totals(self):
        observation = self.activity_observation()
        value = self.module.delivery_activity(self.records, "stubbi/math", observation)
        self.assertEqual(value["observed_at"], "2026-01-31T06:00:00Z")
        self.assertEqual(value["window"], {"days": 30, "start": "2026-01-01T06:00:00Z",
                         "end": "2026-01-31T06:00:00Z", "basis": "rolling-observation"})
        self.assertEqual(len(value["days"]), 31)
        self.assertEqual(value["days"][0], {"date": "2026-01-01", "start": "2026-01-01T06:00:00Z",
                         "end": "2026-01-02T00:00:00Z", "count": 1, "coverage": "complete", "observed_seconds": 64800})
        self.assertEqual(value["days"][-1], {"date": "2026-01-31", "start": "2026-01-31T00:00:00Z",
                         "end": "2026-01-31T06:00:00Z", "count": 2, "coverage": "complete", "observed_seconds": 21600})
        self.assertEqual(value["days"][2]["count"], 0)
        self.assertEqual(value["total"], 4)
        self.assertEqual(sum(day["count"] for day in value["days"]), value["total"])
        exact = self.module.delivery_activity(self.records, "stubbi/math", observation, version="0.1.0")
        self.assertEqual(exact["version"], "0.1.0")
        self.assertEqual(exact["total"], 3)
        self.assertEqual(exact["days"][1]["count"], 0)
        self.assertEqual(sum(day["count"] for day in exact["days"]), 3)

    def test_activity_distinguishes_missing_partial_zero_and_gap_events(self):
        observation = self.activity_observation()
        observation.update(complete=False, stale=True, collection_started_at="2026-01-02T00:00:00Z",
                           coverage_start="2026-01-31T05:59:00Z")
        observation["coverage_intervals"] = [
            {"start": "2026-01-02T00:00:00Z", "end": "2026-01-02T12:00:00Z"},
            {"start": "2026-01-02T12:00:00Z", "end": "2026-01-03T00:00:00Z"},
            {"start": "2026-01-04T00:00:00Z", "end": "2026-01-04T00:01:00Z"},
            {"start": "2026-01-31T05:59:00Z", "end": "2026-01-31T06:00:00Z"}]
        value = self.module.delivery_activity(self.records, "stubbi/math", observation)
        by_date = {day["date"]: day for day in value["days"]}
        self.assertEqual(by_date["2026-01-01"]["count"], 1, "Retained events remain an observed minimum without complete coverage.")
        self.assertEqual(by_date["2026-01-01"]["coverage"], "partial")
        self.assertEqual(by_date["2026-01-02"]["coverage"], "complete")
        self.assertIsNone(by_date["2026-01-03"]["count"])
        self.assertEqual(by_date["2026-01-03"]["coverage"], "unavailable")
        self.assertEqual(by_date["2026-01-04"]["count"], 0)
        self.assertEqual(by_date["2026-01-04"]["coverage"], "partial")
        self.assertEqual(by_date["2026-01-04"]["observed_seconds"], 60)
        self.assertTrue(value["stale"])
        self.assertFalse(value["complete"])
        self.assertEqual(sum(day["count"] or 0 for day in value["days"]), value["total"])

    def test_activity_midnight_cutoff_keeps_the_event_on_the_final_utc_date(self):
        observation = self.activity_observation()
        observation.update(coverage_end="2026-01-31T00:00:00Z", complete=False,
                           coverage_intervals=[{"start": "2026-01-30T23:59:00Z", "end": "2026-01-31T00:00:00Z"}])
        value = self.module.delivery_activity(self.records, "stubbi/math", observation)
        self.assertEqual(len(value["days"]), 31)
        self.assertEqual(value["days"][-1]["start"], "2026-01-31T00:00:00Z")
        self.assertEqual(value["days"][-1]["end"], "2026-01-31T00:00:00Z")
        self.assertEqual(value["days"][-1]["count"], 2)
        self.assertEqual(value["days"][-1]["coverage"], "partial")

    def test_activity_rejects_unknown_selection_and_inconsistent_daily_totals(self):
        for name, version in (("other/math", None), ("stubbi/math", "9.0.0"), ("../math", None)):
            with self.subTest(name=name, version=version), self.assertRaises(registry.RegistryError):
                self.module.delivery_activity(self.records, name, None, version=version)
        observation = self.activity_observation()
        observation["daily_counts"][0]["count"] = 100
        with self.assertRaises(registry.RegistryError):
            self.module.delivery_activity(self.records, "stubbi/math", observation)

    def test_activity_empty_collection_keeps_unobserved_null_and_partial_covered_zero(self):
        observation = self.activity_observation()
        observation.update(counts={}, version_counts={}, daily_counts=[], complete=False,
                           coverage_intervals=[{"start": "2026-01-31T05:59:59.500000Z", "end": "2026-01-31T06:00:00Z"}])
        value = self.module.delivery_activity(self.records, "stubbi/math", observation)
        self.assertEqual(value["total"], 0)
        self.assertTrue(all(day["count"] is None for day in value["days"][:-1]))
        self.assertEqual(value["days"][-1]["count"], 0)
        self.assertEqual(value["days"][-1]["coverage"], "partial")
        self.assertEqual(value["days"][-1]["observed_seconds"], 0.5)
        observation["coverage_intervals"] = [{"start": "2026-01-31T06:00:00Z", "end": "2026-01-31T06:00:00Z"}]
        empty = self.module.delivery_activity(self.records, "stubbi/math", observation)
        self.assertTrue(all(day["count"] is None for day in empty["days"]))

    def test_activity_yanked_history_retains_exact_counts_without_borrowing_a_newer_version(self):
        for record in self.records:
            if record["name"] == "stubbi/math" and record["version"] == "0.1.0":
                record.update(yanked=True, yank_reason="Historical fixture.")
        observation = self.activity_observation()
        old = self.module.delivery_activity(self.records, "stubbi/math", observation, version="0.1.0")
        latest = self.module.delivery_activity(self.records, "stubbi/math", observation, version="0.4.0")
        self.assertEqual(old["total"], 3)
        self.assertEqual(latest["total"], 1)
        self.assertEqual(latest["days"][-1]["count"], 0)

    def test_activity_rejects_ambiguous_foreign_and_outside_window_daily_rows(self):
        from copy import deepcopy
        fixture = self.activity_observation()
        changes = [{"count": True}, {"count": -1}, {"count": 0}, {"count": 2 ** 53},
                   {"name": "foreign/math"}, {"version": "8.0.0"}, {"date": "2026-02-30"},
                   {"date": "2025-12-31"}, {"date": "2026-02-01"}, {"extra": "field"}]
        for change in changes:
            observation = deepcopy(fixture)
            observation["daily_counts"][0].update(change)
            with self.subTest(change=change), self.assertRaises(registry.RegistryError):
                self.module.delivery_activity(self.records, "stubbi/math", observation)
        duplicate = deepcopy(fixture)
        duplicate["daily_counts"].append(dict(duplicate["daily_counts"][0]))
        with self.assertRaises(registry.RegistryError): self.module.delivery_activity(self.records, "stubbi/math", duplicate)
        for interval in ({"start": "2026-01-31T06:00:01Z", "end": "2026-01-31T06:00:00Z"},
                         {"start": "2026-01-31T06:00:00Z", "end": "2026-01-31T06:00:01Z"}):
            observation = deepcopy(fixture)
            observation["coverage_intervals"] = [interval]
            with self.subTest(interval=interval), self.assertRaises(registry.RegistryError):
                self.module.delivery_activity(self.records, "stubbi/math", observation)
