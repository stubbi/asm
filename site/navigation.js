/* Native search and optional cross-document framing. AGPL-3.0-or-later. */
"use strict";
(function () {
  function searchDestination(action, query, baseHref) {
    if (typeof query !== "string" || query.length > 512 || typeof action !== "string" || !action.trim()) return null;
    try {
      const base = new URL(baseHref);
      const destination = new URL(action, base);
      if (!["http:", "https:"].includes(base.protocol) || base.username || base.password ||
          destination.origin !== base.origin || destination.username || destination.password ||
          destination.search || destination.hash ||
          !(destination.pathname === "/" || destination.pathname.endsWith("/index.html"))) return null;
      if (destination.pathname.endsWith("/index.html")) destination.pathname = destination.pathname.slice(0, -10);
      const parameters = new URLSearchParams();
      if (query) parameters.set("q", query);
      parameters.set("all", "1");
      destination.hash = "search?" + parameters;
      return destination.href;
    } catch (_) { return null; }
  }

  if (typeof module !== "undefined" && module.exports) module.exports = { searchDestination };
  if (typeof window === "undefined" || typeof document === "undefined") return;

  let attemptedForm, header, hero, surface, lastHeight, lastHeaderHeight, restingHeight = 0, headerBorder = 0, largestHeaderHeight = 0;
  let observer, observerChecked, observedHeader, observedHero, fontsWatched, homeSearch, scrollFrame;
  function enhanceSearch() {
    const form = document.querySelector("[data-header-search]");
    const fallback = document.querySelector("[data-header-search-fallback]");
    try {
      const input = form?.querySelector('input[name="q"]');
      if (!input || form === attemptedForm) return;
      attemptedForm = form;
      if (!searchDestination(form.action, "", window.location.href)) return;
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        const destination = searchDestination(form.action, input.value, window.location.href);
        input.setCustomValidity("");
        if (!destination) {
          input.setCustomValidity(typeof input.value !== "string" || input.value.length > 512
            ? "Use no more than 512 characters." : "Package search is unavailable. Use Browse packages.");
          if (fallback) fallback.hidden = false;
          input.reportValidity();
          return;
        }
        try { window.location.assign(destination); }
        catch (_) {
          if (fallback) fallback.hidden = false;
          input.setCustomValidity("Search could not open. Use Browse packages.");
          input.reportValidity();
        }
      });
      input.addEventListener("input", () => input.setCustomValidity(""));
      form.hidden = false;
      if (fallback) fallback.hidden = true;
    } catch (_) { /* Leave the native catalog link available if enhancement fails. */ }
  }

  function bottom() {
    return Math.max(header.getBoundingClientRect().bottom, hero ? hero.getBoundingClientRect().bottom : -Infinity);
  }
  function measure() {
    try {
      const inner = header.querySelector(".header-inner") || header;
      const headerRect = header.getBoundingClientRect(), innerRect = inner.getBoundingClientRect();
      if (!homeSearch?.docked) {
        headerBorder = Math.max(0, headerRect.height - innerRect.height);
        restingHeight = headerRect.height;
      }
      const headerHeight = innerRect.height + headerBorder;
      const scroll = Number.isFinite(window.scrollY) ? window.scrollY : 0;
      const height = hero ? Math.max(headerHeight, hero.getBoundingClientRect().bottom + scroll) : headerHeight;
      if (!Number.isFinite(height) || height <= 0) return;
      const root = document.documentElement;
      largestHeaderHeight = Math.max(largestHeaderHeight, headerHeight);
      root.classList.toggle("header-static", Number.isFinite(window.innerHeight) && largestHeaderHeight > window.innerHeight / 2);
      if (headerHeight !== lastHeaderHeight) {
        root.style.setProperty("--header-height", headerHeight + "px");
        lastHeaderHeight = headerHeight;
      }
      root.classList.toggle("header-scrolled", scroll > 0);
      if (height !== lastHeight) {
        root.style.setProperty("--masthead-height", height + "px");
        lastHeight = height;
      }
      root.classList.add("masthead-ready");
    } catch (_) { /* Keep the ordinary header and hero backgrounds. */ }
  }

  function prepareHomeSearch() {
    const slot = hero?.querySelector(".hero-search-slot");
    const box = slot?.querySelector(".search-box");
    const form = document.querySelector("[data-header-search]");
    const original = form?.querySelector(".search-box");
    const owner = document.querySelector("#registry-controls");
    const input = box?.querySelector("#package-search");
    if (!box || !original || !owner || !input || form.hidden) return null;
    // The homepage has one real query control, including while it is expanded.
    original.querySelector('input[name="q"]')?.removeAttribute("name");
    const root = document.documentElement;
    let docked = false, composing = false, motion;
    const label = input.getAttribute("aria-labelledby");
    function apply(next) {
      if (next === docked) return;
      const active = document.activeElement;
      const focused = box.contains(active);
      const selection = focused && active === input
        ? [input.selectionStart, input.selectionEnd, input.selectionDirection] : null;
      if (next) {
        slot.style.height = box.getBoundingClientRect().height + "px";
        root.style.setProperty("--header-rest-height", restingHeight + "px");
        form.replaceChildren(box);
        owner.setAttribute("role", "presentation");
        input.setAttribute("aria-labelledby", "compact-search-label");
        root.classList.add("search-docked");
      } else {
        slot.append(box);
        form.replaceChildren(original);
        owner.setAttribute("role", "search");
        if (label === null) input.removeAttribute("aria-labelledby");
        else input.setAttribute("aria-labelledby", label);
        root.classList.remove("search-docked");
        slot.style.height = "";
      }
      docked = next;
      if (focused) {
        try {
          active.focus({ preventScroll: true });
          if (selection && Number.isInteger(selection[0]) && Number.isInteger(selection[1])) input.setSelectionRange(...selection);
        } catch (_) { /* Preserve the native control even if selection restoration is unavailable. */ }
      }
      measure();
    }
    function update(animate) {
      if (composing) return;
      const shortScreen = window.matchMedia?.("(max-width: 38.75rem) and (max-height: 24rem)").matches;
      const threshold = docked ? lastHeaderHeight + 32 : restingHeight + 16;
      const next = window.scrollY > 0 && !shortScreen && !root.classList.contains("header-static") && slot.getBoundingClientRect().top <= threshold;
      if (motion) {
        if (motion.target === next && (animate || next === docked)) return;
        const previous = motion;
        motion = null;
        previous.transition?.skipTransition();
        root.classList.remove("scroll-transition");
      }
      if (next === docked) return;
      if (!animate || typeof document.startViewTransition !== "function" ||
          window.matchMedia?.("(prefers-reduced-motion: reduce)").matches || document.hidden) {
        apply(next);
        return;
      }
      const current = { target: next };
      motion = current;
      root.classList.add("scroll-transition");
      try {
        current.transition = document.startViewTransition(() => { if (motion === current) apply(next); });
        // Skipped snapshots reject ready independently of finished.
        current.transition.ready?.catch(() => {});
        current.transition.updateCallbackDone?.catch(() => {});
        current.transition.finished.catch(() => {}).then(() => {
          if (motion !== current) return;
          motion = null;
          root.classList.remove("scroll-transition");
          scheduleScroll();
        });
      } catch (_) {
        motion = null;
        root.classList.remove("scroll-transition");
        apply(next);
      }
    }
    input.addEventListener("compositionstart", () => { composing = true; });
    input.addEventListener("compositionend", () => { composing = false; scheduleScroll(); });
    return { get docked() { return docked; }, update,
      resize() { if (!composing) apply(false); } };
  }
  function scheduleScroll() {
    if (scrollFrame) return;
    const refresh = () => { scrollFrame = null; measure(); homeSearch?.update(true); };
    if (typeof window.requestAnimationFrame === "function") scrollFrame = window.requestAnimationFrame(refresh);
    else refresh();
  }
  function initialize(event) {
    enhanceSearch();
    header = document.querySelector(".site-header");
    hero = document.querySelector(".search-hero");
    surface = surface || header?.querySelector(".masthead-surface");
    if (!surface) return;
    // The page-top canvas must not travel with the sticky navigation.
    if (surface.parentNode === header) document.body.insertBefore(surface, header);
    if (!homeSearch) homeSearch = prepareHomeSearch();
    if (event?.type === "resize") { largestHeaderHeight = 0; homeSearch?.resize(); }
    measure();
    homeSearch?.update(false);
    // An incoming snapshot can precede deferred search setup. Skip its motion
    // until app.js has synchronously restored the saved-search layout.
    if (hero && window.location.hash.startsWith("#search?") && !document.documentElement.classList.contains("js-enabled")) {
      event?.viewTransition?.skipTransition();
    }
    try {
      if (!observerChecked) {
        observerChecked = true;
        if (typeof ResizeObserver !== "undefined") observer = new ResizeObserver(() => { measure(); homeSearch?.update(false); });
      }
      const inner = header.querySelector(".header-inner") || header;
      if (observer && inner !== observedHeader) { observer.observe(inner); observedHeader = inner; }
      if (observer && hero && hero !== observedHero) { observer.observe(hero); observedHero = hero; }
    } catch (_) { /* Resize and page events still refresh the measurement. */ }
    if (!fontsWatched && document.fonts?.ready) {
      fontsWatched = true;
      document.fonts.ready.then(measure).catch(() => {});
    }
  }
  // This classic head script registers the incoming hook before the first
  // rendering opportunity. It never waits for assets or fetches page content.
  window.addEventListener("pagereveal", initialize);
  window.addEventListener("pageswap", (event) => {
    initialize();
    if (header && bottom() <= 0) event.viewTransition?.skipTransition();
  });
  window.addEventListener("resize", initialize);
  window.addEventListener("scroll", scheduleScroll, { passive: true });
  window.addEventListener("pageshow", initialize);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initialize, { once: true });
  else initialize();
}());
