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

  let attemptedForm, header, hero, lastHeight, observer, observerChecked, observedHeader, observedHero, fontsWatched;
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
      const height = bottom() + (Number.isFinite(window.scrollY) ? window.scrollY : 0);
      if (!Number.isFinite(height) || height <= 0) return;
      const root = document.documentElement;
      if (height !== lastHeight) {
        root.style.setProperty("--masthead-height", height + "px");
        lastHeight = height;
      }
      root.classList.add("masthead-ready");
    } catch (_) { /* Keep the ordinary header and hero backgrounds. */ }
  }
  function initialize(event) {
    enhanceSearch();
    header = document.querySelector(".site-header");
    hero = document.querySelector(".search-hero");
    if (!header?.querySelector(".masthead-surface")) return;
    measure();
    // An incoming snapshot can precede deferred search setup. Skip its motion
    // until app.js has synchronously restored the saved-search layout.
    if (hero && window.location.hash.startsWith("#search?") && !document.documentElement.classList.contains("js-enabled")) {
      event?.viewTransition?.skipTransition();
    }
    try {
      if (!observerChecked) {
        observerChecked = true;
        if (typeof ResizeObserver !== "undefined") observer = new ResizeObserver(measure);
      }
      if (observer && header !== observedHeader) { observer.observe(header); observedHeader = header; }
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
  window.addEventListener("pageshow", initialize);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initialize, { once: true });
  else initialize();
}());
