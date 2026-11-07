"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const modulePath = path.join(__dirname, "../site/package-demo.js");
const behavior = fs.existsSync(modulePath) ? require(modulePath) : {};
const get = name => {
  assert.equal(typeof behavior[name], "function", name + " must be implemented");
  return behavior[name];
};

test("decimal input retains the full unsigned 64-bit range", () => {
  const parse = get("parseU64");
  assert.equal(parse("0"), 0n);
  assert.equal(parse(" 00012 "), 12n);
  assert.equal(parse("9007199254740993"), 9007199254740993n);
  assert.equal(parse("18446744073709551615"), 18446744073709551615n);
});

test("invalid and out-of-range input has a useful error", () => {
  const parse = get("parseU64");
  for (const value of ["", "-1", "1.5", "1e3", "12 37", "0x10", "Infinity", "+12", "18446744073709551616", "9".repeat(1000)]) {
    assert.throws(() => parse(value), /whole number|too large/i, value);
  }
  assert.throws(() => parse(12), /whole number/i);
});

test("the walkthrough follows the actual four source instructions", () => {
  const walk = get("walkMinimum");
  const source = fs.readFileSync(path.join(__dirname, "../examples/math/targets/x86_64-linux/src/min.s"), "utf8");
  const instructions = source.split("asm_u64_min:\n")[1].split("\n").slice(0, 4).map(line => line.trim());
  assert.deepEqual([1, 2, 3, 4].map(step => walk("12", "37", step).instruction), instructions);
  assert.equal(walk("12", "37", 0).rax, null);
  assert.equal(walk("12", "37", 1).rax, "12");
  assert.equal(walk("12", "37", 1).above, null);
  assert.equal(walk("12", "37", 2).above, false);
  assert.equal(walk("12", "37", 3).rax, "12");
  assert.equal(walk("12", "37", 4).returned, true);
});

test("cmova uses unsigned comparison for reversed, equal, and high-bit inputs", () => {
  const walk = get("walkMinimum");
  assert.equal(walk("37", "12", 2).above, true);
  assert.equal(walk("37", "12", 3).rax, "12");
  const equal = walk("18446744073709551615", "18446744073709551615", 4);
  assert.equal(equal.above, false);
  assert.equal(equal.rax, "18446744073709551615");
  const high = walk("9223372036854775808", "9223372036854775807", 4);
  assert.equal(high.above, true);
  assert.equal(high.result, "9223372036854775807");
  assert.equal(walk("0", "18446744073709551615", 4).rax, "0");
});

test("the model refuses an invalid instruction step", () => {
  const walk = get("walkMinimum");
  for (const step of [-1, 5, 1.5, NaN]) assert.throws(() => walk("12", "37", step), /step/i);
});

// A small DOM boundary fixture lets these tests exercise events, focus, and
// accessible state without installing a browser or a second test framework.
function node(attributes = {}) {
  const classes = new Set();
  return {
    attributes: { ...attributes }, dataset: {}, hidden: false, disabled: false,
    tabIndex: 0, textContent: "", value: "", listeners: {},
    classList: { toggle(name, enabled) { if (enabled) classes.add(name); else classes.delete(name); }, contains: name => classes.has(name) },
    getAttribute(name) { return this.attributes[name] ?? null; },
    setAttribute(name, value) { this.attributes[name] = String(value); },
    removeAttribute(name) { delete this.attributes[name]; },
    addEventListener(name, callback) { this.listeners[name] = callback; },
    focus() { this.focused = true; },
    send(name, extra = {}) { const event = { target: this, prevented: false, preventDefault() { this.prevented = true; }, ...extra }; this.listeners[name]?.(event); return event; }
  };
}

function fixture() {
  const root = node();
  const nav = node(); nav.hidden = true;
  const names = ["find", "inspect", "use"];
  const tabs = names.map(name => node({ "data-demo-tab": name, id: "demo-tab-" + name }));
  const panels = names.map(name => node({ "data-demo-panel": name, id: "demo-panel-" + name }));
  panels.forEach((panel, index) => { panel.hidden = index > 0; });
  const a = node(); a.value = "12";
  const b = node(); b.value = "37";
  const step = node(), reset = node(), status = node();
  const registers = ["rdi", "rsi", "rax"].map(name => node({ "data-min-register": name }));
  const lines = [1, 2, 3, 4].map(index => node({ "data-min-line": String(index) }));
  const single = new Map([
    ["[data-demo-tabs]", nav], ["[data-min-input=\"a\"]", a], ["[data-min-input=\"b\"]", b],
    ["[data-min-step]", step], ["[data-min-reset]", reset], ["[data-min-status]", status]
  ]);
  const lists = new Map([["[data-demo-tab]", tabs], ["[data-demo-panel]", panels], ["[data-min-register]", registers], ["[data-min-line]", lines]]);
  root.querySelector = selector => single.get(selector) || null;
  root.querySelectorAll = selector => lists.get(selector) || [];
  return { root, nav, tabs, panels, a, b, step, reset, status, registers, lines };
}

test("tabs enable progressively without moving focus and keep one panel selected", () => {
  const f = fixture();
  get("mountPackageDemo")(f.root);
  assert.equal(f.nav.hidden, false);
  assert.equal(f.root.dataset.demoReady, "true");
  assert.equal(f.root.dataset.demoStep, "find");
  assert.ok(f.tabs.every(tab => !tab.focused));
  assert.deepEqual(f.tabs.map(tab => tab.getAttribute("aria-selected")), ["true", "false", "false"]);
  assert.deepEqual(f.tabs.map(tab => tab.tabIndex), [0, -1, -1]);
  f.tabs[1].send("click");
  assert.equal(f.root.dataset.demoStep, "inspect");
  assert.deepEqual(f.panels.map(panel => panel.hidden), [true, false, true]);
  assert.deepEqual(f.tabs.map(tab => tab.getAttribute("aria-selected")), ["false", "true", "false"]);
});

test("horizontal tabs support arrow, Home, and End keys without taking browser shortcuts", () => {
  const f = fixture();
  get("mountPackageDemo")(f.root);
  assert.equal(f.nav.getAttribute("aria-orientation"), "horizontal");
  assert.equal(f.tabs[0].send("keydown", { key: "ArrowLeft" }).prevented, true);
  assert.equal(f.root.dataset.demoStep, "use");
  assert.equal(f.tabs[2].focused, true);
  f.tabs[2].send("keydown", { key: "Home" });
  assert.equal(f.root.dataset.demoStep, "find");
  f.tabs[0].send("keydown", { key: "ArrowDown" });
  assert.equal(f.root.dataset.demoStep, "inspect");
  f.tabs[1].send("keydown", { key: "End" });
  assert.equal(f.root.dataset.demoStep, "use");
  for (const modifier of ["altKey", "ctrlKey", "metaKey"]) {
    assert.equal(f.tabs[2].send("keydown", { key: "Home", [modifier]: true }).prevented, false);
    assert.equal(f.root.dataset.demoStep, "use", "Browser shortcuts must not switch tabs");
  }
});

test("stepping updates registers and status with a stable action label until restart", () => {
  const f = fixture();
  get("mountPackageDemo")(f.root);
  assert.equal(f.registers[2].textContent, "—");
  assert.equal(f.step.textContent, "Step instruction");
  f.a.value = "37"; f.a.send("input");
  f.b.value = "12"; f.b.send("input");
  f.step.send("click");
  assert.equal(f.registers[2].textContent, "37");
  assert.equal(f.lines[0].getAttribute("aria-current"), "step");
  assert.equal(f.step.textContent, "Step instruction");
  assert.match(f.status.textContent, /rax receives 37 from rdi/i);
  f.step.send("click");
  assert.equal(f.step.textContent, "Step instruction");
  assert.match(f.status.textContent, /first input is above the second/i);
  f.step.send("click");
  assert.equal(f.registers[2].textContent, "12");
  assert.equal(f.step.textContent, "Step instruction");
  assert.match(f.status.textContent, /rax receives 12 from rsi/i);
  f.step.send("click");
  assert.equal(f.step.textContent, "Restart");
  assert.match(f.status.textContent, /returns 12/i);
  f.step.send("click");
  assert.equal(f.registers[2].textContent, "—");
  assert.ok(f.lines.every(line => !line.classList.contains("is-current")));
  assert.equal(f.step.textContent, "Step instruction");
});

test("input errors clear stale output, disable stepping, and recover after correction", () => {
  const f = fixture();
  get("mountPackageDemo")(f.root);
  f.step.send("click");
  assert.equal(f.registers[2].textContent, "12");
  f.b.value = "1.5"; f.b.send("input");
  assert.equal(f.b.getAttribute("aria-invalid"), "true");
  assert.equal(f.step.disabled, true);
  assert.deepEqual(f.registers.map(register => register.textContent), ["—", "—", "—"]);
  assert.match(f.status.textContent, /Second input.*whole number/i);
  f.b.value = "0"; f.b.send("input");
  assert.equal(f.b.getAttribute("aria-invalid"), "false");
  assert.equal(f.step.disabled, false);
  assert.deepEqual(f.registers.map(register => register.textContent), ["12", "0", "—"]);
  for (let instruction = 0; instruction < 4; instruction++) f.step.send("click");
  assert.equal(f.registers[2].textContent, "0");
  assert.match(f.status.textContent, /returns 0/i);
  f.reset.send("click");
  assert.equal(f.a.value, "12");
  assert.equal(f.b.value, "37");
  assert.deepEqual(f.registers.map(register => register.textContent), ["12", "37", "—"]);
  assert.equal(f.step.textContent, "Step instruction");
});
