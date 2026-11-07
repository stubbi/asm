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

function browser({ hero = false, observer = true, action = "../index.html", form = true, listenFails = false,
  loading = false, scrollY = 0, innerHeight = 900, reduced = false, shortScreen = false, transitions = false } = {}) {
  assert.ok(existsSync(source), "The shared native search enhancement is not implemented.");
  const events = [], assignments = [], listeners = {}, listenerOptions = {}, observers = [], documentListeners = {};
  const frames = new Map(), transitionRuns = [], submissions = [], networkRequests = [], historyCalls = [];
  let available = !loading, frameId = 0, document, window;
  function node(tag, attributes = {}) {
    const attrs = { ...attributes }, handlers = {}, children = [];
    const element = { tagName: tag.toUpperCase(), nodeType: 1, children, parentNode: null, listeners: {}, focusCalls: [],
      style: { values: {}, setProperty(name, value) { events.push("surface size"); this.values[name] = value; },
        getPropertyValue(name) { return this.values[name] || ""; }, removeProperty(name) { delete this.values[name]; } },
      classList: { values: new Set((attrs.class || "").split(/\s+/).filter(Boolean)),
        add(...values) { events.push("surface ready"); for (const value of values) this.values.add(value); },
        remove(...values) { for (const value of values) this.values.delete(value); },
        contains(value) { return this.values.has(value); },
        toggle(value, force) { const added = force === undefined ? !this.values.has(value) : force;
          if (added) this.values.add(value); else this.values.delete(value); return added; } },
      setAttribute(name, value) { attrs[name] = String(value); },
      getAttribute(name) { return Object.hasOwn(attrs, name) ? attrs[name] : null; },
      hasAttribute(name) { return Object.hasOwn(attrs, name); },
      removeAttribute(name) { delete attrs[name]; },
      contains(child) { return child === this || children.some((item) => item.contains(child)); },
      appendChild(child) { return this.insertBefore(child, null); },
      append(...items) { for (const child of items) this.appendChild(child); },
      insertBefore(child, before) {
        if (child.parentNode) {
          if (document?.activeElement && child.contains(document.activeElement)) document.activeElement = document.body;
          child.parentNode.children.splice(child.parentNode.children.indexOf(child), 1);
        }
        const index = before ? children.indexOf(before) : children.length;
        assert.ok(index >= 0, "insertBefore requires a child of the destination.");
        children.splice(index, 0, child); child.parentNode = this; return child;
      },
      replaceChildren(...items) { for (const child of [...children]) child.remove(); this.append(...items); },
      removeChild(child) { assert.equal(child.parentNode, this); child.remove(); return child; },
      remove() { if (this.parentNode) this.parentNode.children.splice(this.parentNode.children.indexOf(this), 1); this.parentNode = null; },
      matches(selector) {
        if (selector.startsWith("#")) return this.id === selector.slice(1);
        if (selector.startsWith(".")) return this.classList.contains(selector.slice(1));
        const match = /^([a-z]+)?(?:\[([^=\]]+)(?:=["']?([^"'\]]+)["']?)?\])?$/.exec(selector);
        return Boolean(match && (!match[1] || match[1].toUpperCase() === this.tagName) &&
          (!match[2] || this.hasAttribute(match[2]) && (match[3] === undefined || this.getAttribute(match[2]) === match[3])));
      },
      querySelectorAll(selector) { return children.flatMap((child) => [child, ...child.querySelectorAll("*")])
        .filter((child) => selector === "*" || selector.split(",").some((part) => child.matches(part.trim()))); },
      querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
      closest(selector) { for (let current = this; current; current = current.parentNode) if (current.matches(selector)) return current; return null; },
      addEventListener(name, callback, options) {
        if (listenFails && this.hasAttribute("data-header-search")) throw new Error("unavailable listener");
        this.listeners[name] = callback; (handlers[name] ||= []).push(callback); events.push(name + " listener");
      },
      dispatch(name, data = {}) { const event = { type: name, target: this, preventDefault() { this.defaultPrevented = true; }, ...data };
        for (let current = this; current; current = current.parentNode) {
          event.currentTarget = current; for (const callback of current._handlers[name] || []) callback(event);
        }
        documentListeners[name]?.(event); return event;
      },
      _handlers: handlers,
      focus(options) { document.activeElement = this; this.focusCalls.push(options); },
      setSelectionRange(start, end, direction = "none") { this.selectionStart = start; this.selectionEnd = end; this.selectionDirection = direction; },
      get form() { return this.getAttribute("form") ? document.getElementById(this.getAttribute("form")) : this.closest("form"); },
      requestSubmit(submitter) { submissions.push(this); return this.dispatch("submit", { submitter }); },
      getBoundingClientRect() { return { top: 0, bottom: 0, height: 0, left: 0, width: 600 }; },
      get offsetHeight() { return this.getBoundingClientRect().height; },
      get offsetWidth() { return this.getBoundingClientRect().width; },
      value: "", validityMessage: "", reports: 0, selectionStart: 0, selectionEnd: 0, selectionDirection: "none",
      setCustomValidity(message) { this.validityMessage = message; }, reportValidity() { this.reports += 1; }
    };
    for (const name of ["id", "name", "action"]) Object.defineProperty(element, name, {
      get() { return this.getAttribute(name) || ""; }, set(value) { this.setAttribute(name, value); }
    });
    Object.defineProperty(element, "parentElement", { get() { return this.parentNode; } });
    Object.defineProperty(element, "hidden", { get() { return this.hasAttribute("hidden"); },
      set(value) { if (value) this.setAttribute("hidden", ""); else { this.removeAttribute("hidden"); if (this.hasAttribute("data-header-search")) events.push("form shown"); } } });
    return element;
  }
  const root = node("html"), body = node("body"); root.append(body);
  const surface = node("div", { class: "masthead-surface" });
  const header = node("header", { class: "site-header" });
  const headerInner = node("div", { class: "header-inner" });
  header.height = 80; header.bottom = 80; header.expandedHeight = 140;
  header.getBoundingClientRect = () => ({ top: 0, bottom: header.bottom, height: header.height });
  const input = node("input", { id: "header-package-search", name: "q", type: "search" });
  const headerBox = node("div", { class: "search-box header-search-box" }); headerBox.append(input);
  const search = node("form", { class: "header-search", "data-header-search": "", action, hidden: "", role: "search" }); search.append(headerBox);
  const fallback = node("a", { "data-header-search-fallback": "" });
  if (form) headerInner.append(search); headerInner.append(fallback); header.append(surface, headerInner); body.append(header);
  const searchHero = node("section", { class: "search-hero" }); searchHero.documentBottom = 400;
  searchHero.getBoundingClientRect = () => ({ top: 80 - window.scrollY,
    bottom: searchHero.bottom ?? searchHero.documentBottom - window.scrollY, height: searchHero.documentBottom - 80 });
  const heroForm = node("form", { id: "registry-controls", role: "search" });
  const slot = node("div", { class: "hero-search-slot" }); slot.documentTop = 244;
  const heroBox = node("div", { class: "search-box" });
  const heroInput = node("input", { id: "package-search", name: "q", type: "search", form: "registry-controls" });
  const heroButton = node("button", { id: "search-submit", type: "submit", form: "registry-controls" });
  heroBox.getBoundingClientRect = () => ({ top: slot.documentTop - window.scrollY, bottom: slot.documentTop - window.scrollY + 56, height: 56, width: 600 });
  slot.getBoundingClientRect = () => { const height = slot.children.includes(heroBox) ? 56 : parseFloat(slot.style.height || slot.style.minHeight || "0");
    return { top: slot.documentTop - window.scrollY, bottom: slot.documentTop - window.scrollY + height, height, width: 600 }; };
  heroBox.append(heroInput, heroButton); slot.append(heroBox); heroForm.append(slot); searchHero.append(heroForm);
  if (hero) body.append(searchHero);
  headerInner.getBoundingClientRect = () => { const height = search.contains(heroBox) ? header.expandedHeight : header.height;
    return { top: 0, bottom: height, height, width: 900 }; };
  document = { documentElement: root, body, activeElement: body, readyState: loading ? "loading" : "complete",
    addEventListener(name, listener) { documentListeners[name] = listener; },
    querySelector(selector) { return available ? root.querySelector(selector) : null; },
    querySelectorAll(selector) { return available ? root.querySelectorAll(selector) : []; },
    getElementById(id) { return this.querySelector("#" + id); } };
  window = { location: { href: "https://asm.build/stats/", hash: "", assign(value) { assignments.push(value); } }, scrollY, innerHeight,
    addEventListener(name, listener, options) { listeners[name] = listener; listenerOptions[name] = options; },
    matchMedia(query) { return { matches: query.includes("prefers-reduced-motion") ? reduced : shortScreen, addEventListener() {} }; },
    requestAnimationFrame(callback) { const id = ++frameId; frames.set(id, callback); return id; },
    cancelAnimationFrame(id) { frames.delete(id); },
    getComputedStyle() { return { borderBottomWidth: "0px", borderTopWidth: "0px" }; },
    fetch(...args) { networkRequests.push(args); assert.fail("Navigation must not fetch page content or search terms."); },
    history: { pushState(...args) { historyCalls.push(args); assert.fail("Scroll must not change history."); },
      replaceState(...args) { historyCalls.push(args); assert.fail("Scroll must not change history."); } } };
  if (transitions) document.startViewTransition = (callback) => {
    let finish, reveal, rejectReady;
    const finished = new Promise((resolve) => { finish = resolve; });
    const ready = new Promise((resolve, reject) => { reveal = resolve; rejectReady = reject; });
    const updateCallbackDone = Promise.resolve().then(callback).then(() => { if (!run.skipped) reveal(); });
    const run = { finished, ready, updateCallbackDone, skipped: 0,
      skipTransition() { this.skipped += 1; rejectReady(new Error("The skipped snapshot cannot become ready.")); finish(); }, finish };
    transitionRuns.push(run); return run;
  };
  const context = { window, document, URL, URLSearchParams, Promise,
    requestAnimationFrame: window.requestAnimationFrame, cancelAnimationFrame: window.cancelAnimationFrame,
    getComputedStyle: window.getComputedStyle,
    fetch: window.fetch };
  if (observer) context.ResizeObserver = class {
    constructor(callback) { this.callback = callback; this.nodes = []; observers.push(this); }
    observe(element) { this.nodes.push(element); }
  };
  vm.runInNewContext(readFileSync(source, "utf8"), context);
  function submit() {
    let prevented = false;
    search.listeners.submit({ preventDefault() { prevented = true; } });
    assert.equal(prevented, true, "Search terms must never enter a native GET query.");
  }
  function flushFrame() { const pending = [...frames.values()]; frames.clear(); for (const callback of pending) callback(); }
  return { window, document, root, body, search, input, headerBox, fallback, events, assignments, listeners, listenerOptions,
    observers, header, headerInner, surface, searchHero, heroForm, slot, heroBox, heroInput, heroButton, submissions, submit,
    frames, transitionRuns, networkRequests, historyCalls, flushFrame, scroll(value) { window.scrollY = value; listeners.scroll?.({ type: "scroll" }); },
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
  assert.deepEqual(page.observers[0].nodes, [page.headerInner, page.searchHero]);
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
    page.header.height += 20;
    page.listeners[event]({ type: event });
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
  assert.deepEqual(page.observers[0].nodes, [page.headerInner, page.searchHero]);
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

test("the masthead surface leaves the sticky header and measurements do not grow with scroll position", () => {
  const page = browser({ hero: true });
  assert.equal(page.surface.parentNode, page.body);
  assert.ok(page.body.children.indexOf(page.surface) < page.body.children.indexOf(page.header));
  assert.equal(page.root.style.values["--masthead-height"], "400px");
  page.scroll(800);
  page.flushFrame();
  assert.equal(page.header.getBoundingClientRect().bottom, 80, "The header stays sticky in the fixture.");
  assert.equal(page.root.style.values["--masthead-height"], "400px");
  assert.equal(page.root.style.values["--header-height"], "140px");
  const inner = browser({ hero: false, scrollY: 1200 });
  assert.equal(inner.root.style.values["--masthead-height"], "80px");
  assert.equal(inner.root.style.values["--header-height"], "80px");
});

test("scroll transfers the same focused search control and preserves the app form without query copies", () => {
  const page = browser({ hero: true });
  const field = page.heroInput, box = page.heroBox;
  const originalHeight = page.slot.getBoundingClientRect().height;
  field.value = "math あ & hello";
  field.focus();
  field.setSelectionRange(2, 6, "backward");
  page.scroll(220);
  page.flushFrame();
  assert.equal(box.parentNode, page.search);
  assert.equal(page.search.querySelector("#package-search"), field);
  assert.equal(page.document.activeElement, field);
  assert.equal(field.value, "math あ & hello");
  assert.deepEqual([field.selectionStart, field.selectionEnd, field.selectionDirection], [2, 6, "backward"]);
  assert.equal(field.focusCalls.at(-1)?.preventScroll, true);
  assert.equal(field.form, page.heroForm);
  assert.equal(page.heroButton.form, page.heroForm);
  assert.equal(field.getAttribute("aria-labelledby"), "compact-search-label");
  assert.equal(page.heroForm.getAttribute("role"), "presentation");
  assert.equal(page.slot.getBoundingClientRect().height, originalHeight);
  assert.equal(page.headerBox.contains(field), false, "The placeholder never receives a copied query.");
  assert.equal(page.input.value, "");
  assert.equal(page.input.getAttribute("name"), null);
  assert.equal(page.document.querySelectorAll('input[name="q"]').length, 1);
  page.heroButton.form.requestSubmit(page.heroButton);
  assert.deepEqual(page.submissions, [page.heroForm]);
  assert.deepEqual(page.assignments, []);
  page.scroll(0);
  page.flushFrame();
  assert.equal(box.parentNode, page.slot);
  assert.equal(page.search.querySelector(".search-box"), page.headerBox);
  assert.equal(page.document.activeElement, field);
  assert.equal(field.value, "math あ & hello");
  assert.equal(field.getAttribute("aria-labelledby"), null);
  assert.equal(page.heroForm.getAttribute("role"), "search");
  assert.equal(page.document.querySelectorAll('input[name="q"]').length, 1);
  assert.equal(page.slot.getBoundingClientRect().height, originalHeight);
  assert.deepEqual(page.assignments, []);
  assert.deepEqual(page.networkRequests, []);
  assert.deepEqual(page.historyCalls, []);
});

test("scroll work is passive and coalesced while the slot boundary has stable hysteresis", () => {
  const page = browser({ hero: true });
  assert.equal(page.listenerOptions.scroll?.passive, true);
  page.scroll(148); // Slot top96 = resting header80 +16.
  page.scroll(149);
  page.scroll(148);
  assert.equal(page.frames.size, 1);
  assert.equal(page.heroBox.parentNode, page.slot);
  page.flushFrame();
  assert.equal(page.heroBox.parentNode, page.search);
  page.scroll(72); // Slot top172 = expanded header140 +32.
  page.flushFrame();
  assert.equal(page.heroBox.parentNode, page.search);
  page.scroll(71);
  page.flushFrame();
  assert.equal(page.heroBox.parentNode, page.slot);
  page.scroll(147); // Slot top97 must not immediately re-dock.
  page.flushFrame();
  assert.equal(page.heroBox.parentNode, page.slot);
});

test("a compact results hero restores its focused field at the top and during negative overscroll", () => {
  for (const top of [0, -18]) {
    const page = browser({ hero: true });
    const field = page.heroInput;
    field.value = "math あ";
    field.focus();
    field.setSelectionRange(1, 4, "backward");
    page.header.expandedHeight = 196;
    page.scroll(220);
    page.flushFrame();
    assert.equal(page.heroBox.parentNode, page.search);
    // Search results shorten the hero while the expanded sticky header remains tall.
    page.slot.documentTop = 160;
    page.scroll(top);
    page.flushFrame();
    assert.equal(page.heroBox.parentNode, page.slot);
    assert.equal(page.document.activeElement, field);
    assert.equal(field.value, "math あ");
    assert.deepEqual([field.selectionStart, field.selectionEnd, field.selectionDirection], [1, 4, "backward"]);
    assert.equal(field.form, page.heroForm);
    assert.equal(field.getAttribute("aria-labelledby"), null);
    assert.equal(page.heroForm.getAttribute("role"), "search");
    assert.equal(page.root.classList.contains("search-docked"), false);
    assert.equal(page.root.style.values["--header-height"], "80px");
    assert.deepEqual(page.assignments, []);
    assert.deepEqual(page.networkRequests, []);
  }
});

test("composition retains the active field until compositionend applies the current position", () => {
  const page = browser({ hero: true });
  page.heroInput.focus();
  page.heroInput.dispatch("compositionstart");
  page.heroInput.value = "組み立て";
  page.scroll(220);
  page.flushFrame();
  assert.equal(page.heroBox.parentNode, page.slot);
  assert.equal(page.document.activeElement, page.heroInput);
  page.heroInput.dispatch("compositionend");
  page.flushFrame();
  assert.equal(page.heroBox.parentNode, page.search);
  assert.equal(page.heroInput.value, "組み立て");
  assert.equal(page.document.activeElement, page.heroInput);
  assert.deepEqual(page.assignments, []);
});

test("restored scroll positions initialize immediately with reduced motion or no transition API", () => {
  for (const options of [{ reduced: true, transitions: true }, { transitions: false }]) {
    const page = browser({ hero: true, scrollY: 220, observer: false, ...options });
    assert.equal(page.heroBox.parentNode, page.search, "Initial restoration must not wait for animation.");
    assert.equal(page.transitionRuns.length, 0);
    page.header.expandedHeight = 196;
    page.listeners.resize({ type: "resize" });
    page.flushFrame();
    assert.equal(page.root.style.values["--header-height"], "196px");
    page.window.scrollY = 0;
    page.listeners.pageshow({ type: "pageshow", persisted: true });
    assert.equal(page.heroBox.parentNode, page.slot, "Back/forward restoration must apply the current viewport.");
    assert.equal(page.transitionRuns.length, 0);
    assert.deepEqual(page.assignments, []);
  }
});

test("a short narrow viewport retains the original form instead of covering it with an expanded sticky header", () => {
  const page = browser({ hero: true, scrollY: 220, shortScreen: true, transitions: true });
  assert.equal(page.heroBox.parentNode, page.slot);
  page.scroll(600);
  page.flushFrame();
  assert.equal(page.heroBox.parentNode, page.slot);
  assert.equal(page.heroInput.form, page.heroForm);
  assert.equal(page.heroForm.getAttribute("role"), "search");
  assert.equal(page.transitionRuns.length, 0);
  assert.deepEqual(page.networkRequests, []);
});

test("an enlarged header becomes static without moving the search and recovers after an actual resize", () => {
  const page = browser({ hero: true, innerHeight: 568 });
  page.heroInput.value = "large text search";
  page.header.height = 715;
  page.header.bottom = 715;
  page.observers[0].callback();
  assert.equal(page.root.classList.contains("header-static"), true);
  page.scroll(1000);
  page.flushFrame();
  assert.equal(page.heroBox.parentNode, page.slot);
  assert.equal(page.heroInput.value, "large text search");
  assert.equal(page.heroInput.form, page.heroForm);
  assert.equal(page.heroForm.getAttribute("role"), "search");
  assert.equal(page.document.activeElement, page.body);
  page.header.height = 120;
  page.header.bottom = 120;
  page.window.innerHeight = 900;
  page.listeners.resize({ type: "resize" });
  assert.equal(page.root.classList.contains("header-static"), false);
  assert.equal(page.heroBox.parentNode, page.search);
  assert.equal(page.heroInput.value, "large text search");
  assert.deepEqual(page.networkRequests, []);
});

test("an oversized expanded search returns to the hero and stays there until resize without oscillation", () => {
  const page = browser({ hero: true, innerHeight: 300 });
  assert.equal(page.root.classList.contains("header-static"), false);
  page.header.expandedHeight = 196;
  page.scroll(220);
  page.flushFrame();
  page.observers[0].callback();
  assert.equal(page.heroBox.parentNode, page.slot);
  assert.equal(page.root.classList.contains("header-static"), true);
  assert.equal(page.root.style.values["--header-height"], "80px");
  for (const position of [225, 215, 220]) {
    page.scroll(position);
    page.flushFrame();
    page.observers[0].callback();
    assert.equal(page.heroBox.parentNode, page.slot);
    assert.equal(page.root.classList.contains("header-static"), true);
  }
  page.window.innerHeight = 900;
  page.header.expandedHeight = 140;
  page.listeners.resize({ type: "resize" });
  assert.equal(page.root.classList.contains("header-static"), false);
  assert.equal(page.heroBox.parentNode, page.search);
  assert.deepEqual(page.assignments, []);
});

test("resize immediately restores the docked field while an earlier transition is awaiting completion", async () => {
  const page = browser({ hero: true, transitions: true });
  const field = page.heroInput;
  field.value = "resize あ";
  field.focus();
  field.setSelectionRange(1, 4, "backward");
  page.scroll(220);
  page.flushFrame();
  const transition = page.transitionRuns[0];
  try {
    await transition.updateCallbackDone;
    assert.equal(page.heroBox.parentNode, page.search);
    // Its DOM update is complete, but the animation's finished promise is still pending.
    page.listeners.resize({ type: "resize" });
    assert.equal(page.heroBox.parentNode, page.search, "Resize must restore the current layout without waiting for animation completion.");
    assert.equal(page.document.activeElement, field);
    assert.equal(field.value, "resize あ");
    assert.deepEqual([field.selectionStart, field.selectionEnd, field.selectionDirection], [1, 4, "backward"]);
    assert.equal(field.form, page.heroForm);
    assert.equal(page.heroForm.getAttribute("role"), "presentation");
    assert.deepEqual(page.assignments, []);
    assert.deepEqual(page.networkRequests, []);
  } finally {
    for (const pending of page.transitionRuns) pending.finish();
    await Promise.resolve();
  }
});

test("rapid directions skip an active optional transition and finish at the latest requested position", async () => {
  const page = browser({ hero: true, transitions: true });
  page.scroll(220);
  page.flushFrame();
  assert.equal(page.transitionRuns.length, 1);
  for (const position of [0, 220, 0, 220, 0]) {
    page.scroll(position);
    page.flushFrame();
  }
  assert.ok(page.transitionRuns[0].skipped > 0, "An obsolete transition cannot delay the latest scroll state.");
  assert.ok(page.transitionRuns.every((transition) => transition.skipped > 0), "Every obsolete snapshot must be cancelled before a new one can replace it.");
  for (let round = 0; round < 4; round += 1) {
    await Promise.resolve();
    for (const transition of page.transitionRuns) transition.finish();
    await Promise.resolve();
    page.flushFrame();
  }
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(page.heroBox.parentNode, page.slot);
  assert.equal(page.root.classList.contains("search-docked"), false);
  assert.equal(page.heroForm.getAttribute("role"), "search");
  assert.deepEqual(page.assignments, []);
});
