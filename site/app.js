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
      if (url.protocol !== "https:" || url.hostname !== "github.com" || url.username || url.password || url.port || url.search || url.hash) return null;
      const repository = "[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}";
      const segment = "[A-Za-z0-9][A-Za-z0-9._-]{0,127}";
      const pattern = releaseAsset ? `${repository}/releases/download/${segment}/${segment}` : repository;
      if (!(new RegExp(`^https://github\\.com/${pattern}$`)).test(value)) return null;
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
        (typeof pkg.latest === "string" || pkg.latest === null) && Array.isArray(pkg.targets) &&
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

  function packageStatus(total, shown) {
    if (total === 0) return "The registry has no published packages yet. You can inspect the source examples below.";
    if (shown === 0) return "No packages match. Try another name or select All targets.";
    const noun = shown === 1 ? "package" : "packages";
    return `${shown} ${noun} shown. Open a record to inspect its releases.`;
  }

  function formatBytes(bytes) {
    if (!Number.isSafeInteger(bytes) || bytes < 0) return "Size unavailable";
    if (bytes < 1024) return `${bytes} bytes`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KiB`;
    return `${(bytes / 1048576).toFixed(1)} MiB`;
  }

  function mathSourcePath(version) {
    if (typeof version !== "string" || !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(version)) return null;
    const [major, minor] = version.split(".").map(Number);
    const source = major === 0 && minor < 6 ? "src/min.s" : "targets/x86_64-linux/src/min.s";
    return `stubbi/math/${version}/x86_64-linux/${source}`;
  }

  function validArtifact(artifact) {
    return artifact && ["source", "executable"].includes(artifact.kind) &&
      typeof artifact.target === "string" && typeof artifact.sha256 === "string" &&
      /^[a-f0-9]{64}$/.test(artifact.sha256) && githubURL(artifact.url, true);
  }

  function packageAnchor(name) {
    if (typeof name !== "string" || !/^[a-z][a-z0-9-]{0,38}\/[a-z][a-z0-9-]{0,63}$/.test(name) ||
        name.split("/").some((part) => part.endsWith("-") || part.includes("--"))) return null;
    return `package-${name.replace("/", "--")}`;
  }

  function featureName(name) {
    return typeof name === "string" && /^[a-z][a-z0-9_-]{0,31}$/.test(name);
  }

  function featureList(values) {
    return Array.isArray(values) && values.length <= 64 && values.every(featureName) && new Set(values).size === values.length;
  }

  // Declarations belong to one checked source artifact. Missing or invalid
  // metadata is unknown, even when another target has an available declaration.
  function dependencyMetadata(artifact, artifactEvidence) {
    const metadata = artifact?.dependency_metadata;
    if (artifactEvidence !== "validated" || artifact?.kind !== "source" || !validArtifact(artifact) ||
        !metadata || metadata.schema !== 1 || metadata.source_sha256 !== artifact.sha256 ||
        !Array.isArray(metadata.dependencies) || metadata.dependencies.length > 64 ||
        !metadata.features || typeof metadata.features !== "object" || Array.isArray(metadata.features)) return null;
    const names = new Set();
    for (const dependency of metadata.dependencies) {
      if (!dependency || !packageAnchor(dependency.name) || names.has(dependency.name) ||
          typeof dependency.requirement !== "string" || !/^[0-9.*^~<>=, ]{1,128}$/.test(dependency.requirement) ||
          dependency.requirement.trim() !== dependency.requirement || !dependency.requirement.trim() ||
          typeof dependency.optional !== "boolean" || typeof dependency.default_features !== "boolean" ||
          !featureList(dependency.features)) return null;
      names.add(dependency.name);
    }
    const features = Object.entries(metadata.features);
    if (features.length > 64) return null;
    for (const [name, members] of features) {
      if (!featureName(name) || !Array.isArray(members) || members.length > 64 || new Set(members).size !== members.length) return null;
      for (const member of members) {
        if (typeof member !== "string" || member.length > 137) return null;
        if (featureName(member)) {
          if (!Object.hasOwn(metadata.features, member)) return null;
        } else if (member.startsWith("dep:")) {
          if (!names.has(member.slice(4))) return null;
        } else {
          const separator = member.lastIndexOf("/");
          if (separator < 0 || !names.has(member.slice(0, separator)) || !featureName(member.slice(separator + 1))) return null;
        }
      }
    }
    return metadata;
  }

  // The optional file cannot change the v1 catalog or attach another source's
  // declarations. Missing, invalid, or ambiguous input leaves metadata unknown.
  function mergeDependencyMetadata(packages, data) {
    const result = packages.map((pkg) => ({ ...pkg, versions: pkg.versions.map((version) => ({
      ...version, artifacts: version.artifacts.map((artifact) => {
        const copy = { ...artifact };
        delete copy.dependency_metadata;
        return copy;
      })
    })) }));
    if (!data || data.schema !== 1 || !Array.isArray(data.sources) || data.sources.length > 4096) return result;
    const sources = new Map();
    for (const source of data.sources) {
      if (!source || !packageAnchor(source.name) || typeof source.version !== "string" ||
          source.version.length > 32 || !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(source.version) ||
          typeof source.target !== "string" || !source.target.length || source.target.length > 128 ||
          typeof source.metadata?.source_sha256 !== "string" || !/^[a-f0-9]{64}$/.test(source.metadata.source_sha256)) return result;
      const key = JSON.stringify([source.name, source.version, source.target, source.metadata.source_sha256]);
      if (sources.has(key)) return result;
      sources.set(key, source.metadata);
    }
    result.forEach((pkg) => pkg.versions.forEach((version) => version.artifacts.forEach((artifact) => {
      const metadata = sources.get(JSON.stringify([pkg.name, version.version, artifact.target, artifact.sha256]));
      if (dependencyMetadata({ ...artifact, dependency_metadata: metadata }, version.evidence?.artifacts)) {
        artifact.dependency_metadata = metadata;
      }
    })));
    return result;
  }

  function evidenceText(value) {
    if (!evidenceStates.has(value)) return "Unavailable";
    return value === "not-run" ? "Not run" : value.charAt(0).toUpperCase() + value.slice(1);
  }

  function versionLicenseText(version) {
    const value = version?.license;
    return typeof value === "string" && /^[A-Za-z0-9+.-]{1,100}$/.test(value)
      ? `License: ${value}` : "License: unavailable";
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
    module.exports = { githubURL, normalizeIndex, findPackages, packageStatus, formatBytes, validArtifact, evidenceText, versionLicenseText, formatDownloadCount, packageAnchor, dependencyMetadata, mergeDependencyMetadata, mathSourcePath };
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

  document.addEventListener("click", async (event) => {
      const button = event.target.closest?.("[data-copy]");
      if (!button || button.getAttribute("aria-disabled") === "true") return;
      const code = document.getElementById(button.dataset.copy);
      const status = document.getElementById("copy-status");
      if (!code) return;
      button.setAttribute("aria-disabled", "true");
      try {
        if (!navigator.clipboard?.writeText) throw new Error("Clipboard unavailable");
        await navigator.clipboard.writeText(code.textContent.trim());
        const previousContent = Array.from(button.childNodes).map((node) => node.cloneNode(true));
        button.textContent = "Copied";
        status.textContent = "Commands copied to clipboard.";
        window.setTimeout(() => {
          button.replaceChildren(...previousContent);
          button.removeAttribute("aria-disabled");
        }, 1800);
      } catch {
        button.removeAttribute("aria-disabled");
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(code);
        selection?.removeAllRanges();
        selection?.addRange(range);
        status.textContent = "Commands selected. Use your keyboard’s copy command to copy them.";
      }
  });

  function commandBlock(id, title, text) {
    const block = element("div", "command-block");
    const heading = element("div", "command-block-heading");
    heading.append(element("span", "", title));
    const copy = element("button", "copy-button", "Copy");
    copy.type = "button";
    copy.dataset.copy = id;
    copy.setAttribute("aria-label", `Copy ${title.toLowerCase()}`);
    heading.append(copy);
    const code = element("code", "", text);
    code.id = id;
    const pre = element("pre");
    pre.append(code);
    block.append(heading, pre);
    return block;
  }

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

  function dependencyLink(name) {
    const destination = packageAnchor(name);
    if (destination && packages.some((pkg) => pkg.name === name)) {
      const anchor = link(name, `#${destination}`, "dependency-link");
      anchor.dataset.package = name;
      return anchor;
    }
    const label = element("span", "dependency-name");
    label.append(element("code", "", name), element("span", "dependency-unavailable", "Not in this catalog"));
    return label;
  }

  function renderFeatureMember(member) {
    const item = element("li");
    if (member.startsWith("dep:")) {
      item.append(document.createTextNode("Enable dependency "), dependencyLink(member.slice(4)));
    } else if (member.includes("/")) {
      const separator = member.lastIndexOf("/");
      item.append(document.createTextNode("Request "), element("code", "", member.slice(separator + 1)),
        document.createTextNode(" from "), dependencyLink(member.slice(0, separator)));
    } else {
      item.append(document.createTextNode("Enable feature "), element("code", "", member));
    }
    return item;
  }

  function renderDependencies(version) {
    const section = element("section", "dependency-section");
    section.append(element("h4", "", "Declared dependencies"));
    const sources = version.artifacts.filter((artifact) => artifact?.kind === "source" && validArtifact(artifact));
    if (!sources.length) {
      section.append(element("p", "dependency-note", "Dependency information unavailable. This release has no checked source archive."));
      return section;
    }
    sources.forEach((artifact) => {
      const target = element("div", "dependency-target");
      target.append(element("p", "dependency-target-name", artifact.target));
      const metadata = dependencyMetadata(artifact, version.evidence?.artifacts);
      if (!metadata) {
        target.append(element("p", "dependency-note", "Dependency information unavailable for this source archive."));
        section.append(target);
        return;
      }
      if (!metadata.dependencies.length) {
        target.append(element("p", "dependency-note", "No package dependencies declared."));
      } else {
        const dependencies = element("ul", "dependency-list");
        metadata.dependencies.forEach((dependency) => {
          const item = element("li", "dependency-item");
          const heading = element("div", "dependency-heading");
          heading.append(dependencyLink(dependency.name), element("code", "dependency-requirement", dependency.requirement));
          item.append(heading);
          const conditions = [dependency.optional ? "Optional" : "Required",
            dependency.default_features ? "Default features requested" : "Default features disabled"];
          if (dependency.optional) {
            const activatedBy = Object.entries(metadata.features).filter(([, members]) =>
              members.some((member) => member === `dep:${dependency.name}` || member.startsWith(`${dependency.name}/`))).map(([name]) => name);
            if (activatedBy.length) conditions.push(`Enabled by: ${activatedBy.join(", ")}`);
          }
          item.append(element("p", "dependency-policy", conditions.join(" · ")));
          if (dependency.features.length) {
            item.append(element("p", "dependency-policy", `Requested features: ${dependency.features.join(", ")}`));
          }
          dependencies.append(item);
        });
        target.append(dependencies);
      }
      const features = Object.entries(metadata.features);
      if (features.length) {
        const disclosure = element("details", "dependency-features");
        disclosure.append(element("summary", "", "Feature options"));
        const definitions = element("dl");
        features.forEach(([name, members]) => {
          const term = element("dt");
          term.append(element("code", "", name));
          if (name === "default") term.append(element("span", "dependency-policy", "Enabled unless disabled"));
          const description = element("dd");
          if (members.length) {
            const list = element("ul");
            members.forEach((member) => list.append(renderFeatureMember(member)));
            description.append(list);
          } else {
            description.append(element("p", "dependency-note", "No additional package requirements."));
          }
          definitions.append(term, description);
        });
        disclosure.append(definitions);
        target.append(disclosure);
      }
      section.append(target);
    });
    section.append(element("p", "dependency-scope", "These are direct requirements from asm.toml. They do not identify a resolved dependency graph."));
    return section;
  }

  function renderVersion(version, latest) {
    const section = element("details", "version-record");
    section.dataset.version = version.version;
    section.open = version.version === latest;
    const summary = element("summary", "", `Version ${version.version}`);
    if (version.yanked) summary.append(element("span", "release-state", "Yanked"));
    section.append(summary, element("p", "", versionLicenseText(version)));

    const artifacts = version.artifacts.filter(validArtifact);
    if (artifacts.length) {
      const artifactList = element("ul", "artifact-list");
      artifacts.forEach((artifact) => {
        const item = element("li", "artifact");
        const title = element("p", "artifact-title");
        const label = artifact.kind === "executable" ? "Executable" : "Source archive";
        if (version.evidence?.artifacts === "validated") {
          title.append(link(label, githubURL(artifact.url, true)));
        } else {
          title.append(element("span", "", label));
        }
        title.append(element("span", "", `${artifact.target} · ${formatBytes(artifact.bytes)}`));
        item.append(title, element("code", "artifact-digest", `SHA-256 ${artifact.sha256}`));
        artifactList.append(item);
      });
      section.append(artifactList);
      if (version.evidence?.artifacts !== "validated") {
        section.append(element("p", "registry-fallback", "The site has not checked the published artifact bytes. Read the index for their declared URLs."));
      }
    } else {
      section.append(element("p", "registry-fallback", "No supported artifact links are present in this record."));
    }

    section.append(renderDependencies(version));

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
    const destination = packageAnchor(pkg.name);
    if (destination) record.id = destination;
    const summary = element("summary");
    summary.append(element("span", "package-name", pkg.name));
    summary.append(element("span", "package-version", pkg.latest || "No active release"));
    summary.append(element("span", "package-description", pkg.summary));
    summary.append(element("span", "package-targets", pkg.targets.join(" · ")));
    record.append(summary);

    const details = element("div", "package-details");
    const meta = element("div", "package-meta");
    const source = githubURL(pkg.repository);
    if (source) meta.append(link("Source repository ↗", source));
    details.append(meta);
    pkg.versions.forEach((version) => details.append(renderVersion(version, pkg.latest)));
    details.append(element("p", "package-downloads", downloadCount(pkg)));
    record.append(details);
    return record;
  }

  function renderPackages() {
    const filtered = findPackages(packages, search.value, targetSelect.value);
    list.replaceChildren(...filtered.map(renderPackage));
    status.textContent = packageStatus(packages.length, filtered.length);
  }

  function showPackageFromHash() {
    const pkg = packages.find((entry) => packageAnchor(entry.name) && window.location.hash === `#${packageAnchor(entry.name)}`);
    if (!pkg) return;
    search.value = "";
    targetSelect.value = "";
    renderPackages();
    const record = document.getElementById(packageAnchor(pkg.name));
    if (!record) return;
    record.open = true;
    record.querySelector("summary").focus({ preventScroll: true });
    record.scrollIntoView({ block: "start" });
  }

  list.addEventListener("click", (event) => {
    const anchor = event.target.closest?.("a[data-package]");
    if (!anchor || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const origin = anchor.closest(".package-record");
    if (origin?.id && window.location.hash !== `#${origin.id}`) window.history.replaceState(null, "", `#${origin.id}`);
    if (window.location.hash === anchor.hash) {
      event.preventDefault();
      showPackageFromHash();
    }
  });
  window.addEventListener("hashchange", showPackageFromHash);

  function renderCliDownload() {
    const pkg = packages.find((entry) => entry.name === "stubbi/asm");
    const version = pkg?.versions.find((entry) => entry.version === pkg.latest && !entry.yanked && entry.evidence?.artifacts === "validated");
    const artifacts = version?.artifacts.filter((artifact) => validArtifact(artifact) && artifact.kind === "executable") || [];
    const panel = document.getElementById("cli-download");
    if (!panel || !artifacts.length) return;
    panel.append(element("h3", "", `Asm ${version.version} release files`));
    panel.append(element("p", "", "Use the installer above to check the signed release and install Asm. These links provide the raw artifacts for inspection."));
    panel.append(link("Install Asm ↑", "#start", "text-link"));
    artifacts.forEach((artifact) => {
      panel.append(link(`Raw executable for ${artifact.target} ↗`, githubURL(artifact.url, true), "text-link"));
      panel.append(element("p", "checksum-label", `${formatBytes(artifact.bytes)} · SHA-256`));
      panel.append(element("code", "", artifact.sha256));
    });
    panel.append(element("p", "", "Release records above list the checks performed on each artifact."));
    panel.hidden = false;
  }

  function renderMathGuide() {
    const pkg = packages.find((entry) => entry.name === "stubbi/math");
    const version = pkg?.versions.find((entry) => entry.version === pkg.latest && !entry.yanked && entry.evidence?.artifacts === "validated");
    if (!version || !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(version.version)) return;
    if (!version.artifacts.some((item) => validArtifact(item) && item.target === "x86_64-linux" && item.kind === "source")) return;
    const panel = document.getElementById("math-guide");
    if (!panel) return;
    panel.append(element("h3", "", "Use the x86-64 math package"));
    panel.append(element("p", "", "This example requires Linux x86-64. From your project directory, add an exact version. Asm records it in asm.lock and checks the extracted source files."));
    panel.append(commandBlock("math-add-commands", "Add the math package", `asm add stubbi/math@${version.version} --target x86_64-linux\nasm lock`));
    panel.append(element("p", "", "Add this include at file scope. Call asm_u64_min from your function with the two unsigned values in rdi and rsi."));
    panel.append(commandBlock("math-include-command", "Include the routine", `.include "${mathSourcePath(version.version)}"`));
    panel.append(element("p", "", "The routine returns the smaller value in rax. Read its contract for register and memory requirements."));
    panel.append(commandBlock("math-build-command", "Build with the lock file", "asm build --locked"));
    panel.append(element("p", "", "Commit asm.lock with your project. Use asm sync to restore its exact packages on another machine with the same target."));
    panel.append(link("Read the routine and tests ↗", "https://github.com/stubbi/asm/tree/main/examples/math", "text-link"));
    panel.hidden = false;
  }

  async function getJSON(path, limit = 0) {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 12000);
    try {
      const response = await fetch(path, { signal: controller.signal, credentials: "omit" });
      if (!response.ok) throw new Error("Record unavailable");
      if (limit) {
        const text = await response.text();
        if (text.length > limit) throw new Error("Record exceeds limit");
        return JSON.parse(text);
      }
      return await response.json();
    } finally {
      window.clearTimeout(timeout);
    }
  }

  async function loadRegistry() {
    status.textContent = "Loading package records…";
    const declarations = getJSON("registry/v1/dependencies.json", 4 * 1024 * 1024).catch(() => null);
    try {
      packages = mergeDependencyMetadata(normalizeIndex(await getJSON("registry/v1/index.json")), null);
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
      showPackageFromHash();
      renderCliDownload();
      renderMathGuide();
      try {
        packages = mergeDependencyMetadata(packages, await declarations);
        list.querySelectorAll(".package-record").forEach((record) => {
          const pkg = packages.find((entry) => entry.name === record.querySelector(".package-name").textContent);
          record.querySelectorAll(".version-record").forEach((section) => {
            const version = pkg.versions.find((entry) => entry.version === section.dataset.version);
            section.querySelector(".dependency-section").replaceWith(renderDependencies(version));
          });
        });
      } catch {
        // Optional declarations must not make the package catalog unavailable.
      }
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
