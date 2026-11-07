/* Asm package walkthrough. AGPL-3.0-or-later.
 * Copyright (c) 2026 ASM contributors.
 * The instruction explorer is a model; it does not execute the native CLI. */
"use strict";
(function () {
  const MAX_U64 = 18446744073709551615n;
  const INPUT_HELP = "Use a whole number from 0 to 18446744073709551615.";
  const INSTRUCTIONS = ["mov rax, rdi", "cmp rdi, rsi", "cmova rax, rsi", "ret"];

  function parseU64(value) {
    if (typeof value !== "string") throw new TypeError(INPUT_HELP);
    const text = value.trim();
    if (!/^[0-9]{1,20}$/.test(text)) throw new RangeError(INPUT_HELP);
    const number = BigInt(text);
    if (number > MAX_U64) throw new RangeError("The value is too large. " + INPUT_HELP);
    return number;
  }

  function walkMinimum(first, second, step = 0) {
    if (!Number.isInteger(step) || step < 0 || step > 4) throw new RangeError("Choose an instruction step from 0 to 4.");
    const a = parseU64(first);
    const b = parseU64(second);
    const above = a > b;
    const result = above ? b : a;
    let message = "Choose inputs, then step through the four instructions.";
    if (step === 1) message = "rax receives " + a + " from rdi.";
    if (step === 2) message = "Compare unsigned inputs. The first input is " + (above ? "above" : "not above") + " the second.";
    if (step === 3) message = above ? "The condition is true. rax receives " + b + " from rsi." : "The condition is false. rax remains " + a + ".";
    if (step === 4) message = "The function returns " + result + " in rax.";
    return {
      step,
      instruction: step ? INSTRUCTIONS[step - 1] : null,
      rdi: a.toString(), rsi: b.toString(),
      rax: step === 0 ? null : (step < 3 ? a : result).toString(),
      above: step < 2 ? null : above,
      result: result.toString(), returned: step === 4, message
    };
  }

  function mountExplorer(root) {
    const first = root.querySelector('[data-min-input="a"]');
    const second = root.querySelector('[data-min-input="b"]');
    const next = root.querySelector("[data-min-step]");
    if (!first || !second || !next) return;
    const status = root.querySelector("[data-min-status]");
    const registers = Array.from(root.querySelectorAll("[data-min-register]"));
    const lines = Array.from(root.querySelectorAll("[data-min-line]"));
    let step = 0;

    function highlight(current) {
      for (const line of lines) {
        const active = Number(line.getAttribute("data-min-line")) === current;
        line.classList.toggle("is-current", active);
        if (active) line.setAttribute("aria-current", "step");
        else line.removeAttribute("aria-current");
      }
    }

    function update() {
      let error = "";
      for (const [input, label] of [[first, "First input"], [second, "Second input"]]) {
        try {
          parseU64(input.value);
          input.setAttribute("aria-invalid", "false");
        } catch (problem) {
          input.setAttribute("aria-invalid", "true");
          if (!error) error = label + ": " + problem.message;
        }
      }
      next.disabled = Boolean(error);
      next.textContent = step === 4 ? "Restart" : "Step instruction";
      if (error) {
        for (const register of registers) register.textContent = "—";
        if (status) status.textContent = error;
        highlight(0);
        return;
      }
      const state = walkMinimum(first.value, second.value, step);
      for (const register of registers) register.textContent = state[register.getAttribute("data-min-register")] ?? "—";
      if (status) status.textContent = state.message;
      highlight(step);
    }

    for (const input of [first, second]) input.addEventListener("input", () => { step = 0; update(); });
    next.addEventListener("click", () => {
      if (next.disabled) return;
      step = (step + 1) % 5;
      update();
    });
    root.querySelector("[data-min-reset]")?.addEventListener("click", () => {
      first.value = "12"; second.value = "37"; step = 0; update();
    });
    update();
  }

  function mountPackageDemo(root) {
    if (!root) return false;
    const nav = root.querySelector("[data-demo-tabs]");
    const tabs = Array.from(root.querySelectorAll("[data-demo-tab]"));
    const panels = Array.from(root.querySelectorAll("[data-demo-panel]"));
    const names = ["find", "inspect", "use"];
    if (!nav || tabs.length !== 3 || panels.length !== 3) return false;
    const entries = names.map(name => ({ name,
      tab: tabs.find(tab => tab.getAttribute("data-demo-tab") === name),
      panel: panels.find(panel => panel.getAttribute("data-demo-panel") === name)
    }));
    if (entries.some(entry => !entry.tab || !entry.panel)) return false;

    function select(index, focus = false) {
      const selected = (index + entries.length) % entries.length;
      entries.forEach((entry, position) => {
        const active = position === selected;
        entry.tab.setAttribute("aria-selected", String(active));
        entry.tab.tabIndex = active ? 0 : -1;
        entry.panel.hidden = !active;
      });
      root.dataset.demoStep = entries[selected].name;
      if (focus) entries[selected].tab.focus();
    }

    nav.setAttribute("role", "tablist");
    nav.setAttribute("aria-orientation", "horizontal");
    entries.forEach((entry, index) => {
      entry.tab.setAttribute("role", "tab");
      entry.tab.setAttribute("aria-controls", entry.panel.getAttribute("id"));
      entry.panel.setAttribute("role", "tabpanel");
      entry.panel.setAttribute("aria-labelledby", entry.tab.getAttribute("id"));
      entry.tab.addEventListener("click", () => select(index));
      entry.tab.addEventListener("keydown", event => {
        if (event.altKey || event.ctrlKey || event.metaKey) return;
        let selected;
        if (event.key === "ArrowRight" || event.key === "ArrowDown") selected = index + 1;
        else if (event.key === "ArrowLeft" || event.key === "ArrowUp") selected = index - 1;
        else if (event.key === "Home") selected = 0;
        else if (event.key === "End") selected = entries.length - 1;
        else return;
        event.preventDefault();
        select(selected, true);
      });
    });
    select(0);
    mountExplorer(root);
    nav.hidden = false;
    root.dataset.demoReady = "true";
    return true;
  }

  if (typeof module !== "undefined" && module.exports) module.exports = { parseU64, walkMinimum, mountPackageDemo };
  if (typeof document !== "undefined") {
    const root = document.querySelector("[data-package-demo]");
    if (root) mountPackageDemo(root);
  }
})();
