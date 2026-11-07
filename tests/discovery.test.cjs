/* Discovery snapshot boundary checks. SPDX-License-Identifier: AGPL-3.0-or-later */
"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { normalizeDiscovery, rejoinDiscovery, formatDiscoveryCount, formatDiscoveryDate, discoveryFreshness, discoveryEmptyMessage, discoveryCoverageMessage, discoveryFeedDate } = require("../site/app.js");

const NOW = Date.parse("2026-11-07T12:00:00Z");

function catalog() {
  return ["alpha", "beta"].map((name) => ({
    name: `owner/${name}`, summary: `${name} purpose`, latest: "0.4.0", targets: ["historic-target", "x86_64-linux"],
    versions: [{ version: "0.4.0", yanked: false, artifacts: [{ kind: "source", target: "x86_64-linux",
      sha256: "a".repeat(64), url: `https://github.com/owner/${name}/releases/download/v0.4.0/source.tar.gz` }] }]
  }));
}

function snapshot() {
  return {
    schema: 1, policy: "asm-deliveries-v1", source: "asm-delivery-events",
    observed_at: "2026-11-07T10:00:00Z", stale: false, refresh_error: null,
    collection_started_at: "2026-10-01T00:00:00Z",
    coverage: { start: "2026-10-08T10:00:00Z", end: "2026-11-07T10:00:00Z", complete: true },
    window: { days: 30, start: "2026-10-08T10:00:00Z", end: "2026-11-07T10:00:00Z", basis: "rolling-observation" },
    packages: [
      { name: "owner/alpha", first_published_at: "2026-11-01T00:00:00Z", last_published_at: "2026-11-06T00:00:00Z",
        publication_source: "github-release", downloads_30d: 12, downloads_30d_exact: true, downloads_30d_coverage: "complete" },
      { name: "owner/beta", first_published_at: "2026-11-03T00:00:00Z", last_published_at: "2026-11-05T00:00:00Z",
        publication_source: "github-release", downloads_30d: 30, downloads_30d_exact: true, downloads_30d_coverage: "complete" }
    ],
    feeds: { popular: ["owner/beta", "owner/alpha"], new: ["owner/beta", "owner/alpha"], updated: ["owner/alpha", "owner/beta"] }
  };
}

test("discovery preserves provider order and joins exact current catalog metadata", () => {
  const data = normalizeDiscovery(snapshot(), catalog(), NOW);
  assert.deepEqual(data.feeds.popular.map((row) => row.name), ["owner/beta", "owner/alpha"]);
  assert.deepEqual(data.feeds.new.map((row) => row.name), ["owner/beta", "owner/alpha"]);
  assert.equal(data.feeds.popular[0].package.summary, "beta purpose");
  assert.equal(data.feeds.popular[0].package.latest, "0.4.0");
  assert.deepEqual(data.feeds.popular[0].targets, ["x86_64-linux"]);
  assert.equal(data.feeds.popular[0].downloads_30d_exact, true);
  assert.equal(data.collection_started_at, "2026-10-01T00:00:00.000Z");
  assert.equal(data.coverage.complete, true);
});

test("New and Recently updated use distinct declared publication dates without a fallback", () => {
  const row = normalizeDiscovery(snapshot(), catalog(), NOW).feeds.updated[0];
  assert.equal(discoveryFeedDate(row, "new"), "2026-11-01T00:00:00.000Z");
  assert.equal(discoveryFeedDate(row, "updated"), "2026-11-06T00:00:00.000Z");
  assert.equal(discoveryFeedDate({ ...row, last_published_at: null }, "updated"), null);
  assert.equal(discoveryFeedDate(row, "popular"), null);
});

test("an empty Updated feed distinguishes missing latest dates from no update activity", () => {
  const data = snapshot();
  data.feeds.updated = [];
  data.feeds.new = [];
  assert.match(discoveryEmptyMessage(normalizeDiscovery(data, catalog(), NOW), "updated"), /No updated packages/);
  for (const row of data.packages) row.last_published_at = null;
  assert.match(discoveryEmptyMessage(normalizeDiscovery(data, catalog(), NOW), "updated"), /Latest GitHub release dates are unavailable/);
  assert.match(discoveryEmptyMessage(normalizeDiscovery(data, catalog(), NOW), "new"), /No new packages/);
});

test("GitHub ranking snapshots cannot replace Asm delivery observations", () => {
  const data = snapshot();
  data.policy = "github-release-assets-v1";
  data.source = "github-release-assets";
  assert.throws(() => normalizeDiscovery(data, catalog(), NOW), { name: "RangeError", message: /discovery/i });
});

test("missing observations stay distinct from exact zero and lower bounds", () => {
  assert.equal(formatDiscoveryCount({ downloads_30d: null, downloads_30d_exact: false }), "Downloads unavailable");
  assert.equal(formatDiscoveryCount({ downloads_30d: 0, downloads_30d_exact: true }), "0 downloads");
  assert.equal(formatDiscoveryCount({ downloads_30d: 1, downloads_30d_exact: true }), "1 download");
  assert.equal(formatDiscoveryCount({ downloads_30d: 1200, downloads_30d_exact: false }), "≥ 1.2k downloads");
  assert.equal(formatDiscoveryCount({ downloads_30d: 1250, downloads_30d_exact: false }), "≥ 1.2k downloads");
  assert.equal(formatDiscoveryCount({ downloads_30d: 1250, downloads_30d_exact: false }, { exact: true }), "≥ 1,250 downloads");
  assert.equal(formatDiscoveryCount({ downloads_30d: 999950, downloads_30d_exact: true }), "1000k downloads");
  assert.equal(formatDiscoveryCount({ downloads_30d: 999950, downloads_30d_exact: false }), "≥ 999k downloads");
  assert.equal(formatDiscoveryCount({ downloads_30d: 4 }), "Downloads unavailable");
  const data = snapshot();
  data.packages[0].downloads_30d = 0;
  data.feeds.popular = ["owner/beta"];
  assert.equal(normalizeDiscovery(data, catalog(), NOW).packages[0].downloads_30d, 0);
  data.packages[0].downloads_30d = null;
  data.packages[0].downloads_30d_exact = false;
  data.packages[0].downloads_30d_coverage = "unavailable";
  data.feeds.popular = ["owner/beta"];
  assert.equal(normalizeDiscovery(data, catalog(), NOW).packages[0].downloads_30d, null);
});

test("unavailable coverage does not become an empty successful popularity observation", () => {
  const data = snapshot();
  data.observed_at = null;
  data.collection_started_at = null;
  data.coverage = { start: null, end: null, complete: false };
  data.window.start = null;
  data.window.end = null;
  data.feeds.popular = [];
  for (const row of data.packages) {
    row.downloads_30d = null;
    row.downloads_30d_exact = false;
    row.downloads_30d_coverage = "unavailable";
  }
  assert.equal(normalizeDiscovery(data, catalog(), NOW).observed_at, null);
  assert.match(discoveryFreshness(data), /Observation time unavailable/);
  assert.match(discoveryEmptyMessage(normalizeDiscovery(data, catalog(), NOW), "popular"), /unavailable.*not started/i);
});

test("publication dates use their own observation after a stale delivery cutoff", () => {
  const data = snapshot();
  data.publication_observed_at = "2026-11-07T10:00:00Z";
  data.observed_at = "2026-11-04T10:00:00Z";
  data.window.start = data.coverage.start = "2026-10-05T10:00:00Z";
  data.window.end = data.coverage.end = data.observed_at;
  const normalized = normalizeDiscovery(data, catalog(), NOW);
  assert.equal(normalized.publication_observed_at, "2026-11-07T10:00:00.000Z");
  assert.equal(normalized.feeds.updated[0].last_published_at, "2026-11-06T00:00:00.000Z");
  assert.equal(normalized.observed_at, "2026-11-04T10:00:00.000Z");
  data.publication_observed_at = null;
  assert.equal(normalizeDiscovery(data, catalog(), NOW).publication_observed_at, null);
  data.publication_observed_at = "2026-11-02T00:00:00Z";
  assert.throws(() => normalizeDiscovery(data, catalog(), NOW), { name: "RangeError", message: /discovery/i });
});

test("New retains publication facts before delivery collection has been initialized", () => {
  const data = snapshot();
  data.publication_observed_at = "2026-11-07T10:00:00Z";
  data.observed_at = data.collection_started_at = data.window.start = data.window.end = null;
  data.coverage = { start: null, end: null, complete: false };
  data.feeds.popular = [];
  for (const row of data.packages) {
    row.downloads_30d = null;
    row.downloads_30d_exact = false;
    row.downloads_30d_coverage = "unavailable";
  }
  const normalized = normalizeDiscovery(data, catalog(), NOW);
  assert.equal(normalized.publication_observed_at, "2026-11-07T10:00:00.000Z");
  assert.deepEqual(normalized.feeds.new.map((row) => row.name), ["owner/beta", "owner/alpha"]);
  assert.equal(normalized.packages[0].downloads_30d, null);
  assert.deepEqual(normalized.feeds.popular, []);
  for (const invalid of ["2027-01-01T00:00:00Z", "2026-02-30T00:00:00Z"]) {
    data.publication_observed_at = invalid;
    assert.throws(() => normalizeDiscovery(data, catalog(), NOW), { name: "RangeError", message: /discovery/i });
  }
});

test("initial collection keeps observed zero distinct from an uninitialized counter", () => {
  const data = snapshot();
  data.collection_started_at = "2026-11-07T09:00:00Z";
  data.coverage = { start: "2026-11-07T09:00:00Z", end: data.observed_at, complete: false };
  data.feeds.popular = [];
  for (const row of data.packages) {
    row.downloads_30d = 0;
    row.downloads_30d_exact = false;
    row.downloads_30d_coverage = "lower-bound";
  }
  const normalized = normalizeDiscovery(data, catalog(), NOW);
  assert.equal(normalized.packages[0].downloads_30d, 0);
  assert.match(discoveryEmptyMessage(normalized, "popular"), /Collecting downloads since 7 Nov 2026.*No downloads.*recorded/i);
  assert.match(discoveryCoverageMessage(normalized), /incomplete/i);
});

test("a retained coverage gap cannot claim exact counts even when outer bounds cover the window", () => {
  const data = snapshot();
  data.coverage.complete = false;
  for (const row of data.packages) {
    row.downloads_30d_exact = false;
    row.downloads_30d_coverage = "lower-bound";
  }
  const normalized = normalizeDiscovery(data, catalog(), NOW);
  assert.equal(formatDiscoveryCount(normalized.feeds.popular[0]), "≥ 30 downloads");
  assert.match(discoveryCoverageMessage(normalized), /incomplete/i);
  data.packages[0].downloads_30d_exact = true;
  data.packages[0].downloads_30d_coverage = "complete";
  assert.throws(() => normalizeDiscovery(data, catalog(), NOW), { name: "RangeError", message: /discovery/i });
});

test("publication dates use UTC and invalid calendar values remain unavailable", () => {
  assert.equal(formatDiscoveryDate("2026-11-07T00:05:00Z"), "7 Nov 2026");
  for (const value of [null, "", "tomorrow", "2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-11-07"]) {
    assert.equal(formatDiscoveryDate(value), "Publication date unavailable");
  }
  assert.match(discoveryFreshness({ observed_at: "2026-11-07T10:00:00Z", stale: true, refresh_error: "Network error" }), /Stale snapshot/);
  assert.match(discoveryFreshness({ observed_at: "2026-11-07T10:00:00Z", stale: true, refresh_error: "Network error" }), /refresh failed/);
  assert.match(discoveryFreshness({ observed_at: null, stale: true, refresh_error: "Network error" }), /Stale snapshot.*Observation time unavailable.*refresh failed/);
});

test("static discovery visibly ages after the documented 24-hour freshness limit", () => {
  const data = snapshot();
  const observed = Date.parse(data.observed_at);
  const day = 24 * 60 * 60 * 1000;
  assert.equal(normalizeDiscovery(data, catalog(), observed + day).stale, false);
  const expired = normalizeDiscovery(data, catalog(), observed + day + 1);
  assert.equal(expired.stale, true);
  assert.match(discoveryFreshness(expired), /Stale snapshot/);
  assert.equal(expired.refresh_error, null);
  data.stale = true;
  assert.equal(normalizeDiscovery(data, catalog(), NOW).stale, true);
});

test("empty discovery distinguishes complete zero activity, incomplete observations, and unknown dates", () => {
  const data = snapshot();
  data.feeds.popular = [];
  for (const row of data.packages) {
    row.downloads_30d = 0;
    row.downloads_30d_exact = true;
    row.downloads_30d_coverage = "complete";
  }
  assert.match(discoveryEmptyMessage(normalizeDiscovery(data, catalog(), NOW), "popular"), /No downloads were observed/);
  data.coverage.complete = false;
  for (const row of data.packages) {
    row.downloads_30d_exact = false;
    row.downloads_30d_coverage = "lower-bound";
  }
  assert.match(discoveryEmptyMessage(normalizeDiscovery(data, catalog(), NOW), "popular"), /Collecting downloads.*No downloads/i);
  for (const row of data.packages) {
    row.downloads_30d = null;
    row.downloads_30d_exact = false;
    row.downloads_30d_coverage = "unavailable";
    row.first_published_at = null;
  }
  data.feeds.new = [];
  assert.match(discoveryEmptyMessage(normalizeDiscovery(data, catalog(), NOW), "popular"), /unavailable/);
  assert.match(discoveryEmptyMessage(normalizeDiscovery(data, catalog(), NOW), "new"), /dates are unavailable/);
  assert.match(discoveryEmptyMessage(null, "popular"), /unavailable/);
});

test("unsupported, ambiguous, future, and inconsistent discovery facts are rejected", () => {
  const mutations = [
    (data) => { data.schema = 2; },
    (data) => { data.policy = "lifetime-downloads"; },
    (data) => { data.source = "other-service"; },
    (data) => { data.stale = "false"; },
    (data) => { data.observed_at = "2027-01-01T00:00:00Z"; },
    (data) => { data.observed_at = "2026-02-30T00:00:00Z"; },
    (data) => { data.packages[0].first_published_at = "2027-01-01T00:00:00Z"; },
    (data) => { data.packages[0].first_published_at = "2026-11-07T00:00:00Z"; },
    (data) => { data.packages[0].publication_source = "git-import"; },
    (data) => { data.packages[0].downloads_30d = -1; },
    (data) => { data.packages[0].downloads_30d = Number.MAX_SAFE_INTEGER + 1; },
    (data) => { data.packages[0].downloads_30d = 1.5; },
    (data) => { data.packages[0].downloads_30d_exact = false; },
    (data) => { data.coverage.complete = false; },
    (data) => { data.collection_started_at = null; },
    (data) => { data.collection_started_at = "2026-11-08T00:00:00Z"; },
    (data) => { data.coverage.start = "2026-10-09T00:00:00Z"; },
    (data) => { data.coverage.start = null; },
    (data) => { data.coverage.end = "2026-11-07T09:00:00Z"; },
    (data) => { data.coverage.complete = "true"; },
    (data) => { data.window.days = 29; },
    (data) => { data.window.start = null; },
    (data) => { data.window.end = "2026-11-09T00:00:00Z"; },
    (data) => { data.window.start = "2026-10-08T09:00:00Z"; data.window.end = "2026-11-07T09:00:00Z"; },
    (data) => { data.packages[0].downloads_30d = 0; },
    (data) => { data.feeds.popular.push("owner/alpha"); },
    (data) => { data.feeds.new = ["owner/unknown"]; },
    (data) => { data.packages.push({ ...data.packages[0] }); },
    (data) => { data.packages[0].name = "../owner/alpha"; },
    (data) => { data.packages[0].first_published_at = null; }
  ];
  for (const mutate of mutations) {
    const data = snapshot();
    mutate(data);
    assert.throws(() => normalizeDiscovery(data, catalog(), NOW), { name: "RangeError", message: /discovery/i });
  }
});

test("feed membership requires an accepted active release and valid artifacts", () => {
  for (const mutate of [
    (pkg) => { pkg.latest = null; },
    (pkg) => { pkg.latest = "9.0.0"; },
    (pkg) => { pkg.versions[0].yanked = true; },
    (pkg) => { pkg.versions[0].artifacts = []; },
    (pkg) => { pkg.versions[0].artifacts[0].url = "javascript:alert(1)"; }
  ]) {
    const packages = catalog();
    mutate(packages[0]);
    assert.throws(() => normalizeDiscovery(snapshot(), packages, NOW), { name: "RangeError", message: /discovery/i });
  }
});

test("retained observations rejoin current metadata and become unavailable after a catalog yank", () => {
  const previous = normalizeDiscovery(snapshot(), catalog(), NOW);
  const current = catalog();
  current[0].summary = "A revised purpose";
  current[0].latest = "0.5.0";
  current[0].versions.push({ ...current[0].versions[0], version: "0.5.0" });
  const retained = rejoinDiscovery(previous, current, NOW);
  assert.equal(retained.feeds.popular[1].package.summary, "A revised purpose");
  assert.equal(retained.feeds.popular[1].package.latest, "0.5.0");
  assert.equal(retained.feeds.popular[1].downloads_30d, 12);
  assert.equal(retained.observed_at, previous.observed_at);
  current[0].latest = null;
  current[0].versions.forEach((version) => { version.yanked = true; });
  assert.equal(rejoinDiscovery(previous, current, NOW), null);
  assert.equal(rejoinDiscovery(previous, catalog().slice(1), NOW), null);
});

test("categories use explicit unique metadata and canonical native routes", () => {
  const data = snapshot();
  assert.deepEqual(normalizeDiscovery(data, catalog(), NOW).categories, []);
  data.categories = [{ id: "developer-tools", name: "Developer tools", packages: ["owner/alpha"] }];
  assert.equal(normalizeDiscovery(data, catalog(), NOW).categories[0].id, "developer-tools");
  for (const category of [
    { id: "../tools", name: "Tools", packages: ["owner/alpha"] },
    { id: "tools", name: "", packages: ["owner/alpha"] },
    { id: "tools", name: "Tools", packages: ["owner/unknown"] },
    { id: "tools", name: "Tools", packages: ["owner/alpha", "owner/alpha"] }
  ]) {
    data.categories = [category];
    assert.throws(() => normalizeDiscovery(data, catalog(), NOW), { name: "RangeError", message: /discovery/i });
  }
  const valid = { id: "tools", name: "Tools", packages: ["owner/alpha"] };
  data.categories = [valid, valid];
  assert.throws(() => normalizeDiscovery(data, catalog(), NOW), { name: "RangeError", message: /discovery/i });
});
