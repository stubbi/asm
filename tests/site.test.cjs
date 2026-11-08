"use strict";

// Run with: node --test tests/site.test.cjs
// No browser or npm dependency is required for these metadata-boundary checks.
const assert = require("node:assert/strict");
const test = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
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

function v2Catalog() {
  const id = { registry: "1".repeat(32), package: "2".repeat(32), release: "3".repeat(32) };
  const item = { kind: "source", format: "tar.gz", target: "x86_64-linux", isa: "x86_64", os: "linux", abi: "sysv-amd64", cpu_features: [], bytes: 100,
    sha256: "a".repeat(64), url: `https://mirror.example/asm/blobs/sha256/${"a".repeat(64)}?x-asm=${id.registry}.${id.package}.${id.release}.x86_64-linux.source` };
  return { schema: 2, registry_id: id.registry, projection: { version: "1", publication_revision: "1", policy_revision: "0" },
    mirrors: ["https://mirror.example/asm"], packages: [{ name: "owner/alpha", package_id: id.package, summary: "V2 fixture", latest: "1.0.0", targets: [item.target],
      versions: [{ version: "1.0.0", release_id: id.release, manifest_sha256: "b".repeat(64), envelope_sha256: "c".repeat(64), summary: "V2 fixture", license: "MIT",
        source: { commit: { algorithm: "git-sha1", digest: "d".repeat(40) }, path: ".", archive: { sha256: item.sha256, bytes: 100 } },
        yanked: false, revoked: false, artifacts: [item], evidence: { metadata: "validated", artifacts: "not-run", provenance: "not-run", formal: "not-run", agent_review: "not-run" }, publication: {} }] }] };
}

test("V2 catalog supports exact mirror-bound artifacts without admitting general HTTPS URLs", () => {
  const data = v2Catalog();
  const packages = normalizeIndex(data);
  assert.equal(packages.length, 1);
  assert.equal(validArtifact(packages[0].versions[0].artifacts[0]), true);
  assert.equal(findPackages(packages, "owner/alpha", "x86_64-linux", "source").length, 1);
  assert.deepEqual(catalogStats(packages), { packages: 1, releases: 1, files: 1, targets: 1 });
  assert.equal(validArtifact(data.packages[0].versions[0].artifacts[0]), false);
  for (const mirror of ["https://[::1]:8443/asm", "https://mirror.example:443/asm"]) {
    const accepted = structuredClone(data);
    accepted.mirrors = [mirror];
    accepted.packages[0].versions[0].artifacts[0].url = accepted.packages[0].versions[0].artifacts[0].url.replace(data.mirrors[0], mirror);
    assert.equal(normalizeIndex(accepted).length, 1);
  }
  for (const value of ["https://evil.example/blob", data.packages[0].versions[0].artifacts[0].url + "&ignored=1",
    data.packages[0].versions[0].artifacts[0].url.replace("3".repeat(32), "4".repeat(32)),
    data.packages[0].versions[0].artifacts[0].url.replace("source", "executable")]) {
    const invalid = structuredClone(data);
    invalid.packages[0].versions[0].artifacts[0].url = value;
    assert.throws(() => normalizeIndex(invalid), /V2|index/i);
  }
});

test("V2 index rejects misleading mirrors, duplicate identities, and contradictory active releases", () => {
  for (const change of [
    (data) => { data.mirrors = ["http://mirror.example/asm"]; },
    (data) => { data.mirrors = ["https://user@mirror.example/asm"]; },
    (data) => { data.mirrors = ["https://mirror.example/asm/../other"]; },
    (data) => { data.packages.push(structuredClone(data.packages[0])); },
    (data) => { data.packages[0].versions[0].revoked = true; },
    (data) => { data.packages[0].versions[0].artifacts[0].cpu_features = ["avx2"]; },
    (data) => { data.packages[0].versions[0].artifacts[0].abi = "guess"; },
    (data) => {
      const artifact = data.packages[0].versions[0].artifacts[0];
      artifact.target = "__proto__"; delete artifact.isa; delete artifact.os; delete artifact.abi;
      artifact.url = artifact.url.replace("x86_64-linux", "__proto__");
      data.packages[0].targets = ["__proto__"];
    }
  ]) {
    const data = v2Catalog(); change(data);
    assert.throws(() => normalizeIndex(data), /V2|index/i);
  }
  const data = v2Catalog();
  data.packages[0].latest = null;
  data.packages[0].targets = [];
  data.packages[0].versions[0].revoked = true;
  assert.equal(normalizeIndex(data)[0].latest, null);
});

test("V2 discovery binds counts to immutable IDs and keeps absent release dates unavailable", () => {
  const { normalizeDiscovery, discoveryEmptyMessage } = require("../site/app.js");
  const catalog = v2Catalog();
  const data = { schema: 2, registry_id: catalog.registry_id, policy: "asm-deliveries-v2", source: "asm-delivery-events",
    observed_at: null, publication_observed_at: null, stale: true, refresh_error: null, collection_started_at: null,
    window: { days: 30, start: null, end: null, basis: "rolling-observation" }, coverage: { start: null, end: null, complete: false },
    packages: [{ name: "owner/alpha", package_id: "2".repeat(32), first_published_at: null, last_published_at: null, publication_source: "asm-v2", downloads_30d: null, downloads_30d_exact: false, downloads_30d_coverage: "unavailable" }],
    feeds: { popular: [], new: [], updated: [] }, categories: [] };
  const packages = normalizeIndex(catalog);
  const snapshot = normalizeDiscovery(data, packages);
  assert.equal(snapshot.packages[0].downloads_30d, null);
  assert.ok(require("../site/app.js").rejoinDiscovery(snapshot, packages));
  assert.match(discoveryEmptyMessage(snapshot, "new"), /Publication dates are unavailable/);
  const bad = structuredClone(data); bad.packages[0].package_id = "4".repeat(32);
  assert.throws(() => normalizeDiscovery(bad, packages));
  const foreign = structuredClone(data); foreign.registry_id = "5".repeat(32);
  assert.throws(() => normalizeDiscovery(foreign, packages));
  const fakeDate = structuredClone(data); fakeDate.packages[0].first_published_at = "2026-01-01T00:00:00Z";
  assert.throws(() => normalizeDiscovery(fakeDate, packages));
});

test("V2 refresh selects its own paths and cannot silently use V1 data", () => {
  const { registryPaths } = require("../site/app.js");
  assert.deepEqual(registryPaths("2"), { index: "registry/v2/index.json", discovery: "registry/v2/discovery.json", schema: 2 });
  assert.deepEqual(registryPaths("1"), { index: "registry/v1/index.json", discovery: "registry/v1/discovery.json", schema: 1 });
  assert.throws(() => registryPaths("3"));
});

test("V2 sender observations cannot claim complete coverage or exact download counts", () => {
  const { normalizeDiscovery, formatDiscoveryCount } = require("../site/app.js");
  const catalog = v2Catalog();
  const packages = normalizeIndex(catalog);
  const data = { schema: 2, registry_id: catalog.registry_id, policy: "asm-deliveries-v2", source: "asm-delivery-events",
    observed_at: "2026-01-31T00:00:00Z", publication_observed_at: null, stale: false, refresh_error: null,
    collection_started_at: "2026-01-01T00:00:00Z",
    window: { days: 30, start: "2026-01-01T00:00:00Z", end: "2026-01-31T00:00:00Z", basis: "rolling-observation" },
    coverage: { start: "2026-01-01T00:00:00Z", end: "2026-01-31T00:00:00Z", complete: false },
    packages: [{ name: "owner/alpha", package_id: "2".repeat(32), first_published_at: null, last_published_at: null,
      publication_source: "asm-v2", downloads_30d: 1, downloads_30d_exact: false, downloads_30d_coverage: "lower-bound" }],
    feeds: { popular: ["owner/alpha"], new: [], updated: [] }, categories: [] };
  const now = Date.parse(data.observed_at);
  const snapshot = normalizeDiscovery(data, packages, now);
  assert.equal(formatDiscoveryCount(snapshot.packages[0]), "≥ 1 download");
  for (const change of [
    (value) => { value.coverage.complete = true; },
    (value) => { value.coverage.complete = true; value.packages[0].downloads_30d_exact = true; value.packages[0].downloads_30d_coverage = "complete"; },
    (value) => { value.packages[0].downloads_30d_exact = true; },
    (value) => { value.packages[0].downloads_30d_coverage = "complete"; },
    (value) => { value.packages[0].downloads_30d = null; value.packages[0].downloads_30d_coverage = "lower-bound"; }
  ]) {
    const invalid = structuredClone(data); change(invalid);
    assert.throws(() => normalizeDiscovery(invalid, packages, now), /discovery/i);
  }
});
