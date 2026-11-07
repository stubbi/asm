"use strict";

// Run with: node --test tests/site.test.cjs
// No browser or npm dependency is required for these metadata-boundary checks.
const assert = require("node:assert/strict");
const test = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { mathSourcePath } = require("../site/app.js");
const { githubURL, normalizeIndex, catalogStats, searchResultMetadata, findPackages, packageStatus, formatBytes, validArtifact, evidenceText, versionLicenseText, formatDownloadCount, compactCount, exactCount, architectureGroups } = require("../site/app.js");
const countCases = require("./count-format-cases.json");

test("compact counts agree with shared integer rounding, suffix, and lower-bound cases", () => {
  for (const row of countCases.valid) {
    const lowerBound = row.lower_bound || false;
    assert.equal(compactCount(row.value, { lowerBound }), row.compact, JSON.stringify(row));
    assert.equal(exactCount(row.value), row.exact, JSON.stringify(row));
  }
});

test("invalid or unknown counts never become zero or an abbreviated statistic", () => {
  for (const value of [...countCases.invalid, NaN, Infinity, -Infinity, 1n]) {
    assert.equal(compactCount(value), null, String(value));
    assert.equal(exactCount(value), null, String(value));
  }
  for (const options of [null, true, "counts", { lowerBound: 1 }]) {
    assert.equal(compactCount(1200, options), null);
  }
});

test("an accepted numeric zero has one canonical visible and exact representation", () => {
  assert.equal(compactCount(-0), "0");
  assert.equal(exactCount(-0), "0");
});

test("large result counts have a compact label and an exact accessibility equivalent", () => {
  assert.match(packageStatus(2000, 1250), /^1\.3k packages shown/);
  assert.match(packageStatus(2000, 1250, { exact: true }), /^1,250 packages shown/);
});

test("all visible counts use one GitHub convention with its precision and unit boundaries", () => {
  assert.equal(compactCount(1200), "1.2k");
  assert.equal(compactCount(121580), "122k");
  assert.equal(compactCount(999950), "1000k");
  assert.equal(compactCount(1250000), "1.3M");
  assert.equal(compactCount(121580000), "122M");
});

function record(name, target) {
  return { name, summary: "A source package", latest: "0.1.0", targets: [target],
    versions: [{ version: "0.1.0", yanked: false, artifacts: [artifact("source", target)] }] };
}

function artifact(kind, target) {
  const suffix = kind === "source" ? ".tar.gz" : "";
  return { kind, target, sha256: "a".repeat(64), url: `https://github.com/owner/package/releases/download/v0.1.0/package-${target}${suffix}` };
}

function packageWithArtifacts(name, artifacts) {
  const pkg = record(name, "x86_64-linux");
  pkg.targets = [...new Set(artifacts.filter(Boolean).map((item) => item.target))];
  pkg.versions[0] = { version: pkg.latest, yanked: false, artifacts };
  return pkg;
}

test("download links reject executable schemes, credentials, misleading hosts, and non-release paths", () => {
  for (const url of [
    "javascript:alert(1)",
    "http://github.com/stubbi/asm/releases/download/v1/asm",
    "https://github.com.evil.example/stubbi/asm/releases/download/v1/asm",
    "https://user:secret@github.com/stubbi/asm/releases/download/v1/asm",
    "https://github.com/stubbi/asm/blob/main/cli/asm.s",
    "https://github.com/stubbi/asm/releases/download/v1/asm?unexpected=value",
    "https://github.com/stubbi/asm/releases/download/v1/asm#fragment",
    "https://github.com/stubbi/asm/releases/download/v1/asm%2fextra",
    "https://github.com/stubbi/asm/releases/download/v1/asm';echo-owned",
    "https://github.com:8443/stubbi/asm/releases/download/v1/asm"
  ]) assert.equal(githubURL(url, true), null);
  const good = "https://github.com/stubbi/asm/releases/download/v0.1.0/asm-linux-x86_64";
  assert.equal(githubURL(good, true), good);
});

test("unsupported index schemas do not produce a plausible empty catalog", () => {
  for (const value of [null, {}, { schema: 2, packages: [] }, { schema: 1, packages: {} }]) {
    assert.throws(() => normalizeIndex(value));
  }
});

test("malformed records are excluded and valid targets remain exact", () => {
  const pkg = record("owner/alpha", "x86_64-linux");
  pkg.targets.push("x86_64-linux");
  const records = normalizeIndex({ schema: 1, packages: [null, {}, { ...pkg, targets: [null] }, pkg] });
  assert.equal(records.length, 1);
  assert.deepEqual(records[0].targets, ["x86_64-linux"]);
});

test("packages remain visible when every release has been yanked", () => {
  const pkg = record("owner/alpha", "x86_64-linux");
  pkg.latest = null;
  pkg.versions[0].yanked = true;
  assert.equal(normalizeIndex({ schema: 1, packages: [pkg] }).length, 1);
});

test("catalog totals include retained yanked releases and their explicit artifact targets", () => {
  const alpha = packageWithArtifacts("owner/alpha", [artifact("source", "x86_64-linux"), artifact("executable", "x86_64-linux")]);
  alpha.versions.push({ version: "0.0.1", yanked: true, artifacts: [artifact("source", "aarch64-linux")] });
  alpha.targets = ["an-unused-package-target"];
  const beta = packageWithArtifacts("owner/beta", [artifact("source", "x86_64-linux")]);
  beta.latest = null;
  beta.versions[0].yanked = true;
  assert.deepEqual(catalogStats([alpha, beta]), { packages: 2, releases: 3, files: 4, targets: 2 });
});

test("catalog totals deduplicate canonical package, release, and file selections", () => {
  const source = artifact("source", "x86_64-linux");
  const pkg = packageWithArtifacts("owner/alpha", [source, { ...source }]);
  pkg.versions.push({ ...pkg.versions[0] });
  const duplicate = { ...pkg, versions: [{ version: "0.1.0", artifacts: [source, artifact("source", "aarch64-linux")] }] };
  assert.deepEqual(catalogStats([pkg, duplicate, pkg]), { packages: 1, releases: 1, files: 2, targets: 2 });
});

test("catalog totals cannot turn malformed metadata into published files or targets", () => {
  const good = artifact("source", "x86_64-linux");
  const pkg = packageWithArtifacts("owner/alpha", [good, null, {}, { ...good, kind: "library" },
    { ...good, target: "" }, { ...good, target: "a".repeat(129) }, { ...good, sha256: "bad" },
    { ...good, url: "javascript:alert(1)" }]);
  pkg.versions.push({ version: "01.0.0", artifacts: [artifact("source", "invalid-version-target")] });
  assert.deepEqual(catalogStats([null, { ...pkg, name: "../invalid" }, pkg]),
    { packages: 1, releases: 1, files: 1, targets: 1 });
  assert.deepEqual(catalogStats([]), { packages: 0, releases: 0, files: 0, targets: 0 });
});

test("each release displays its own license without borrowing the current package license", () => {
  const pkg = record("stubbi/asm", "x86_64-linux");
  pkg.license = "AGPL-3.0-or-later";
  pkg.latest = "0.2.0";
  pkg.versions = [
    { version: "0.1.0", license: "MIT", artifacts: [] },
    { version: "0.2.0", license: "AGPL-3.0-or-later", artifacts: [] },
    { version: "0.0.1", artifacts: [] }
  ];
  const versions = normalizeIndex({ schema: 1, packages: [pkg] })[0].versions;
  assert.deepEqual(versions.map(versionLicenseText), ["License: MIT", "License: AGPL-3.0-or-later", "License: unavailable"]);
  for (const license of [null, {}, "", "MIT\nAGPL", "<script>", "a".repeat(101)]) {
    assert.equal(versionLicenseText({ license }), "License: unavailable");
  }
});

test("search combines all terms with an exact target filter", () => {
  const records = [record("owner/alpha", "x86_64-linux"), record("owner/beta", "aarch64-linux")];
  assert.deepEqual(findPackages(records, "  ALPHA source ", "x86_64-linux").map((p) => p.name), ["owner/alpha"]);
  assert.equal(findPackages(records, "alpha", "aarch64-linux").length, 0);
  assert.equal(findPackages(records, ".*", "").length, 0);
  assert.equal(findPackages(records, "", "").length, 2);
});

test("typed search prefers an exact identity over incidental descriptions and partial names", () => {
  const companion = record("aaa/companion", "x86_64-linux");
  companion.summary = "Helpers for owner/math";
  const exact = record("owner/math", "x86_64-linux");
  const partial = record("owner/math-tools", "x86_64-linux");
  const packages = normalizeIndex({ schema: 1, packages: [companion, partial, exact] });
  assert.deepEqual(findPackages(packages, "owner/math", "").map((pkg) => pkg.name),
    ["owner/math", "aaa/companion", "owner/math-tools"]);
  assert.deepEqual(findPackages(packages, "math", "").map((pkg) => pkg.name),
    ["owner/math", "aaa/companion", "owner/math-tools"]);
  assert.deepEqual(findPackages(packages, "", "").map((pkg) => pkg.name),
    ["aaa/companion", "owner/math", "owner/math-tools"]);
});

test("format and target must match the same artifact", () => {
  const pkg = packageWithArtifacts("owner/mixed", [
    artifact("source", "x86_64-linux"), artifact("executable", "aarch64-linux")
  ]);
  assert.equal(findPackages([pkg], "", "aarch64-linux", "source").length, 0);
  assert.deepEqual(findPackages([pkg], "", "aarch64-linux", "executable"), [pkg]);
  assert.deepEqual(findPackages([pkg], "", "x86_64-linux", "source"), [pkg]);
});

test("architecture, target, and format must match one latest active artifact", () => {
  const pkg = packageWithArtifacts("owner/mixed", [artifact("source", "x86_64-linux"), artifact("executable", "aarch64-macos")]);
  assert.deepEqual(findPackages([pkg], "", "", "source", "aarch64"), []);
  assert.deepEqual(findPackages([pkg], "", "x86_64-linux", "", "aarch64"), []);
  assert.deepEqual(findPackages([pkg], "", "", "executable", "aarch64"), [pkg]);
  assert.deepEqual(findPackages([pkg], "", "", "", "unknown"), []);
  pkg.latest = "0.2.0";
  pkg.versions.push({ version: "0.2.0", yanked: false, artifacts: [artifact("source", "riscv64-linux")] });
  assert.deepEqual(findPackages([pkg], "", "", "", "aarch64"), []);
  assert.deepEqual(findPackages([pkg], "", "", "source", "riscv64"), [pkg]);
  pkg.versions[1].yanked = true;
  assert.deepEqual(findPackages([pkg], "", "", "", "riscv64"), []);
});

test("architecture aliases and target text describe active eligible artifacts", () => {
  const arm = packageWithArtifacts("owner/alpha", [artifact("source", "aarch64-macos")]);
  const x86 = packageWithArtifacts("owner/beta", [artifact("source", "x86_64-linux")]);
  const risc = packageWithArtifacts("owner/gamma", [artifact("source", "riscv64-linux")]);
  for (const [query, expected] of [["ARM64", arm], ["aarch64", arm], ["x86-64", x86], ["x86_64", x86], ["RISC-V64", risc], ["riscv64", risc]]) {
    assert.deepEqual(findPackages([arm, x86, risc], query, ""), [expected], query);
  }
  arm.targets.push("riscv64-linux");
  assert.deepEqual(findPackages([arm], "riscv64", ""), []);
  arm.versions[0].artifacts[0].sha256 = "bad";
  assert.deepEqual(findPackages([arm], "ARM64", ""), []);
  const mixed = packageWithArtifacts("owner/mixed", [artifact("source", "x86_64-linux"), artifact("executable", "aarch64-linux")]);
  assert.deepEqual(findPackages([mixed], "ARM64", "", "source"), []);
  assert.deepEqual(findPackages([mixed], "ARM64", "", "executable"), [mixed]);
  const exact = packageWithArtifacts("owner/arm64", [artifact("source", "aarch64-linux")]);
  assert.equal(findPackages([arm, exact], "arm64", "")[0], exact);
});

test("architecture discovery deduplicates packages across targets without borrowing history or invalid artifacts", () => {
  const arm = packageWithArtifacts("owner/alpha", [artifact("source", "aarch64-macos"), artifact("source", "aarch64-linux")]);
  const mixed = packageWithArtifacts("owner/beta", [artifact("source", "riscv64-linux"), artifact("source", "x86_64-linux")]);
  arm.targets.push("x86_64-linux");
  mixed.versions.unshift({ version: "0.0.1", yanked: true, artifacts: [artifact("source", "aarch64-linux")] });
  const unknown = packageWithArtifacts("owner/unknown", [artifact("source", "aarch64-custom")]);
  const invalid = packageWithArtifacts("owner/invalid", [{ ...artifact("source", "aarch64-linux"), sha256: "bad" }]);
  const yanked = packageWithArtifacts("owner/yanked", [artifact("source", "aarch64-linux")]);
  yanked.latest = null;
  assert.deepEqual(architectureGroups([arm, arm, mixed, unknown, invalid, yanked]), [
    { id: "aarch64", name: "ARM64", packages: ["owner/alpha"] },
    { id: "riscv64", name: "RISC-V64", packages: ["owner/beta"] },
    { id: "x86_64", name: "x86-64", packages: ["owner/beta"] }
  ]);
});

test("accepted Windows artifact profiles use explicit architecture discovery without adding native hosts", () => {
  const { architectureForTarget } = require("../site/app.js");
  assert.equal(architectureForTarget("aarch64-windows"), "aarch64");
  assert.equal(architectureForTarget("x86_64-windows"), "x86_64");
  assert.equal(architectureForTarget("x86_64-macos"), null);
  const arm = packageWithArtifacts("owner/windows-arm", [artifact("source", "aarch64-windows")]);
  const x86 = packageWithArtifacts("owner/windows-x86", [artifact("source", "x86_64-windows")]);
  assert.deepEqual(findPackages([arm, x86], "", "", "source", "aarch64").map((pkg) => pkg.name), ["owner/windows-arm"]);
  assert.deepEqual(architectureGroups([arm, x86]), [
    { id: "aarch64", name: "ARM64", packages: ["owner/windows-arm"] },
    { id: "x86_64", name: "x86-64", packages: ["owner/windows-x86"] }
  ]);
});

test("discovery accepts current multi-platform releases above six files while retaining the fourteen-file bound", () => {
  const { normalizeDiscovery } = require("../site/app.js");
  const profiles = ["x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos", "x86_64-windows", "aarch64-windows"];
  const pkg = packageWithArtifacts("owner/multi", profiles.map((target) => artifact("source", target)).concat(artifact("executable", profiles[0])));
  const published = "2026-01-02T00:00:00Z";
  const snapshot = { schema: 1, policy: "asm-deliveries-v1", source: "asm-delivery-events", observed_at: null,
    publication_observed_at: published, stale: true, refresh_error: null, collection_started_at: null,
    coverage: { start: null, end: null, complete: false }, window: { days: 30, start: null, end: null, basis: "rolling-observation" },
    packages: [{ name: pkg.name, first_published_at: published, last_published_at: published, publication_source: "github-release",
      downloads_30d: null, downloads_30d_exact: false, downloads_30d_coverage: "unavailable" }],
    feeds: { new: [pkg.name], popular: [], updated: [pkg.name] } };
  assert.equal(normalizeDiscovery(snapshot, [pkg]).feeds.new[0].name, pkg.name);
  pkg.versions[0].artifacts = Array.from({ length: 15 }, () => artifact("source", profiles[0]));
  assert.throws(() => normalizeDiscovery(snapshot, [pkg]), /discovery/i);
});

test("target-only filters require a valid artifact in the latest active release", () => {
  const pkg = packageWithArtifacts("owner/changed", [artifact("source", "x86_64-linux")]);
  pkg.latest = "0.2.0";
  pkg.targets = ["x86_64-linux", "aarch64-linux"];
  pkg.versions.push({ version: "0.2.0", yanked: false, artifacts: [artifact("source", "aarch64-linux")] });
  assert.deepEqual(findPackages([pkg], "", "x86_64-linux"), []);
  assert.deepEqual(findPackages([pkg], "", "aarch64-linux"), [pkg]);
  for (const mutate of [
    (value) => { value.latest = null; },
    (value) => { value.latest = "9.0.0"; },
    (value) => { value.versions[1].yanked = true; },
    (value) => { value.versions[1].artifacts[0].sha256 = "bad"; }
  ]) {
    const invalid = structuredClone(pkg);
    mutate(invalid);
    assert.deepEqual(findPackages([invalid], "", "aarch64-linux"), []);
    assert.deepEqual(findPackages([invalid], "", ""), [invalid]);
  }
});

test("search metadata binds license and format-target groups to the exact latest active release", () => {
  const pkg = packageWithArtifacts("owner/mixed", [artifact("source", "historic-target")]);
  pkg.license = "Apache-2.0";
  pkg.versions[0].license = "MIT";
  pkg.latest = "0.2.0";
  pkg.targets.push("unrelated-target");
  pkg.versions.push({ version: "0.2.0", yanked: false, license: "AGPL-3.0-or-later", artifacts: [
    artifact("source", "aarch64-linux"), artifact("source", "aarch64-linux"), artifact("executable", "x86_64-linux")
  ] });
  assert.deepEqual(searchResultMetadata(pkg), { version: "0.2.0", license: "AGPL-3.0-or-later", formats: [
    { kind: "source", targets: ["aarch64-linux"] }, { kind: "executable", targets: ["x86_64-linux"] }
  ] });
  pkg.versions[1].license = "<invalid>";
  assert.equal(searchResultMetadata(pkg).license, null);
});

test("filtered search previews show only formats and targets matching one selected artifact", () => {
  const asm = packageWithArtifacts("stubbi/asm", [artifact("source", "x86_64-linux"),
    artifact("executable", "x86_64-linux"), artifact("executable", "aarch64-linux"), artifact("executable", "aarch64-macos")]);
  asm.versions[0].license = "AGPL-3.0-or-later";
  const hello = packageWithArtifacts("stubbi/hello", [artifact("source", "x86_64-linux"),
    artifact("source", "aarch64-linux"), artifact("source", "aarch64-macos")]);
  hello.versions[0].license = "MIT";
  assert.deepEqual(searchResultMetadata(asm, { architecture: "aarch64" }), {
    version: "0.1.0", license: "AGPL-3.0-or-later", formats: [{ kind: "executable", targets: ["aarch64-linux", "aarch64-macos"] }]
  });
  assert.deepEqual(findPackages([asm, hello], "", "", "source", "aarch64"), [hello]);
  assert.deepEqual(searchResultMetadata(hello, { kind: "source", architecture: "aarch64" }).formats,
    [{ kind: "source", targets: ["aarch64-linux", "aarch64-macos"] }]);
  assert.deepEqual(searchResultMetadata(asm, { target: "aarch64-linux" }).formats,
    [{ kind: "executable", targets: ["aarch64-linux"] }]);
  assert.deepEqual(searchResultMetadata(asm, { kind: "source", target: "aarch64-linux", architecture: "aarch64" }).formats, []);
  assert.deepEqual(searchResultMetadata(hello, { kind: "source", target: "aarch64-linux", architecture: "x86_64" }).formats, []);
  assert.deepEqual(searchResultMetadata(asm).formats.map((format) => format.kind), ["source", "executable"]);
});

test("search metadata never borrows historical or package facts for an unavailable release", () => {
  const base = packageWithArtifacts("owner/history", [artifact("source", "x86_64-linux")]);
  base.license = "MIT";
  base.versions[0].license = "MIT";
  for (const pkg of [
    { ...base, latest: null }, { ...base, latest: "9.0.0" },
    { ...base, versions: [{ ...base.versions[0], yanked: true }] }
  ]) {
    assert.deepEqual(searchResultMetadata(pkg), { version: null, license: null, formats: [] });
  }
  const valid = artifact("source", "x86_64-linux");
  base.versions[0].artifacts = [null, { ...valid, kind: "library" }, { ...valid, target: "" },
    { ...valid, target: "a".repeat(129) }, { ...valid, sha256: "bad" }, { ...valid, url: "javascript:alert(1)" }];
  assert.deepEqual(searchResultMetadata(base), { version: "0.1.0", license: "MIT", formats: [] });
  assert.deepEqual(findPackages([base], "", "", "source"), []);
});

test("format discovery uses the latest active release instead of historical artifacts", () => {
  const pkg = packageWithArtifacts("owner/changed", [artifact("executable", "x86_64-linux")]);
  pkg.latest = "0.2.0";
  pkg.versions.push({ version: "0.2.0", yanked: false, artifacts: [artifact("source", "aarch64-linux")] });
  pkg.versions.unshift({ version: "0.0.1", yanked: true, artifacts: [artifact("executable", "riscv64-linux")] });
  pkg.targets = ["x86_64-linux", "aarch64-linux", "riscv64-linux"];
  assert.equal(findPackages([pkg], "", "", "executable").length, 0);
  assert.equal(findPackages([pkg], "", "x86_64-linux", "source").length, 0);
  assert.deepEqual(findPackages([pkg], "", "aarch64-linux", "source"), [pkg]);
});

test("yanked and missing latest releases remain outside active format categories", () => {
  const base = packageWithArtifacts("owner/history", [
    artifact("source", "x86_64-linux"), artifact("executable", "x86_64-linux")
  ]);
  const records = [
    { ...base, name: "owner/null-latest", latest: null },
    { ...base, name: "owner/missing-latest", latest: undefined },
    { ...base, name: "owner/unknown-latest", latest: "9.0.0" },
    { ...base, name: "owner/yanked", versions: [{ ...base.versions[0], yanked: true }] }
  ];
  for (const kind of ["source", "executable"]) {
    assert.deepEqual(findPackages(records, "", "", kind), []);
  }
  assert.deepEqual(findPackages(records, "", "", ""), records);
});

test("format discovery excludes malformed artifacts and unsupported kinds", () => {
  const good = artifact("source", "x86_64-linux");
  const malformed = [null, {}, { ...good, kind: "library" },
    { ...good, sha256: "A".repeat(64) }, { ...good, target: null },
    { ...good, url: "javascript:alert(1)" }];
  const records = malformed.map((item, index) => packageWithArtifacts(`owner/bad-${index}`, [item]));
  assert.deepEqual(findPackages(records, "", "", "source"), []);
  assert.deepEqual(findPackages(records, "", "", "executable"), []);
  const valid = packageWithArtifacts("owner/valid", [good]);
  assert.deepEqual(findPackages([valid], "", "", "library"), []);
  assert.deepEqual(findPackages([valid], "", "", "SOURCE"), []);
});

test("packages can belong to both formats without duplicate result rows", () => {
  const mixed = packageWithArtifacts("owner/mixed", [
    artifact("source", "x86_64-linux"), artifact("source", "aarch64-linux"),
    artifact("executable", "x86_64-linux"), artifact("executable", "aarch64-linux")
  ]);
  const source = packageWithArtifacts("owner/source", [artifact("source", "x86_64-linux")]);
  const executable = packageWithArtifacts("owner/executable", [artifact("executable", "x86_64-linux")]);
  const records = [mixed, source, executable];
  assert.deepEqual(findPackages(records, "", "", "source"), [mixed, source]);
  assert.deepEqual(findPackages(records, "", "", "executable"), [mixed, executable]);
  assert.deepEqual(findPackages(records, "", "", ""), records);
});

test("search terms compose with format and target, and clearing filters restores history", () => {
  const alpha = packageWithArtifacts("owner/alpha", [artifact("source", "x86_64-linux")]);
  const beta = packageWithArtifacts("owner/beta", [
    artifact("source", "aarch64-linux"), artifact("executable", "x86_64-linux")
  ]);
  const history = packageWithArtifacts("owner/history", [artifact("source", "x86_64-linux")]);
  history.latest = null;
  history.versions[0].yanked = true;
  const records = [alpha, beta, history];
  assert.deepEqual(findPackages(records, "  BETA source ", "aarch64-linux", "source"), [beta]);
  assert.deepEqual(findPackages(records, "beta", "x86_64-linux", "source"), []);
  assert.deepEqual(findPackages(records, "beta", "x86_64-linux", "executable"), [beta]);
  assert.deepEqual(findPackages(records, ".*", "", "source"), []);
  assert.deepEqual(findPackages(records, "", "", ""), records);
  assert.deepEqual(findPackages(records, "", ""), records);
  assert.deepEqual(findPackages(records, "history", "x86_64-linux", ""), []);
  assert.deepEqual(findPackages(records, "history", "", ""), [history]);
});

test("an empty registry is distinct from a search without matches", () => {
  assert.match(packageStatus(0, 0), /no published packages yet/);
  assert.match(packageStatus(3, 0), /No packages match/);
  assert.match(packageStatus(3, 1), /^1 package shown/);
  assert.match(packageStatus(3, 3), /^3 packages shown/);
});

test("artifact downloads need a supported kind, target, and full lowercase SHA-256", () => {
  const good = { kind: "executable", target: "x86_64-linux", sha256: "a".repeat(64), url: "https://github.com/stubbi/asm/releases/download/v0.1.0/asm-linux-x86_64" };
  assert.ok(validArtifact(good));
  assert.ok(!validArtifact({ ...good, sha256: "a".repeat(63) }));
  assert.ok(!validArtifact({ ...good, sha256: "G".repeat(64) }));
  assert.ok(!validArtifact({ ...good, kind: "install-script" }));
  assert.ok(!validArtifact({ ...good, url: "data:text/html,bad" }));
});

test("missing or failed evidence is never presented as a successful check", () => {
  assert.equal(evidenceText("not-run"), "Not run");
  assert.equal(evidenceText("error"), "Error");
  assert.equal(evidenceText("fail"), "Fail");
  assert.equal(evidenceText("unsupported"), "Unsupported");
  assert.equal(evidenceText(undefined), "Unavailable");
  assert.equal(evidenceText("safe"), "Unavailable");
});

test("unknown byte sizes remain distinct from a measured zero", () => {
  assert.equal(formatBytes(null), "Size unavailable");
  assert.equal(formatBytes(-1), "Size unavailable");
  assert.equal(formatBytes(0), "0 bytes");
  assert.equal(formatBytes(1024), "1.0 KiB");
});

test("missing counters do not become zero, and missing dates do not become 1970", () => {
  assert.equal(formatDownloadCount(null, "owner/alpha"), "GitHub asset downloads: unavailable");
  assert.equal(formatDownloadCount({ packages: { "owner/alpha": { total: null } } }, "owner/alpha"), "GitHub asset downloads: unavailable");
  assert.equal(formatDownloadCount({ observed_at: "2026-10-31T12:00:00Z", packages: { "owner/alpha": { total: 0 } } }, "owner/alpha"), "GitHub asset downloads: 0 · observed 2026-10-31");
  assert.equal(formatDownloadCount({ observed_at: null, packages: { "owner/alpha": { total: 12 } } }, "owner/alpha"), "GitHub asset downloads: 12 · observation time unavailable");
});

function sourceWithDependencies() {
  return {
    kind: "source", target: "x86_64-linux", bytes: 2054, sha256: "b".repeat(64),
    url: "https://github.com/stubbi/asm/releases/download/v1/source.tar.gz",
    dependency_metadata: {
      schema: 1, source_sha256: "b".repeat(64),
      dependencies: [{ name: "owner/math", requirement: "^1.2.0", optional: false, default_features: true, features: ["checked"] }],
      features: { default: ["fast"], fast: ["dep:owner/math", "owner/math/checked"] }
    }
  };
}

test("dependency declarations require checked source bytes and their exact digest", () => {
  const { dependencyMetadata } = require("../site/app.js");
  const source = sourceWithDependencies();
  assert.deepEqual(dependencyMetadata(source, "validated"), source.dependency_metadata);
  for (const state of [undefined, "not-run", "error", "pass"]) assert.equal(dependencyMetadata(source, state), null);
  assert.equal(dependencyMetadata({ ...source, kind: "executable" }, "validated"), null);
  assert.equal(dependencyMetadata({ ...source, dependency_metadata: { ...source.dependency_metadata, source_sha256: "c".repeat(64) } }, "validated"), null);
});

test("checked empty declarations remain distinct from missing or malformed metadata", () => {
  const { dependencyMetadata } = require("../site/app.js");
  const source = sourceWithDependencies();
  const empty = { schema: 1, source_sha256: source.sha256, dependencies: [], features: {} };
  assert.deepEqual(dependencyMetadata({ ...source, dependency_metadata: empty }, "validated"), empty);
  for (const metadata of [undefined, null, {}, { ...empty, schema: 2 }, { ...empty, dependencies: null }, { ...empty, features: [] }]) {
    assert.equal(dependencyMetadata({ ...source, dependency_metadata: metadata }, "validated"), null);
  }
});

test("dependency declarations keep ranges and feature policies without selecting a version", () => {
  const { dependencyMetadata } = require("../site/app.js");
  const source = sourceWithDependencies();
  source.dependency_metadata.dependencies[0] = {
    name: "owner/math", requirement: ">=1.2.0, <2.0.0", optional: true, default_features: false, features: ["checked"]
  };
  const metadata = dependencyMetadata(source, "validated");
  assert.equal(metadata.dependencies[0].requirement, ">=1.2.0, <2.0.0");
  assert.equal(metadata.dependencies[0].optional, true);
  assert.equal(metadata.dependencies[0].default_features, false);
  assert.equal(Object.hasOwn(metadata.dependencies[0], "version"), false);
});

test("dependency display rejects hostile names, malformed policies, and excessive lists", () => {
  const { dependencyMetadata } = require("../site/app.js");
  const source = sourceWithDependencies();
  const valid = source.dependency_metadata.dependencies[0];
  const invalid = [
    { ...valid, name: "javascript:alert(1)" }, { ...valid, name: "owner/<img>" },
    { ...valid, name: "owner/../math" }, { ...valid, name: "owner/math--one" },
    { ...valid, optional: "false" }, { ...valid, default_features: null },
    { ...valid, requirement: "<script>alert(1)</script>" }, { ...valid, requirement: " " },
    { ...valid, requirement: " ^1.2.0" }, { ...valid, requirement: "1.2.0 " }, { ...valid, requirement: "1".repeat(129) },
    { ...valid, features: ["<img>"] }, { ...valid, features: ["checked", "checked"] }
  ];
  for (const entry of invalid) {
    assert.equal(dependencyMetadata({ ...source, dependency_metadata: { ...source.dependency_metadata, dependencies: [entry] } }, "validated"), null);
  }
  for (const entries of [[valid, valid], Array(65).fill(valid)]) {
    assert.equal(dependencyMetadata({ ...source, dependency_metadata: { ...source.dependency_metadata, dependencies: entries } }, "validated"), null);
  }
});

test("feature declarations are bounded and reference declared features and packages", () => {
  const { dependencyMetadata } = require("../site/app.js");
  const source = sourceWithDependencies();
  for (const features of [
    { default: ["missing"] }, { fast: ["dep:owner/missing"] }, { fast: ["owner/missing/checked"] },
    { fast: ["<script>"] }, { fast: Array(65).fill("dep:owner/math") },
    { fast: ["dep:owner/math", "dep:owner/math"] },
    Object.fromEntries(Array.from({ length: 65 }, (_, index) => [`feature${index}`, []]))
  ]) {
    assert.equal(dependencyMetadata({ ...source, dependency_metadata: { ...source.dependency_metadata, features } }, "validated"), null);
  }
});

test("package fragment links use canonical identities without collisions", () => {
  const { packageAnchor } = require("../site/app.js");
  assert.equal(packageAnchor("owner/math"), "package-owner--math");
  assert.notEqual(packageAnchor("owner-math/lib"), packageAnchor("owner/math-lib"));
  for (const name of ["owner/../math", "javascript:alert(1)", "owner/math--one", "owner/math-", "owner_/math", "<img>"]) {
    assert.equal(packageAnchor(name), null);
  }
});

function declarationCatalog() {
  const source = sourceWithDependencies();
  delete source.dependency_metadata;
  return [{ name: "owner/app", versions: [
    { version: "1.0.0", evidence: { artifacts: "validated" }, artifacts: [source] },
    { version: "2.0.0", evidence: { artifacts: "validated" }, artifacts: [{ ...source }] }
  ] }];
}

test("optional declarations bind only the exact package version target and source digest", () => {
  const { mergeDependencyMetadata } = require("../site/app.js");
  const entry = { name: "owner/app", version: "1.0.0", target: "x86_64-linux", metadata: sourceWithDependencies().dependency_metadata };
  const catalog = declarationCatalog();
  const result = mergeDependencyMetadata(catalog, { schema: 1, sources: [entry] });
  assert.equal(result[0].versions[0].artifacts[0].dependency_metadata.dependencies[0].requirement, "^1.2.0");
  assert.equal(result[0].versions[1].artifacts[0].dependency_metadata, undefined);
  assert.equal(catalog[0].versions[0].artifacts[0].dependency_metadata, undefined);
  for (const change of [
    { name: "other/app" }, { version: "3.0.0" }, { target: "aarch64-linux" },
    { metadata: { ...entry.metadata, source_sha256: "c".repeat(64) } }
  ]) {
    const unmatched = mergeDependencyMetadata(catalog, { schema: 1, sources: [{ ...entry, ...change }] });
    assert.equal(unmatched[0].versions[0].artifacts[0].dependency_metadata, undefined);
  }
});

test("missing invalid or ambiguous optional declarations keep catalog records with unknown metadata", () => {
  const { mergeDependencyMetadata } = require("../site/app.js");
  const entry = { name: "owner/app", version: "1.0.0", target: "x86_64-linux", metadata: sourceWithDependencies().dependency_metadata };
  const catalog = declarationCatalog();
  catalog[0].versions[0].artifacts[0].dependency_metadata = entry.metadata;
  for (const data of [null, {}, { schema: 2, sources: [entry] }, { schema: 1, sources: null },
    { schema: 1, sources: [entry, entry] }, { schema: 1, sources: Array(4097).fill(entry) }]) {
    const result = mergeDependencyMetadata(catalog, data);
    assert.equal(result[0].name, "owner/app");
    assert.equal(result[0].versions.length, 2);
    assert.equal(result[0].versions[0].artifacts[0].dependency_metadata, undefined);
  }
});

test("the math guide selects the unified routine and retains earlier include paths", () => {
  const version = "0.6.0";
  const prefix = `stubbi/math/${version}/x86_64-linux/`;
  const include = mathSourcePath(version);
  assert.ok(include.startsWith(prefix));
  const routine = path.join(__dirname, "../examples/math", include.slice(prefix.length));
  assert.match(fs.readFileSync(routine, "utf8"), /asm_u64_min/);
  assert.equal(mathSourcePath("0.5.0"), "stubbi/math/0.5.0/x86_64-linux/src/min.s");
  assert.equal(mathSourcePath('0.6.0";bad'), null);
});

async function searchPage({ hash = "", offline = false, title = "Assembly package registry and CLI | Asm",
  metadata = { schema: 1, packages: [] }, categories = { schema: 1, categories: [] }, deferTopics = false,
  responses = {} } = {}) {
  const requests = [], listeners = {}, nodes = new Map(), deferred = [];
  let document;
  function node(tag = "div") {
    const attributes = new Map(), handlers = new Map();
    return { tagName: tag.toUpperCase(), children: [], dataset: {}, value: "", textContent: "", hidden: false,
      disabled: false, classList: { values: new Set(), add(name) { this.values.add(name); },
        remove(name) { this.values.delete(name); }, contains(name) { return this.values.has(name); }, toggle(name, enabled) {
          if (enabled) this.values.add(name); else this.values.delete(name);
        } },
      setAttribute(name, value) { attributes.set(name, String(value)); },
      getAttribute(name) { return attributes.get(name) ?? null; },
      removeAttribute(name) { attributes.delete(name); },
      append(...items) { this.children.push(...items); },
      replaceChildren(...items) { this.children = items; },
      get options() { return this.children; },
      querySelectorAll(selector) { return selector === "[data-unavailable-target]"
        ? this.children.filter((child) => child.dataset.unavailableTarget) : []; },
      contains(item) { return item === this || this.children.some((child) => child.contains?.(item)); },
      remove() {}, focus() { document.activeElement = this; },
      addEventListener(name, callback) { handlers.set(name, callback); },
      dispatch(name) { const event = { type: name, preventDefault() { this.defaultPrevented = true; } };
        handlers.get(name)?.(event); return event; }
    };
  }
  for (const id of ["package-list", "registry-status", "package-search", "package-target", "package-kind",
    "package-architecture", "registry-controls", "search-submit", "reset-search", "catalog-heading",
    "registry-fallback", "package-discovery", "results-toolbar", "browse-all", "catalog-note"]) nodes.set(id, node());
  const canonical = node("link"), description = node("meta"), social = node("meta");
  canonical.setAttribute("href", "https://asm.build/");
  description.setAttribute("content", "Find assembly packages.");
  social.setAttribute("content", "Assembly package registry and CLI | Asm");
  const head = { 'link[rel="canonical"]': canonical, 'meta[name="description"]': description,
    'meta[property="og:title"]': social };
  document = { title, documentElement: node("html"), body: node("body"), hidden: false, activeElement: null,
    getElementById(id) { return nodes.get(id) || null; }, createElement: node,
    querySelector(selector) { return head[selector] || null; }, querySelectorAll() { return []; },
    addEventListener(name, callback) { listeners[name] = callback; } };
  const location = { pathname: "/", search: "", hash };
  const history = {};
  for (const name of ["pushState", "replaceState"]) history[name] = (_state, _title, address) => {
    const url = new URL(address, "https://asm.build/"); location.hash = url.hash; location.search = url.search;
  };
  const window = { location, history, addEventListener(name, callback) { listeners[name] = callback; },
    setTimeout() { return 1; }, clearTimeout() {}, setInterval(callback) { listeners.refresh = callback; } };
  const packages = [record("owner/math", "x86_64-linux"), record("owner/text", "aarch64-linux")];
  const fetch = async (url, options) => {
    requests.push([url, options]);
    if (offline) throw new Error("The index is unavailable.");
    const values = { "registry/v1/index.json": { schema: 1, packages }, "registry/v1/discovery.json": null,
      "registry/v1/discovery-metadata.json": metadata, "registry/v1/categories.json": categories };
    assert.ok(Object.hasOwn(values, url));
    const value = values[url];
    if (deferTopics && ["registry/v1/discovery-metadata.json", "registry/v1/categories.json"].includes(url)) {
      await new Promise((resolve) => deferred.push(resolve));
    }
    if (value instanceof Error) throw value;
    return responses[url] || new Response(typeof value === "string" ? value : JSON.stringify(value));
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../site/app.js"), "utf8"),
    { document, window, fetch, URL, URLSearchParams, AbortController, TextDecoder, queueMicrotask });
  await new Promise(setImmediate);
  return { document, nodes, location, requests, canonical, description, social, packages,
    async finishTopics() { deferred.splice(0).forEach((resolve) => resolve()); await new Promise(setImmediate); },
    async refresh() { listeners.refresh(); await new Promise(setImmediate); },
    blur() { document.activeElement = null; listeners.focusout?.(); },
    visit(fragment) { location.hash = fragment; listeners.popstate?.(); } };
}

test("search tab titles follow restored, submitted, cleared, and browser Back states", async () => {
  const page = await searchPage({ hash: "#search?q=math&all=1", title: "Homepage fixture | Asm" });
  const search = page.nodes.get("package-search");
  assert.equal(page.document.title, "Search results for math | Asm");
  search.value = "text";
  assert.equal(page.nodes.get("registry-controls").dispatch("submit").defaultPrevented, true);
  assert.equal(page.document.title, "Search results for text | Asm");
  page.visit("#search?q=math&all=1");
  assert.equal(page.document.title, "Search results for math | Asm");
  page.nodes.get("reset-search").dispatch("click");
  assert.equal(page.document.title, "Homepage fixture | Asm");
  assert.equal(search.value, "");
  page.visit("");
  assert.equal(page.document.title, "Homepage fixture | Asm");
});

test("filter-only and complete catalog tab titles describe the visible results", async () => {
  const page = await searchPage();
  assert.equal(page.document.title, "Assembly package registry and CLI | Asm");
  page.nodes.get("browse-all").dispatch("click");
  assert.equal(page.document.title, "All packages | Asm");
  page.nodes.get("package-kind").value = "source";
  page.nodes.get("package-kind").dispatch("change");
  assert.equal(page.document.title, "Source packages | Asm");
  page.nodes.get("package-architecture").value = "aarch64";
  page.nodes.get("package-architecture").dispatch("change");
  assert.equal(page.document.title, "Source packages for ARM64 | Asm");
  page.nodes.get("package-target").value = "aarch64-linux";
  page.nodes.get("package-target").dispatch("change");
  assert.equal(page.document.title, "Source packages for ARM64 on aarch64-linux | Asm");
  page.visit("#search?kind=executable&all=1");
  assert.equal(page.document.title, "Executable packages | Asm");
  assert.equal(page.nodes.get("package-list").children.length, 0);
  page.visit("#search?target=x86_64-linux&all=1");
  assert.equal(page.document.title, "Assembly packages on x86_64-linux | Asm");
});

test("search titles display bounded plain Unicode text without changing private query state or page metadata", async () => {
  const query = "  math\t\n\u202Espoof\u202C\u0000 <script>alert(1)</script> " + "😀".repeat(100);
  const page = await searchPage({ hash: "#search?q=" + encodeURIComponent(query) + "&all=1" });
  assert.match(page.document.title, /^Search results for math spoof <script>alert\(1\)<\/script> 😀/u);
  assert.doesNotMatch(page.document.title, /[\u0000-\u001f\u007f-\u009f\u202a-\u202e]/u);
  assert.ok(Array.from(page.document.title).length < 120);
  assert.ok(page.document.title.endsWith("… | Asm"));
  assert.equal(page.nodes.get("package-search").value, query);
  assert.equal(new URLSearchParams(page.location.hash.slice(8)).get("q"), query);
  assert.equal(page.canonical.getAttribute("href"), "https://asm.build/");
  assert.equal(page.description.getAttribute("content"), "Find assembly packages.");
  assert.equal(page.social.getAttribute("content"), "Assembly package registry and CLI | Asm");
  assert.deepEqual(page.requests.map(([url]) => url).sort(), ["registry/v1/categories.json", "registry/v1/discovery-metadata.json",
    "registry/v1/discovery.json", "registry/v1/index.json"]);
});

test("invalid search links and unavailable catalog data keep a usable homepage tab title", async () => {
  const page = await searchPage({ hash: "#search?q=math&all=1" });
  assert.equal(page.document.title, "Search results for math | Asm");
  page.visit("#search?kind=unrecognized");
  assert.equal(page.document.title, "Assembly package registry and CLI | Asm");
  assert.match(page.nodes.get("registry-status").textContent, /unsupported filters/);
  const unavailable = await searchPage({ hash: "#search?q=math&all=1", offline: true });
  assert.equal(unavailable.document.title, "Assembly package registry and CLI | Asm");
  assert.equal(unavailable.nodes.get("registry-fallback").hidden, false);
  assert.match(unavailable.nodes.get("registry-status").textContent, /could not be loaded/);
});

test("license queries use only the exact latest active release", () => {
  const current = record("owner/current", "x86_64-linux");
  current.license = "MIT";
  current.versions[0].license = "AGPL-3.0-or-later";
  current.versions.push({ version: "0.0.1", license: "MIT", yanked: false, artifacts: [] });
  const retired = record("owner/retired", "x86_64-linux");
  retired.latest = null;
  retired.versions[0].license = "MIT";
  retired.versions[0].yanked = true;
  assert.deepEqual(findPackages([current, retired], "agpl-3.0-or-later", "").map((pkg) => pkg.name), ["owner/current"]);
  assert.deepEqual(findPackages([current, retired], "MIT", ""), []);
  delete current.versions[0].license;
  assert.deepEqual(findPackages([current], "AGPL", ""), []);
});

function reviewedTopics() {
  return { metadata: { schema: 1, packages: [{ name: "owner/math", keywords: ["integers", "arithmetic"] }] },
    categories: { schema: 1, categories: [{ id: "number-tools", name: "Number tools", packages: ["owner/math"] }] } };
}

test("reviewed keyword and category searches compose with one active artifact and exact identity ranking", () => {
  const { normalizeSearchTopics } = require("../site/app.js");
  const math = packageWithArtifacts("owner/math", [artifact("source", "aarch64-linux"), artifact("executable", "x86_64-linux")]);
  const named = record("owner/integers", "x86_64-linux");
  const catalog = [math, named], { metadata, categories } = reviewedTopics();
  const before = JSON.stringify(catalog);
  const topics = [normalizeSearchTopics(metadata, catalog, "keywords"), normalizeSearchTopics(categories, catalog, "categories")];
  assert.deepEqual(findPackages(catalog, "integers", "", "", "", topics).map((pkg) => pkg.name), ["owner/integers", "owner/math"]);
  assert.deepEqual(findPackages(catalog, "number tools arithmetic", "aarch64-linux", "source", "aarch64", topics).map((pkg) => pkg.name), ["owner/math"]);
  assert.deepEqual(findPackages(catalog, "number-tools", "x86_64-linux", "source", "", topics), []);
  assert.equal(JSON.stringify(catalog), before);
});

test("reviewed labels cannot survive a changed latest version or yanked-only history", () => {
  const { normalizeSearchTopics } = require("../site/app.js");
  const math = record("owner/math", "x86_64-linux");
  const catalog = [math], { metadata, categories } = reviewedTopics();
  const topics = [normalizeSearchTopics(metadata, catalog, "keywords"), normalizeSearchTopics(categories, catalog, "categories")];
  const next = { ...math, latest: "0.2.0", versions: [{ ...math.versions[0], version: "0.2.0" }, ...math.versions] };
  assert.deepEqual(findPackages([next], "integers", "", "", "", topics), []);
  const retired = { ...math, latest: null, versions: [{ ...math.versions[0], yanked: true }] };
  const retiredTopics = [normalizeSearchTopics(metadata, [retired], "keywords"), normalizeSearchTopics(categories, [retired], "categories")];
  assert.deepEqual(findPackages([retired], "number-tools", "", "", "", retiredTopics), []);
});

test("optional search metadata rejects ambiguous malformed oversized and foreign declarations", () => {
  const { normalizeSearchTopics } = require("../site/app.js");
  const catalog = [record("owner/math", "x86_64-linux")], { metadata, categories } = reviewedTopics();
  for (const data of [null, {}, { ...metadata, schema: 2 }, { ...metadata, extra: true },
    { schema: 1, packages: [...metadata.packages, ...metadata.packages] },
    { schema: 1, packages: [{ name: "other/math", keywords: [] }] },
    ...[["Uppercase"], ["bad--id"], ["trailing-"], ["<script>"], ["same", "same"], Array(33).fill("topic")]
      .map((keywords) => ({ schema: 1, packages: [{ name: "owner/math", keywords }] })),
    { schema: 1, packages: [{ name: "owner/math", releases: [{ version: "0.0.1", source_commit: "a".repeat(40), dependencies: [] }] }] }]) {
    assert.throws(() => normalizeSearchTopics(data, catalog, "keywords"), { name: "RangeError" });
  }
  for (const data of [{ ...categories, schema: 0 }, { ...categories, categories: [...categories.categories, ...categories.categories] },
    ...[{ id: "bad--id" }, { name: " " }, { name: "a".repeat(81) }, { name: "Bad\u0000label" },
      { packages: ["other/math"] }, { packages: ["owner/math", "owner/math"] }].map((change) => ({ schema: 1,
      categories: [{ ...categories.categories[0], ...change }] })), { schema: 1, categories: Array(33).fill(categories.categories[0]) }]) {
    assert.throws(() => normalizeSearchTopics(data, catalog, "categories"), { name: "RangeError" });
  }
});

test("optional topic loads preserve the base search and focused query before completing", async () => {
  const page = await searchPage({ ...reviewedTopics(), deferTopics: true, hash: "#search?q=integers&all=1" });
  const search = page.nodes.get("package-search"), list = page.nodes.get("package-list");
  assert.equal(search.disabled, false);
  assert.equal(list.children.length, 0);
  assert.match(page.nodes.get("registry-status").textContent, /topic.*loading/i);
  search.focus();
  await page.finishTopics();
  assert.equal(list.children.length, 1);
  assert.equal(page.document.activeElement, search);
  assert.equal(search.value, "integers");
  assert.equal(page.location.hash, "#search?q=integers&all=1");
  assert.equal(page.document.title, "Search results for integers | Asm");
  assert.deepEqual(page.requests.map(([url]) => url).sort(), ["registry/v1/categories.json", "registry/v1/discovery-metadata.json",
    "registry/v1/discovery.json", "registry/v1/index.json"]);
});

test("failed or excessive topic sources retain base results and independent valid labels with limited coverage", async () => {
  for (const metadata of [new Error("Unavailable"), "not JSON", " ".repeat(256 * 1024 + 1), { schema: 2, packages: [] }]) {
    const page = await searchPage({ metadata, categories: reviewedTopics().categories, hash: "#search?q=number-tools&all=1" });
    assert.equal(page.nodes.get("package-list").children.length, 1);
    assert.match(page.nodes.get("registry-status").textContent, /topic.*unavailable|keyword.*unavailable/i);
    page.visit("#search?q=text&all=1");
    assert.equal(page.nodes.get("package-list").children.length, 1);
    assert.equal(page.nodes.get("package-search").disabled, false);
  }
  const page = await searchPage({ metadata: reviewedTopics().metadata, categories: new Error("Unavailable"),
    hash: "#search?q=integers&all=1" });
  assert.equal(page.nodes.get("package-list").children.length, 1);
  assert.match(page.nodes.get("registry-status").textContent, /topic.*unavailable|categor.*unavailable/i);
});

test("optional topic bodies stop reading at the byte limit and cancel excessive streams", { timeout: 5000 }, async () => {
  let reads = 0, cancelled = false;
  const response = new Response(new ReadableStream({ pull(controller) {
    if (reads++ === 100) { controller.close(); return; }
    controller.enqueue(new Uint8Array(8192).fill(32));
  }, cancel() { cancelled = true; } }));
  const page = await searchPage({ metadata: reviewedTopics().metadata, responses: { "registry/v1/categories.json": response },
    hash: "#search?q=integers&all=1" });
  assert.equal(page.nodes.get("package-list").children.length, 1);
  assert.ok(reads <= 10, `Read ${reads} chunks after exceeding the 64 KiB category bound.`);
  assert.equal(cancelled, true);
  assert.match(page.nodes.get("registry-status").textContent, /topic.*unavailable|categor.*unavailable/i);
});

test("late optional topics defer result replacement while a package link has focus", async () => {
  const page = await searchPage({ ...reviewedTopics(), deferTopics: true, hash: "#search?q=math&all=1" });
  const list = page.nodes.get("package-list"), result = list.children[0];
  result.focus();
  await page.finishTopics();
  assert.equal(list.children[0], result);
  assert.equal(page.document.activeElement, result);
  page.blur();
  await new Promise(setImmediate);
  page.visit("#search?q=integers&all=1");
  assert.equal(list.children.length, 1);
});

test("a later failed topic refresh removes stale matches without losing the query or current catalog", async () => {
  const topics = reviewedTopics(), page = await searchPage({ ...topics, hash: "#search?q=integers&all=1" });
  assert.equal(page.nodes.get("package-list").children.length, 1);
  topics.metadata.schema = 2;
  page.packages[0].latest = "0.2.0";
  page.packages[0].versions.unshift({ ...page.packages[0].versions[0], version: "0.2.0" });
  const search = page.nodes.get("package-search");
  search.focus();
  await page.refresh();
  assert.equal(page.nodes.get("package-list").children.length, 0);
  assert.equal(page.document.activeElement, search);
  assert.equal(search.value, "integers");
  assert.equal(page.location.hash, "#search?q=integers&all=1");
  assert.match(page.nodes.get("registry-status").textContent, /topic.*unavailable|keyword.*unavailable/i);
  page.visit("#search?q=number-tools&all=1");
  assert.equal(page.nodes.get("package-list").children.length, 1);
  page.visit("#search?q=text&all=1");
  assert.equal(page.nodes.get("package-list").children.length, 1);
});

test("an invalid initial search retains visible recovery through delayed topics and catalog refresh", async () => {
  const hash = "#search?kind=unrecognized";
  const page = await searchPage({ ...reviewedTopics(), hash, deferTopics: true });
  const status = page.nodes.get("registry-status"), reset = page.nodes.get("reset-search");
  const search = page.nodes.get("package-search");
  assert.match(status.textContent, /unsupported filters/);
  assert.equal(reset.hidden, false);
  search.focus();
  await page.finishTopics();
  assert.match(status.textContent, /unsupported filters/);
  assert.equal(status.classList.contains("sr-only"), false);
  assert.equal(reset.hidden, false);
  assert.equal(page.location.hash, hash);
  assert.equal(page.document.activeElement, search);
  await page.refresh();
  await page.finishTopics();
  assert.match(status.textContent, /unsupported filters/);
  assert.equal(reset.hidden, false);
  assert.equal(page.document.activeElement, search);
  reset.dispatch("click");
  assert.equal(page.location.hash, "");
  assert.equal(reset.hidden, true);
  assert.doesNotMatch(status.textContent, /unsupported filters/);
  page.visit(hash);
  search.value = "math";
  search.dispatch("input");
  assert.equal(page.nodes.get("package-list").children.length, 1);
  assert.doesNotMatch(status.textContent, /unsupported filters/);
});
