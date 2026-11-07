/* Native header search and optional masthead enhancement. AGPL-3.0-or-later. */
"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { existsSync, readFileSync } = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = path.join(__dirname, "../site/navigation.js");

function navigation() {
  assert.ok(existsSync(source), "The shared native search enhancement is not implemented.");
  return require(source);
}

function browser({ hero = false, observer = true, action = "../index.html", form = true, listenFails = false, loading = false } = {}) {
  assert.ok(existsSync(source), "The shared native search enhancement is not implemented.");
  const events = [], assignments = [], listeners = {}, observers = [], documentListeners = {};
  let available = !loading;
  const root = {
    style: { values: {}, setProperty(name, value) { events.push("surface size"); this.values[name] = value; } },
    classList: { values: new Set(), add(value) { events.push("surface ready"); this.values.add(value); },
      contains(value) { return this.values.has(value); } }
  };
  const input = { value: "", validityMessage: "", reports: 0, listeners: {},
    setCustomValidity(message) { this.validityMessage = message; },
    reportValidity() { this.reports += 1; },
    addEventListener(name, listener) { this.listeners[name] = listener; } };
  const search = { action, listeners: {}, _hidden: true,
    get hidden() { return this._hidden; },
    set hidden(value) { if (!value) events.push("form shown"); this._hidden = value; },
    querySelector(selector) { return selector === 'input[name="q"]' ? input : null; },
    addEventListener(name, listener) {
      if (listenFails) throw new Error("unavailable listener");
      events.push(name + " listener"); this.listeners[name] = listener;
    } };
  const fallback = { hidden: false };
  const surface = {};
  const header = { bottom: 80, getBoundingClientRect() { return { bottom: this.bottom }; },
    querySelector(selector) { return selector === ".masthead-surface" ? surface : null; } };
  const searchHero = { bottom: 400, getBoundingClientRect() { return { bottom: this.bottom }; } };
  const document = { documentElement: root, readyState: loading ? "loading" : "complete",
    addEventListener(name, listener) { documentListeners[name] = listener; },
    querySelector(selector) {
      if (!available) return null;
      return selector === "[data-header-search]" ? (form ? search : null)
        : selector === "[data-header-search-fallback]" ? fallback
        : selector === ".site-header" ? header
        : selector === ".search-hero" && hero ? searchHero : null;
    } };
  const window = { location: { href: "https://asm.build/stats/", hash: "", assign(value) { assignments.push(value); } }, scrollY: 0,
    addEventListener(name, listener) { listeners[name] = listener; } };
  const context = { window, document, URL, URLSearchParams,
    fetch() { assert.fail("Navigation must not fetch page content or search terms."); } };
  if (observer) {
    context.ResizeObserver = class {
      constructor(callback) { this.callback = callback; this.nodes = []; observers.push(this); }
      observe(node) { this.nodes.push(node); }
    };
  }
  vm.runInNewContext(readFileSync(source, "utf8"), context);
  function submit() {
    let prevented = false;
    search.listeners.submit({ preventDefault() { prevented = true; } });
    assert.equal(prevented, true, "Search terms must never enter a native GET query.");
  }
  return { window, document, root, search, input, fallback, events, assignments, listeners, observers, header, searchHero, submit,
    documentListeners, revealDOM() { available = true; document.readyState = "interactive"; } };
}

test("header search uses the existing private fragment format and preserves Unicode and spaces", () => {
  const { searchDestination } = navigation();
  assert.equal(searchDestination("../index.html", " asm & あ 🛠 ", "https://asm.build/stats/"),
    "https://asm.build/#search?q=+asm+%26+%E3%81%82+%F0%9F%9B%A0+&all=1");
  assert.equal(searchDestination("/", "", "https://asm.build/blog/articles/entry/"), "https://asm.build/#search?all=1");
  assert.equal(searchDestination("../../index.html", "hello", "https://example.org/project/blog/articles/"),
    "https://example.org/project/#search?q=hello&all=1");
  assert.equal(searchDestination("/index.html", "hello", "https://asm.build/stats"),
    "https://asm.build/#search?q=hello&all=1");
  const maximum = searchDestination("index.html", "あ".repeat(512), "http://127.0.0.1:8765/");
  assert.equal(new URLSearchParams(new URL(maximum).hash.slice(8)).get("q"), "あ".repeat(512));
  assert.equal(new URL(maximum).search, "");
});

test("header search rejects unbounded queries and destinations outside the same-origin homepage", () => {
  const { searchDestination } = navigation();
  for (const query of [null, undefined, true, 123, {}, "x".repeat(513)]) {
    assert.equal(searchDestination("../index.html", query, "https://asm.build/stats/"), null);
  }
  for (const action of [null, "https://evil.invalid/index.html", "https://name:secret@asm.build/index.html",
    "javascript:alert(1)", "data:text/html,wrong", "/packages/", "/index.html?q=secret", "/index.html#old"]) {
    assert.equal(searchDestination(action, "asm", "https://asm.build/stats/"), null, String(action));
  }
  assert.equal(searchDestination("index.html", "asm", "file:///tmp/index.html"), null);
});

test("native submission is installed before the enhanced form replaces its fallback", () => {
  const page = browser();
  assert.equal(page.search.hidden, false);
  assert.equal(page.fallback.hidden, true);
  assert.ok(page.events.indexOf("submit listener") < page.events.indexOf("form shown"));
  page.input.value = "hello & math";
  page.submit();
  assert.deepEqual(page.assignments, ["https://asm.build/#search?q=hello+%26+math&all=1"]);
  page.input.value = "";
  page.submit();
  assert.equal(page.assignments[1], "https://asm.build/#search?all=1");
});

test("invalid search input retains its value and recovers through native validity feedback", () => {
  const page = browser();
  page.input.value = "x".repeat(513);
  page.submit();
  assert.equal(page.assignments.length, 0);
  assert.equal(page.input.value.length, 513);
  assert.match(page.input.validityMessage, /512/);
  assert.equal(page.input.reports, 1);
  page.input.value = "corrected";
  page.input.listeners.input();
  assert.equal(page.input.validityMessage, "");
  page.submit();
  assert.equal(page.assignments.length, 1);
});

test("unsafe or incomplete initialization leaves the native package fallback available", () => {
  for (const options of [{ action: "https://evil.invalid/index.html" }, { listenFails: true }]) {
    const page = browser(options);
    assert.equal(page.search.hidden, true);
    assert.equal(page.fallback.hidden, false);
    assert.equal(page.assignments.length, 0);
    assert.ok(page.root.classList.values.has("masthead-ready"));
  }
});

test("masthead measurement includes the homepage hero and publishes its size before readiness", () => {
  const page = browser({ hero: true });
  assert.equal(page.root.style.values["--masthead-height"], "400px");
  assert.ok(page.events.indexOf("surface size") < page.events.indexOf("surface ready"));
  assert.deepEqual(page.observers[0].nodes, [page.header, page.searchHero]);
  page.window.scrollY = 200;
  page.header.bottom = -120;
  page.searchHero.bottom = 320.5;
  page.observers[0].callback();
  assert.equal(page.root.style.values["--masthead-height"], "520.5px");
});

test("masthead refresh works without ResizeObserver, search markup, or custom routing", () => {
  const page = browser({ observer: false, form: false });
  assert.equal(page.fallback.hidden, false);
  assert.equal(page.root.style.values["--masthead-height"], "80px");
  for (const event of ["resize", "pageshow", "pagereveal"]) {
    page.header.bottom += 20;
    page.listeners[event]({});
    assert.equal(page.root.style.values["--masthead-height"], page.header.bottom + "px");
  }
  assert.equal(page.listeners.click, undefined);
  assert.equal(page.listeners.popstate, undefined);
});

test("cross-document transitions are skipped only when the whole masthead is above the viewport", () => {
  const page = browser({ hero: true });
  let skipped = 0;
  const event = { viewTransition: { skipTransition() { skipped += 1; } } };
  page.header.bottom = -100;
  page.searchHero.bottom = 1;
  page.listeners.pageswap(event);
  assert.equal(skipped, 0);
  page.searchHero.bottom = 0;
  page.listeners.pageswap(event);
  assert.equal(skipped, 1);
  assert.doesNotThrow(() => page.listeners.pageswap({}));
});

test("a parser-blocking head script registers transition hooks before waiting for page markup", () => {
  const page = browser({ loading: true, hero: true });
  assert.equal(typeof page.listeners.pagereveal, "function");
  assert.equal(typeof page.listeners.pageswap, "function");
  assert.equal(typeof page.documentListeners.DOMContentLoaded, "function");
  assert.equal(page.search.hidden, true);
  assert.equal(page.fallback.hidden, false);
  assert.equal(page.observers.length, 0);
  assert.equal(page.root.classList.values.has("masthead-ready"), false);
  page.listeners.pagereveal({});
  assert.equal(page.observers.length, 0);
  page.revealDOM();
  page.documentListeners.DOMContentLoaded();
  assert.equal(page.search.hidden, false);
  assert.equal(page.root.style.values["--masthead-height"], "400px");
  assert.equal(page.observers.length, 1);
});

test("pagereveal initializes synchronously before the snapshot without duplicate ready-time setup", () => {
  const page = browser({ loading: true, hero: true });
  page.revealDOM();
  page.listeners.pagereveal({});
  assert.equal(page.search.hidden, false);
  assert.equal(page.root.style.values["--masthead-height"], "400px");
  assert.equal(page.observers.length, 1);
  page.documentListeners.DOMContentLoaded();
  page.searchHero.bottom = 450;
  page.listeners.pagereveal({});
  assert.equal(page.root.style.values["--masthead-height"], "450px");
  assert.equal(page.events.filter((event) => event === "submit listener").length, 1);
  assert.equal(page.observers.length, 1);
  assert.deepEqual(page.observers[0].nodes, [page.header, page.searchHero]);
  page.input.value = "once";
  page.submit();
  assert.equal(page.assignments.length, 1);
});

test("incoming saved-search motion skips until the app has restored the search layout", () => {
  const page = browser({ loading: true, hero: true });
  page.window.location.hash = "#search?q=assembly&all=1";
  page.revealDOM();
  let skipped = 0;
  const event = { viewTransition: { skipTransition() { skipped += 1; } } };
  page.listeners.pagereveal(event);
  assert.equal(skipped, 1);
  assert.equal(page.root.style.values["--masthead-height"], "400px");
  page.root.classList.add("js-enabled");
  page.listeners.pagereveal(event);
  assert.equal(skipped, 1, "A restored search keeps normal incoming motion.");
});

test("ordinary home and secondary-page reveals keep normal incoming motion", () => {
  for (const options of [{ hero: true }, { hero: false }]) {
    const page = browser(options);
    if (!options.hero) page.window.location.hash = "#search?all=1";
    let skipped = 0;
    page.listeners.pagereveal({ viewTransition: { skipTransition() { skipped += 1; } } });
    assert.equal(skipped, 0);
  }
});
