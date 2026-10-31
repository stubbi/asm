"use strict";

// The index is generated from accepted records. The UI does not invent records,
// infer verification from a checksum, or send searches to another service.
(function () {
  const evidenceLabels = {
    metadata: "Metadata",
    artifacts: "Artifacts",
    provenance: "Provenance",
    formal: "Formal proof",
    agent_review: "Agent review"
  };
  const evidenceStates = new Set(["validated", "pass", "fail", "not-run", "unsupported", "error"]);

  function githubURL(value, releaseAsset = false) {
    if (typeof value !== "string") return null;
    try {
      const url = new URL(value);
      if (url.protocol !== "https:" || url.hostname !== "github.com" || url.username || url.password || url.port) return null;
      if (releaseAsset && !/^\/[^/]+\/[^/]+\/releases\/download\/[^/]+\/[^/]+$/.test(url.pathname)) return null;
      if (!releaseAsset && !/^\/[^/]+\/[^/]+\/?$/.test(url.pathname)) return null;
      return url.href;
    } catch {
      return null;
    }
  }

  function normalizeIndex(data) {
    if (!data || data.schema !== 1 || !Array.isArray(data.packages) || data.packages.length > 10000) {
      throw new Error("Unsupported package index");
    }
    return data.packages.filter((pkg) => {
      return pkg && typeof pkg.name === "string" && pkg.name.length <= 128 &&
        typeof pkg.summary === "string" && pkg.summary.length <= 2000 &&
        typeof pkg.latest === "string" && Array.isArray(pkg.targets) &&
        pkg.targets.every((target) => typeof target === "string" && target.length <= 128) &&
        Array.isArray(pkg.versions);
    }).map((pkg) => ({
      ...pkg,
      versions: pkg.versions.filter((version) => version && typeof version.version === "string" && Array.isArray(version.artifacts)),
      targets: [...new Set(pkg.targets)]
    })).sort((a, b) => a.name.localeCompare(b.name));
  }

  function findPackages(packages, query, target) {
    const terms = String(query || "").trim().toLowerCase().split(/\s+/).filter(Boolean);
    return packages.filter((pkg) => {
      const text = [pkg.name, pkg.summary, ...pkg.targets].join(" ").toLowerCase();
      return (!target || pkg.targets.includes(target)) && terms.every((term) => text.includes(term));
    });
  }

  function formatBytes(bytes) {
    if (!Number.isSafeInteger(bytes) || bytes < 0) return "Size unavailable";
    if (bytes < 1024) return `${bytes} bytes`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KiB`;
    return `${(bytes / 1048576).toFixed(1)} MiB`;
  }

  function validArtifact(artifact) {
    return artifact && ["source", "executable"].includes(artifact.kind) &&
      typeof artifact.target === "string" && typeof artifact.sha256 === "string" &&
      /^[a-f0-9]{64}$/.test(artifact.sha256) && githubURL(artifact.url, true);
  }

  function evidenceText(value) {
    if (!evidenceStates.has(value)) return "Unavailable";
    return value === "not-run" ? "Not run" : value.charAt(0).toUpperCase() + value.slice(1);
  }

  function formatDownloadCount(records, name) {
    const record = records?.packages?.[name];
    if (!record || !Number.isSafeInteger(record.total) || record.total < 0) return "GitHub asset downloads: unavailable";
    const date = typeof records.observed_at === "string" ? new Date(records.observed_at) : null;
    const observed = date && !Number.isNaN(date.getTime())
      ? ` · observed ${date.toISOString().slice(0, 10)}`
      : " · observation time unavailable";
    return `GitHub asset downloads: ${record.total.toLocaleString("en-US")}${observed}`;
  }

  // These pure functions are also used by the repository's Node checks.
  if (typeof module !== "undefined" && module.exports) {
    module.exports = { githubURL, normalizeIndex, findPackages, formatBytes, validArtifact, evidenceText, formatDownloadCount };
  }
  if (typeof document === "undefined") return;

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function link(text, href, className) {
    const node = element("a", className, text);
    node.href = href;
    return node;
  }

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const code = document.getElementById(button.dataset.copy);
      const status = document.getElementById("copy-status");
      if (!code) return;
      try {
        if (!navigator.clipboard?.writeText) throw new Error("Clipboard unavailable");
        await navigator.clipboard.writeText(code.textContent.trim());
        const previousContent = Array.from(button.childNodes).map((node) => node.cloneNode(true));
        button.textContent = "Copied";
        status.textContent = "Source build commands copied to clipboard.";
        button.disabled = true;
        window.setTimeout(() => {
          button.replaceChildren(...previousContent);
          button.disabled = false;
        }, 1800);
      } catch {
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(code);
        selection?.removeAllRanges();
        selection?.addRange(range);
        status.textContent = "Commands selected. Use your keyboard’s copy command to copy them.";
      }
    });
  });

  const list = document.getElementById("package-list");
  const status = document.getElementById("registry-status");
  const search = document.getElementById("package-search");
  const targetSelect = document.getElementById("package-target");
  if (!list || !status || !search || !targetSelect) return;

  let packages = [];
  let downloadRecords = null;

  function downloadCount(pkg) {
    return formatDownloadCount(downloadRecords, pkg.name);
  }

  function renderVersion(version, latest) {
    const section = element("details", "version-record");
    section.open = version.version === latest;
    const summary = element("summary", "", `Version ${version.version}`);
    if (version.yanked) summary.append(element("span", "release-state", "Yanked"));
    section.append(summary);

    const artifacts = version.artifacts.filter(validArtifact);
    if (artifacts.length) {
      const artifactList = element("ul", "artifact-list");
      artifacts.forEach((artifact) => {
        const item = element("li", "artifact");
        const title = element("p", "artifact-title");
        const label = artifact.kind === "executable" ? "Executable" : "Source archive";
        title.append(link(label, githubURL(artifact.url, true)));
        title.append(element("span", "", `${artifact.target} · ${formatBytes(artifact.bytes)}`));
        item.append(title, element("code", "artifact-digest", `SHA-256 ${artifact.sha256}`));
        artifactList.append(item);
      });
      section.append(artifactList);
    } else {
      section.append(element("p", "registry-fallback", "No supported artifact links are present in this record."));
    }

    const evidence = element("ul", "evidence-record");
    Object.entries(evidenceLabels).forEach(([key, label]) => {
      evidence.append(element("li", "", `${label}: ${evidenceText(version.evidence?.[key])}`));
    });
    section.append(evidence);
    const commit = version.source?.commit;
    if (typeof commit === "string" && /^[a-f0-9]{40}$/.test(commit)) {
      section.append(element("p", "artifact-digest", `Source commit ${commit}`));
    }
    return section;
  }

  function renderPackage(pkg) {
    const record = element("details", "package-record");
    const summary = element("summary");
    summary.append(element("span", "package-name", pkg.name));
    summary.append(element("span", "package-version", pkg.latest));
    summary.append(element("span", "package-description", pkg.summary));
    summary.append(element("span", "package-targets", pkg.targets.join(" · ")));
    record.append(summary);

    const details = element("div", "package-details");
    const meta = element("div", "package-meta");
    const source = githubURL(pkg.repository);
    if (source) meta.append(link("Source repository ↗", source));
    meta.append(element("span", "", `License: ${typeof pkg.license === "string" ? pkg.license : "Unavailable"}`));
    details.append(meta);
    pkg.versions.forEach((version) => details.append(renderVersion(version, pkg.latest)));
    details.append(element("p", "package-downloads", downloadCount(pkg)));
    record.append(details);
    return record;
  }

  function renderPackages() {
    const filtered = findPackages(packages, search.value, targetSelect.value);
    list.replaceChildren(...filtered.map(renderPackage));
    const noun = filtered.length === 1 ? "package" : "packages";
    status.textContent = filtered.length ? `${filtered.length} ${noun} shown. Open a record to inspect its releases.` : "No packages match. Try another name or select All targets.";
  }

  function renderCliDownload() {
    const pkg = packages.find((entry) => entry.name === "stubbi/asm");
    const version = pkg?.versions.find((entry) => entry.version === pkg.latest && !entry.yanked);
    const artifacts = version?.artifacts.filter((artifact) => validArtifact(artifact) && artifact.kind === "executable") || [];
    const panel = document.getElementById("cli-download");
    if (!panel || !artifacts.length) return;
    panel.append(element("h3", "", `Download asm ${version.version}`));
    panel.append(element("p", "", "Choose the artifact for your system. Check its SHA-256 before you run it."));
    artifacts.forEach((artifact) => {
      panel.append(link(`Download for ${artifact.target} ↗`, githubURL(artifact.url, true), "button button-primary"));
      panel.append(element("p", "checksum-label", `${formatBytes(artifact.bytes)} · SHA-256`));
      panel.append(element("code", "", artifact.sha256));
    });
    panel.append(element("p", "", "Release records above list the checks performed on each artifact."));
    panel.hidden = false;
  }

  async function getJSON(path) {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 12000);
    try {
      const response = await fetch(path, { signal: controller.signal, credentials: "omit" });
      if (!response.ok) throw new Error("Record unavailable");
      return await response.json();
    } finally {
      window.clearTimeout(timeout);
    }
  }

  async function loadRegistry() {
    status.textContent = "Loading package records…";
    try {
      packages = normalizeIndex(await getJSON("registry/v1/index.json"));
      const targets = [...new Set(packages.flatMap((pkg) => pkg.targets))].sort();
      targets.forEach((target) => {
        const option = element("option", "", target);
        option.value = target;
        targetSelect.append(option);
      });
      document.getElementById("registry-controls").hidden = false;
      search.addEventListener("input", renderPackages);
      targetSelect.addEventListener("change", renderPackages);
      renderPackages();
      renderCliDownload();
      try {
        const records = await getJSON("registry/v1/downloads.json");
        if (records?.schema === 1 && records.source === "github-release-assets") {
          downloadRecords = records;
          // Preserve opened records and focus when the optional counter arrives.
          list.querySelectorAll(".package-record").forEach((record) => {
            const name = record.querySelector(".package-name").textContent;
            const pkg = packages.find((entry) => entry.name === name);
            record.querySelector(".package-downloads").textContent = downloadCount(pkg);
          });
        }
      } catch {
        // Counts are optional. A missing counter is not a zero.
      }
    } catch {
      status.textContent = "The package index could not be loaded. Open the index link or browse the source below.";
    }
  }
  loadRegistry();
})();
