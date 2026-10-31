"use strict";

// Run with: node --test tests/site.test.cjs
// No browser or npm dependency is required for these metadata-boundary checks.
const assert = require("node:assert/strict");
const test = require("node:test");
const { createHash } = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { githubURL, normalizeIndex, findPackages, formatBytes, validArtifact, evidenceText, formatDownloadCount, installInstructions } = require("../site/app.js");

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

test("search combines all terms with an exact target filter", () => {
  const records = [record("owner/alpha", "x86_64-linux"), record("owner/beta", "aarch64-linux")];
  assert.deepEqual(findPackages(records, "  ALPHA source ", "x86_64-linux").map((p) => p.name), ["owner/alpha"]);
  assert.equal(findPackages(records, "alpha", "aarch64-linux").length, 0);
  assert.equal(findPackages(records, ".*", "").length, 0);
  assert.equal(findPackages(records, "", "").length, 2);
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

test("the generated checksum command verifies the named download", { skip: process.platform !== "linux" }, () => {
  const base = path.resolve(__dirname, "../build");
  fs.mkdirSync(base, { recursive: true });
  const directory = fs.mkdtempSync(path.join(base, "site-checksum-"));
  try {
    const filename = "asm-0.1.0-x86_64-linux";
    const content = Buffer.from("Controlled checksum fixture\n");
    fs.writeFileSync(path.join(directory, filename), content);
    const artifact = { kind: "executable", target: "x86_64-linux", sha256: createHash("sha256").update(content).digest("hex"), url: `https://github.com/stubbi/asm/releases/download/v0.1.0/${filename}` };
    const instructions = installInstructions(artifact, "0.1.0");
    const output = execFileSync("sh", ["-c", instructions.verify], { cwd: directory, encoding: "utf8" });
    assert.equal(output, `${filename}: OK\n`);
    assert.equal(installInstructions(artifact, "0.1.0;echo unsafe"), null);
    assert.equal(installInstructions({ ...artifact, target: "aarch64-linux" }, "0.1.0"), null);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
