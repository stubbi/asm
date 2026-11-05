"use strict";

// Run with: node --test tests/site.test.cjs
// No browser or npm dependency is required for these metadata-boundary checks.
const assert = require("node:assert/strict");
const test = require("node:test");
const { githubURL, normalizeIndex, findPackages, packageStatus, formatBytes, validArtifact, evidenceText, versionLicenseText, formatDownloadCount } = require("../site/app.js");

function record(name, target) {
  return { name, summary: "A source package", latest: "0.1.0", targets: [target], versions: [{ version: "0.1.0", artifacts: [] }] };
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
