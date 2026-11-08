"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { packagePath, parseSearchState, searchStateHash, readReturnState, matchesArtifact, architectureForTarget, architectureLabel } = require("../site/app.js");

test("package permalinks identify the exact package and optional numeric release", () => {
  assert.equal(typeof packagePath, "function");
  assert.equal(packagePath("stubbi/math"), "/packages/stubbi/math");
  assert.equal(packagePath("stubbi/asm", "0.1.0"), "/packages/stubbi/asm/0.1.0");
  assert.equal(new URL(packagePath("stubbi/math"), "https://asm.build/browse/architectures/aarch64").href,
    "https://asm.build/packages/stubbi/math");
  for (const name of ["../math", "owner/../math", "Owner/math", "owner/bad--name", "owner/trailing-", "owner/math?x=1", "owner/math#files", "owner/%2e%2e", "owner\\math", "a".repeat(40) + "/math"]) {
    assert.equal(packagePath(name), null, name);
  }
  for (const version of ["latest", "01.0.0", "0.1.0/..", "0.1.0?x=1", "0.1.0#use", "2147483648.0.0"]) {
    assert.equal(packagePath("stubbi/math", version), null, version);
  }
});

test("search fragments restore query, format, architecture, target, and the complete catalog", () => {
  assert.equal(typeof parseSearchState, "function");
  assert.deepEqual(parseSearchState("#search?q=unsigned+math&kind=source&target=x86_64-linux&all=1"),
    { query: "unsigned math", kind: "source", architecture: "", target: "x86_64-linux", all: true });
  assert.deepEqual(parseSearchState("#search?all=1"), { query: "", kind: "", architecture: "", target: "", all: true });
  assert.equal(parseSearchState("#start"), null);
  assert.equal(parseSearchState("#catalog"), null);
  assert.equal(searchStateHash({ query: "math & min", kind: "source", target: "x86_64-linux", all: true }),
    "#search?q=math+%26+min&kind=source&target=x86_64-linux&all=1");
  assert.equal(searchStateHash({ query: "", kind: "", target: "", all: false }), "");
  const state = { query: "math", kind: "source", architecture: "aarch64", target: "aarch64-macos", all: true };
  const hash = searchStateHash(state);
  assert.equal(hash, "#search?q=math&kind=source&architecture=aarch64&target=aarch64-macos&all=1");
  assert.deepEqual(parseSearchState(hash), state);
  assert.deepEqual(readReturnState("#from=" + encodeURIComponent(hash)), state);
});

test("malformed search links cannot silently replace a filter or exceed input bounds", () => {
  assert.equal(typeof parseSearchState, "function");
  for (const hash of ["#search?q=a&q=b", "#search?kind=library", "#search?all=yes", "#search?architecture=ARM64", "#search?architecture=unknown", "#search?architecture=aarch64&architecture=x86_64", "#search?redirect=https%3A%2F%2Fevil.invalid", "#search?q=" + "x".repeat(513), "#search?target=" + "x".repeat(129)]) {
    assert.throws(() => parseSearchState(hash), /search|filter/i, hash.slice(0, 70));
  }
});

test("maximum Unicode search and target values survive encoded search and return links", () => {
  for (const query of ["あ".repeat(512), "🛠".repeat(256)]) {
    const state = { query, kind: "source", architecture: "riscv64", target: "界".repeat(128), all: true };
    const hash = searchStateHash(state);
    assert.deepEqual(parseSearchState(hash), state);
    assert.deepEqual(readReturnState("#from=" + encodeURIComponent(hash)), state);
  }
});

test("package return navigation accepts only a validated local search fragment", () => {
  assert.equal(typeof readReturnState, "function");
  assert.deepEqual(readReturnState("#from=%23search%3Fq%3Dmath%26kind%3Dsource%26target%3Dx86_64-linux%26all%3D1"),
    { query: "math", kind: "source", architecture: "", target: "x86_64-linux", all: true });
  for (const hash of ["", "#files", "#from=https%3A%2F%2Fevil.invalid", "#from=%23start", "#from=%23search%3Fkind%3Dinvalid", "#from=%23search%3Fall%3D1&from=%23search%3Fq%3Db"]) {
    assert.equal(readReturnState(hash), null, hash);
  }
});

test("artifact filters match target and format on the same file", () => {
  assert.equal(typeof matchesArtifact, "function");
  const source = { kind: "source", target: "x86_64-linux" };
  const executable = { kind: "executable", target: "aarch64-macos" };
  assert.equal(matchesArtifact("", "", source), true);
  assert.equal(matchesArtifact("source", "x86_64-linux", source), true);
  assert.equal(matchesArtifact("source", "aarch64-macos", source), false);
  assert.equal(matchesArtifact("source", "aarch64-macos", executable), false);
  assert.equal(matchesArtifact("executable", "aarch64-macos", executable), true);
  assert.equal(matchesArtifact("library", "", source), false);
  assert.equal(matchesArtifact("source", "x86_64-linux", source, "x86_64"), true);
  assert.equal(matchesArtifact("source", "x86_64-linux", source, "aarch64"), false);
  assert.equal(matchesArtifact("executable", "aarch64-macos", executable, "aarch64"), true);
  assert.equal(matchesArtifact("", "", source, "unknown"), false);
  assert.equal(matchesArtifact("", "", { kind: "source", target: "aarch64-custom" }, "aarch64"), false);
});

test("architecture labels use only explicit v1 target profiles", () => {
  assert.equal(architectureForTarget("aarch64-linux"), "aarch64");
  assert.equal(architectureForTarget("aarch64-macos"), "aarch64");
  assert.equal(architectureForTarget("x86_64-linux"), "x86_64");
  assert.equal(architectureForTarget("riscv64-linux"), "riscv64");
  assert.equal(architectureForTarget("aarch64-windows"), "aarch64");
  assert.equal(architectureForTarget("x86_64-windows"), "x86_64");
  assert.equal(architectureLabel("aarch64"), "ARM64");
  assert.equal(architectureLabel("x86_64"), "x86-64");
  assert.equal(architectureLabel("riscv64"), "RISC-V64");
  for (const target of [null, {}, "aarch64", "aarch64-custom", "aarch64-windows-extra", "x86_64-macos", "__proto__"]) {
    assert.equal(architectureForTarget(target), null);
  }
  assert.equal(architectureLabel("__proto__"), null);
  assert.equal(architectureLabel("ARM64"), null);
});

test("package-page architecture state filters exact artifacts and clears unavailable combinations", () => {
  const { readFileSync } = require("node:fs");
  const vm = require("node:vm");
  const site = require("../site/app.js");
  function control(values) {
    return { value: "", options: values.map((value) => ({ value })), listeners: {}, hidden: true,
      append(option) { this.options.push(option); }, addEventListener(name, action) { this.listeners[name] = action; } };
  }
  function run(architecture) {
    const form = control([]), target = control(["", "x86_64-linux", "aarch64-linux", "aarch64-macos"]);
    const kind = control(["", "source", "executable"]), isa = control(["", "aarch64", "x86_64"]);
    const status = { setAttribute(name, value) { this[name] = value; } }, empty = { hidden: true }, clear = control([]);
    const artifacts = [["source", "x86_64-linux"], ["executable", "aarch64-linux"], ["source", "aarch64-macos"]]
      .map(([kind, target]) => ({ dataset: { artifactKind: kind, artifactTarget: target } }));
    const ids = { "artifact-target": target, "artifact-kind": kind, "artifact-architecture": isa, "artifact-filter-status": status };
    const document = {
      querySelector(selector) { return selector === ".package-filter-form" ? form : selector === ".package-artifact-empty" ? empty : null; },
      querySelectorAll(selector) { return selector.startsWith(".package-artifact[") ? artifacts : selector === "[data-clear-artifact-filters]" ? [clear] : []; },
      getElementById(id) { return ids[id] || null; }, createElement() { return {}; }
    };
    const hash = "#from=" + encodeURIComponent(site.searchStateHash({ query: "", kind: "source", architecture, target: "", all: true }));
    vm.runInNewContext(readFileSync(require.resolve("../site/package-page.js"), "utf8"), { window: { AsmSite: site, location: { hash } }, document });
    return { form, target, kind, isa, status, empty, clear, artifacts };
  }
  const selected = run("aarch64");
  assert.deepEqual(selected.artifacts.map((artifact) => artifact.hidden), [true, true, false]);
  assert.equal(selected.status.textContent, "1 artifact shown.");
  selected.target.value = "x86_64-linux";
  selected.target.listeners.change();
  assert.equal(selected.empty.hidden, false);
  selected.clear.listeners.click();
  assert.equal(selected.isa.value, "");
  assert.deepEqual(selected.artifacts.map((artifact) => artifact.hidden), [false, false, false]);
  const missing = run("riscv64");
  assert.equal(missing.isa.value, "riscv64");
  assert.ok(missing.isa.options.some((option) => option.value === "riscv64"));
  assert.equal(missing.empty.hidden, false);
  assert.equal(missing.form.hidden, false);
});
