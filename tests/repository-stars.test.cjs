/* Public repository observations, with bounded privacy-preserving refresh. AGPL-3.0-or-later. */
"use strict";
const assert = require("node:assert/strict");
const test = require("node:test");
const { existsSync, readFileSync } = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = path.join(__dirname, "../site/repository-stars.js");
const NOW = Date.parse("2026-11-07T12:00:00Z");
const API = "https://api.github.com/repos/stubbi/asm";
const LOCAL = "https://asm.build/project/registry/v1/github.json";
const CACHE = "asm.github.stubbi/asm.v1";
function moduleAPI() { assert.ok(existsSync(source), "The repository refresh is not implemented."); return require(source); }
function snapshot(stars, at = NOW, changes = {}) {
  return { schema: 1, source: "github", repository: "stubbi/asm", observed_at: new Date(at).toISOString(), stars, stale: false, refresh_error: null, ...changes };
}
function repository(stars) { return { full_name: "stubbi/asm", html_url: "https://github.com/stubbi/asm", stargazers_count: stars, private: false }; }
function response(value) { return new Response(JSON.stringify(value), { headers: { "Content-Type": "application/json" } }); }

class Node {
  constructor(tag = "span", text = "") { this.tagName = tag; this._text = text; this.children = []; this.attrs = {}; this.className = ""; }
  get textContent() { return this._text + this.children.map((child) => child.textContent).join(""); }
  set textContent(value) { this._text = value; this.children = []; }
  get classList() { return { contains: (value) => this.className.split(" ").includes(value) }; }
  append(...children) { children.forEach((child) => { child.parent = this; this.children.push(child); }); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((child) => child !== this); }
  setAttribute(name, value) { this.attrs[name] = value; }
  getAttribute(name) { return this.attrs[name] ?? null; }
  removeAttribute(name) { delete this.attrs[name]; }
  querySelectorAll(selector) {
    const classes = selector.split(",").map((value) => value.trim().slice(1));
    return this.children.flatMap((child) => (classes.some((name) => child.classList.contains(name)) ? [child] : []).concat(child.querySelectorAll(selector)));
  }
}
function browser({ replies = [], storage = new Map(), hidden = false, script = "https://asm.build/project/repository-stars.js", brokenStorage = false } = {}) {
  assert.ok(existsSync(source), "The repository refresh is not implemented.");
  let clock = NOW, nextTimer = 0;
  const requests = [], timers = new Map(), listeners = {}, documentListeners = {};
  const anchor = new Node("a"), icon = new Node("svg"), label = new Node("span", "Star on GitHub");
  anchor.href = "https://github.com/stubbi/asm"; anchor.focused = true; anchor.title = "Old count";
  const baked = new Node("span", "OLD"); baked.className = "github-stars-count";
  const context = new Node("span", "; observed 2020-01-01T00:00:00Z"); context.className = "sr-only github-stars-observation";
  anchor.append(icon, label, baked, context);
  const document = { hidden, currentScript: { src: script }, createElement: (tag) => new Node(tag),
    querySelectorAll: () => [anchor], addEventListener(name, listener) { documentListeners[name] = listener; } };
  const window = { location: { href: "https://asm.build/project/packages/stubbi/asm/?private=term#search?q=secret" },
    sessionStorage: { getItem(key) { if (brokenStorage) throw Error("denied"); return storage.get(key) ?? null; },
      setItem(key, value) { if (brokenStorage) throw Error("denied"); storage.set(key, value); }, removeItem(key) { storage.delete(key); } },
    addEventListener(name, listener) { listeners[name] = listener; } };
  class Clock extends Date { constructor(...args) { super(...(args.length ? args : [clock])); } static now() { return clock; } }
  vm.runInNewContext(readFileSync(source, "utf8"), { window, document, URL, Date: Clock, TextDecoder, AbortController,
    setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, { callback, at: clock + delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    fetch(url, options) { requests.push({ url, options }); const reply = replies.shift(); return typeof reply === "function" ? reply(url, options) : Promise.resolve(reply || new Response("unavailable", { status: 503 })); } });
  document.currentScript = null;
  const flush = async () => { for (let i = 0; i < 16; i++) await new Promise((resolve) => setImmediate(resolve)); };
  async function advance(milliseconds) {
    clock += milliseconds;
    for (const [id, timer] of [...timers]) if (timer.at <= clock) { timers.delete(id); timer.callback(); }
    await flush();
  }
  return { window, document, anchor, icon, label, storage, requests, timers, listeners, documentListeners, flush, advance,
    count: () => anchor.querySelectorAll(".github-stars-count")[0] || null };
}

test("repository counts share the exact GitHub convention and never format unknown as zero", () => {
  const { compactCount, exactCount } = moduleAPI();
  const cases = JSON.parse(readFileSync(path.join(__dirname, "count-format-cases.json"), "utf8"));
  for (const entry of cases.valid.filter((item) => !item.lower_bound)) {
    assert.equal(compactCount(entry.value), entry.compact);
    assert.equal(exactCount(entry.value), entry.exact);
  }
  for (const value of cases.invalid) { assert.equal(compactCount(value), null); assert.equal(exactCount(value), null); }
});

test("only recent canonical observations qualify, with zero distinct from unavailable", () => {
  const { normalizeSnapshot, normalizeRepository } = moduleAPI();
  assert.equal(normalizeSnapshot(snapshot(0), NOW).stars, 0);
  assert.equal(normalizeSnapshot(snapshot(7, NOW - 299999), NOW).stars, 7);
  for (const value of [snapshot(7, NOW - 300000), snapshot(7, NOW + 1), snapshot(7, NOW, { stale: true }),
    snapshot(null, NOW, { observed_at: null, stale: true }), snapshot(true), snapshot(-1), snapshot(1.5),
    snapshot(7, NOW, { repository: "foreign/repo" }), snapshot(7, NOW, { observed_at: "2026-02-30T12:00:00Z" }),
    snapshot(7, NOW, { extra: "untrusted" })]) assert.equal(normalizeSnapshot(value, NOW), null);
  assert.equal(normalizeRepository(repository(3), NOW).stars, 3);
  assert.equal(normalizeRepository({ ...repository(3), full_name: "another/repo" }, NOW), null);
  for (const now of [NaN, Infinity, -1, 1e20]) assert.equal(normalizeRepository(repository(3), now), null);
});

test("the snapshot endpoint comes from the fixed local script, including nested missing routes", () => {
  const { snapshotURL } = moduleAPI();
  assert.equal(snapshotURL("https://asm.build/project/repository-stars.js", "https://asm.build/project/missing/deep/"), LOCAL);
  for (const script of [null, "https://evil.invalid/repository-stars.js", "https://asm.build/project/other.js", "javascript:bad"]) {
    assert.equal(snapshotURL(script, "https://asm.build/project/missing/"), null);
  }
});

test("fresh same-origin data updates count children without replacing the native link", async () => {
  const page = browser({ replies: [response(snapshot(1250))] });
  assert.equal(page.count(), null, "Stale baked text is cleared before awaiting a request.");
  await page.flush();
  assert.deepEqual(page.requests.map((request) => request.url), [LOCAL]);
  assert.equal(page.count().children[0].textContent, "1.3k");
  assert.match(page.count().textContent, /1,250 stars/);
  assert.equal(page.anchor.children[0], page.icon);
  assert.equal(page.anchor.children[1], page.label);
  assert.equal(page.anchor.href, "https://github.com/stubbi/asm");
  assert.equal(page.anchor.focused, true);
  assert.match(page.anchor.title, /1,250 stars.*observed/);
});

test("stale static data falls back only to public repository metadata without credentials or page terms", async () => {
  const page = browser({ replies: [response(snapshot(8, NOW - 300000)), response(repository(0))] });
  await page.flush();
  assert.deepEqual(page.requests.map((request) => request.url), [LOCAL, API]);
  for (const { url, options } of page.requests) {
    assert.equal(new URL(url).search, ""); assert.equal(new URL(url).hash, "");
    assert.equal(options.credentials, "omit"); assert.equal(options.referrerPolicy, "no-referrer");
    assert.equal(options.redirect, "error"); assert.equal(options.body, undefined);
    assert.equal(options.headers.Authorization, undefined);
  }
  assert.equal(page.count().children[0].textContent, "0");
  const stored = JSON.parse(page.storage.get(CACHE));
  assert.equal(stored.stars, 0);
  assert.equal(stored.full_name, undefined);
  assert.equal(stored.private, undefined);
});

test("a fresh session observation avoids repeated network work and can decrease after expiry", async () => {
  const storage = new Map([[CACHE, JSON.stringify(snapshot(1500))]]);
  const page = browser({ storage, replies: [response(snapshot(5, NOW + 300000))] });
  await page.flush();
  assert.equal(page.requests.length, 0);
  assert.equal(page.count().children[0].textContent, "1.5k");
  page.listeners.pageshow();
  assert.equal(page.requests.length, 0);
  await page.advance(300000);
  assert.equal(page.requests.length, 1);
  assert.equal(page.count().children[0].textContent, "5");
});

test("expired observations disappear in hidden tabs and return refreshes coalesce", async () => {
  let resolve;
  const page = browser({ storage: new Map([[CACHE, JSON.stringify(snapshot(8))]]), replies: [() => new Promise((done) => { resolve = done; })] });
  page.document.hidden = true;
  await page.advance(300000);
  assert.equal(page.count(), null);
  assert.equal(page.requests.length, 0);
  page.document.hidden = false;
  page.documentListeners.visibilitychange();
  page.listeners.pageshow();
  page.documentListeners.visibilitychange();
  assert.equal(page.requests.length, 1);
  resolve(response(snapshot(6, NOW + 300000)));
  await page.flush();
  assert.equal(page.count().children[0].textContent, "6");
});

test("unavailable services and blocked storage preserve the link without inventing a count", async () => {
  const page = browser({ brokenStorage: true });
  await page.flush();
  assert.equal(page.requests.length, 2);
  assert.equal(page.count(), null);
  assert.equal(page.anchor.textContent, "Star on GitHub");
  assert.equal(page.anchor.href, "https://github.com/stubbi/asm");
  page.listeners.pageshow(); await page.flush();
  assert.equal(page.requests.length, 2, "An unavailable counter cannot cause an immediate retry loop.");
});

test("a public failure cooldown survives navigation and expires without hiding a fresh cached count", async () => {
  const storage = new Map();
  const first = browser({ storage }); await first.flush();
  assert.equal(first.requests.length, 2);
  assert.equal(storage.get(CACHE + ".retry-at"), String(NOW + 300000));
  const next = browser({ storage, replies: [response(snapshot(4, NOW + 300000))] });
  await next.flush();
  assert.equal(next.requests.length, 0);
  assert.equal(next.count(), null);
  await next.advance(300000);
  assert.equal(next.requests.length, 1);
  assert.equal(next.count().children[0].textContent, "4");
  assert.equal(storage.has(CACHE + ".retry-at"), false);
  const fresh = browser({ storage: new Map([[CACHE, JSON.stringify(snapshot(7))], [CACHE + ".retry-at", String(NOW + 300000)]]) });
  assert.equal(fresh.count().children[0].textContent, "7");
  assert.equal(fresh.requests.length, 0);
});

test("invalid or unbounded public cooldowns cannot suppress a fresh attempt", async () => {
  for (const value of ["broken", "null", "true", "-1", "1.5", String(NOW + 86400001), String(Number.MAX_SAFE_INTEGER)]) {
    const page = browser({ storage: new Map([[CACHE + ".retry-at", value]]), replies: [response(snapshot(2))] });
    await page.flush();
    assert.equal(page.requests.length, 1, value);
    assert.equal(page.count().children[0].textContent, "2");
  }
});

test("a hidden tab pauses external fallback without a failure cooldown and resumes on return", async () => {
  let resolve;
  const page = browser({ replies: [() => new Promise((done) => { resolve = done; }), new Response("no snapshot", { status: 503 }), response(repository(7))] });
  page.document.hidden = true;
  resolve(new Response("no snapshot", { status: 503 }));
  await page.flush();
  assert.deepEqual(page.requests.map((request) => request.url), [LOCAL]);
  assert.equal(page.storage.has(CACHE + ".retry-at"), false);
  await page.advance(300000);
  assert.equal(page.requests.length, 1);
  page.document.hidden = false;
  page.documentListeners.visibilitychange(); await page.flush();
  assert.deepEqual(page.requests.map((request) => request.url), [LOCAL, LOCAL, API]);
  assert.equal(page.count().children[0].textContent, "7");
});

test("GitHub rate-limit deadlines persist across navigation instead of retrying after five minutes", async () => {
  const storage = new Map();
  const limited = new Response("rate limited", { status: 429, headers: { "Retry-After": "3600", "X-RateLimit-Reset": String(NOW / 1000 + 1800) } });
  const first = browser({ storage, replies: [new Response("none", { status: 503 }), limited] });
  await first.flush();
  assert.equal(storage.get(CACHE + ".retry-at"), String(NOW + 3600000));
  const next = browser({ storage, replies: [response(snapshot(9, NOW + 3600000))] });
  await next.advance(300000);
  assert.equal(next.requests.length, 0);
  await next.advance(3300000);
  assert.equal(next.requests.length, 1);
  assert.equal(next.count().children[0].textContent, "9");
  assert.equal(storage.has(CACHE + ".retry-at"), false);
});

test("rate-limit parsing bounds Retry-After dates and reset timestamps to one day", () => {
  const { rateLimitDeadline } = moduleAPI();
  assert.equal(typeof rateLimitDeadline, "function");
  assert.equal(rateLimitDeadline(403, new Headers({ "X-RateLimit-Reset": String(NOW / 1000 + 600) }), NOW), NOW + 600000);
  assert.equal(rateLimitDeadline(429, new Headers({ "Retry-After": new Date(NOW + 120000).toUTCString() }), NOW), NOW + 120000);
  for (const headers of [{ "Retry-After": "bad" }, { "Retry-After": "86401" }, { "X-RateLimit-Reset": String(NOW / 1000 + 86401) }]) {
    assert.equal(rateLimitDeadline(429, new Headers(headers), NOW), null);
  }
  assert.equal(rateLimitDeadline(200, new Headers({ "Retry-After": "3600" }), NOW), null);
});

test("oversized bodies fail closed and stalled requests have a bounded timeout", async () => {
  const large = new Response(" ".repeat(16385));
  const oversized = browser({ replies: [large, response({ ...repository(5), padding: "x".repeat(16385) })] });
  await oversized.flush();
  assert.equal(oversized.count(), null);
  const hanging = (_url, { signal }) => new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(Error("aborted"))));
  const stalled = browser({ replies: [hanging, hanging] });
  await stalled.advance(5000);
  assert.equal(stalled.requests.length, 2);
  await stalled.advance(5000);
  assert.equal(stalled.count(), null);
  assert.equal(stalled.requests.length, 2);
});
