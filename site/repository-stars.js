/* Fixed public repository observation; no visitor or search data. AGPL-3.0-or-later. */
"use strict";
(function () {
  const AGE = 300000, DAY = 86400000, LIMIT = 16384, CACHE = "asm.github.stubbi/asm.v1";
  const REPOSITORY = "stubbi/asm", LINK = "https://github.com/stubbi/asm", API = "https://api.github.com/repos/stubbi/asm";
  function exactCount(value) {
    return Number.isSafeInteger(value) && value >= 0 ? value.toLocaleString("en-US") : null;
  }
  function compactCount(value) {
    if (exactCount(value) === null) return null;
    if (value < 1000) return String(value);
    const units = [1000n, 1000000n, 1000000000n, 1000000000000n, 1000000000000000n], suffix = ["k", "M", "B", "T", "Q"];
    let index = 0;
    while (index + 1 < units.length && BigInt(value) >= units[index + 1]) index++;
    const scale = (value >= 100000 && value < 1000000) || (value >= 100000000 && value < 1000000000) ? 1n : 10n;
    const rounded = (BigInt(value) * scale + units[index] / 2n) / units[index];
    return String(rounded / scale) + (rounded % scale ? "." + rounded % scale : "") + suffix[index];
  }
  function normalizeSnapshot(value, now) {
    const fields = ["schema", "source", "repository", "observed_at", "stars", "stale", "refresh_error"];
    if (!value || Array.isArray(value) || Object.keys(value).length !== fields.length || !Object.keys(value).every((key) => fields.includes(key)) ||
        value.schema !== 1 || value.source !== "github" || value.repository !== REPOSITORY || value.stale !== false || value.refresh_error !== null ||
        exactCount(value.stars) === null || !Number.isFinite(now) || typeof value.observed_at !== "string" ||
        !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)$/.test(value.observed_at)) return null;
    const at = Date.parse(value.observed_at);
    if (!Number.isFinite(at) || at < 0 || at > now || now - at >= AGE || new Date(at).toISOString().slice(0, 19) !== value.observed_at.slice(0, 19)) return null;
    return { ...value };
  }
  function normalizeRepository(value, now) {
    if (!value || value.full_name !== REPOSITORY || value.html_url !== LINK || exactCount(value.stargazers_count) === null ||
        !Number.isSafeInteger(now) || now < 0 || now > 8640000000000000) return null;
    return normalizeSnapshot({ schema: 1, source: "github", repository: REPOSITORY, observed_at: new Date(now).toISOString(),
      stars: value.stargazers_count, stale: false, refresh_error: null }, now);
  }
  function snapshotURL(src, page) {
    if (typeof src !== "string") return null;
    try {
      const script = new URL(src, page), base = new URL(page);
      if (!["http:", "https:"].includes(script.protocol) || script.origin !== base.origin || script.username || script.password ||
          script.search || script.hash || !script.pathname.endsWith("/repository-stars.js")) return null;
      return new URL("registry/v1/github.json", script).href;
    } catch (_) { return null; }
  }
  function rateLimitDeadline(status, headers, now) {
    if (![403, 429].includes(status) || typeof headers?.get !== "function" || !Number.isSafeInteger(now)) return null;
    const after = headers.get("retry-after"), reset = headers.get("x-ratelimit-reset"), candidates = [];
    if (after) candidates.push(/^\d+$/.test(after) ? now + Number(after) * 1000 : Date.parse(after));
    if (reset && /^\d+$/.test(reset)) candidates.push(Number(reset) * 1000);
    const valid = candidates.filter((at) => Number.isSafeInteger(at) && at >= now && at <= now + DAY);
    return valid.length ? Math.max(...valid) : null;
  }
  if (typeof module !== "undefined" && module.exports) module.exports = { compactCount, exactCount, normalizeSnapshot, normalizeRepository, snapshotURL, rateLimitDeadline };
  if (typeof window === "undefined" || typeof document === "undefined") return;
  const endpoint = snapshotURL(document.currentScript?.src, window.location.href);
  const anchors = Array.from(document.querySelectorAll("a.github-stars")).filter((anchor) => anchor.href === LINK);
  function render(value) {
    anchors.forEach((anchor) => {
      anchor.querySelectorAll(".github-stars-count, .github-stars-observation").forEach((node) => node.remove());
      Array.from(anchor.children).filter((node) => node.classList.contains("sr-only") && node.textContent.startsWith("; observed ")).forEach((node) => node.remove());
      anchor.title = "";
      if (!value) return;
      const count = document.createElement("span"), visible = document.createElement("span"), exact = document.createElement("span"), context = document.createElement("span");
      count.className = "github-stars-count";
      visible.textContent = compactCount(value.stars); visible.setAttribute("aria-hidden", "true");
      exact.className = "sr-only"; exact.textContent = exactCount(value.stars) + " stars";
      context.className = "sr-only github-stars-observation"; context.textContent = "; observed " + value.observed_at + "; cached for up to 5 minutes";
      count.append(visible, exact); anchor.append(count, context);
      anchor.title = exactCount(value.stars) + " stars on GitHub; observed " + value.observed_at + "; cached for up to 5 minutes";
    });
  }
  render(null);
  if (!endpoint || !anchors.length) return;
  let current = null, pending = null, timer, retryAt = 0;
  try {
    const text = window.sessionStorage.getItem(CACHE);
    if (text && text.length <= LIMIT) current = normalizeSnapshot(JSON.parse(text), Date.now());
  } catch (_) { /* Storage is optional; the native link remains usable. */ }
  try {
    const at = JSON.parse(window.sessionStorage.getItem(CACHE + ".retry-at"));
    if (Number.isSafeInteger(at) && at > Date.now() && at <= Date.now() + DAY) retryAt = at;
  } catch (_) {}
  function remember() {
    try {
      if (current) {
        window.sessionStorage.removeItem(CACHE + ".retry-at");
        window.sessionStorage.setItem(CACHE, JSON.stringify(current));
      } else window.sessionStorage.setItem(CACHE + ".retry-at", String(retryAt));
    } catch (_) { /* A blocked cache cannot disable the link or future attempts. */ }
  }
  async function json(url) {
    const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 5000);
    let reader;
    try {
      const response = await fetch(url, { credentials: "omit", referrerPolicy: "no-referrer", redirect: "error", cache: "no-store",
        headers: { Accept: "application/json" }, signal: controller.signal });
      if (url === API) retryAt = Math.max(retryAt, rateLimitDeadline(response.status, response.headers, Date.now()) || 0);
      if (!response.ok || response.redirected || Number(response.headers.get("content-length")) > LIMIT || !response.body) return null;
      reader = response.body.getReader();
      const decoder = new TextDecoder("utf-8", { fatal: true });
      let bytes = 0, text = "";
      for (let reads = 0; reads < 128; reads++) {
        const { done, value } = await reader.read();
        if (done) return JSON.parse(text + decoder.decode());
        bytes += value.byteLength;
        if (bytes > LIMIT) return null;
        text += decoder.decode(value, { stream: true });
      }
      return null;
    } catch (_) { return null; }
    finally { clearTimeout(timeout); controller.abort(); if (reader) reader.cancel().catch(() => {}); }
  }
  function schedule(at) { clearTimeout(timer); timer = setTimeout(refresh, Math.max(1, at - Date.now())); }
  function refresh() {
    if (pending) return;
    current = normalizeSnapshot(current, Date.now()); render(current); clearTimeout(timer);
    if (current) { schedule(Date.parse(current.observed_at) + AGE); return; }
    if (document.hidden) return;
    if (Date.now() < retryAt) { schedule(retryAt); return; }
    let paused = false;
    pending = (async () => {
      current = normalizeSnapshot(await json(endpoint), Date.now());
      if (!current && document.hidden) { paused = true; return; }
      if (!current) current = normalizeRepository(await json(API), Date.now());
      retryAt = current ? Date.parse(current.observed_at) + AGE : Math.max(retryAt, Date.now() + AGE);
      remember();
    })().catch(() => { current = null; retryAt = Math.max(retryAt, Date.now() + AGE); remember(); }).finally(() => {
      pending = null; current = normalizeSnapshot(current, Date.now()); render(current);
      if (paused) { if (!document.hidden) refresh(); return; }
      if (current) schedule(Date.parse(current.observed_at) + AGE);
      else if (!document.hidden) schedule(retryAt);
    });
  }
  window.addEventListener("pageshow", refresh);
  document.addEventListener("visibilitychange", refresh);
  refresh();
}());
