"use strict";

// The index is generated from accepted records. The UI does not invent records,
// infer verification from a checksum, or send searches to another service.
(function () {
  const evidenceStates = new Set(["validated", "pass", "fail", "not-run", "unsupported", "error"]);
  const architectures = Object.freeze({ aarch64: "ARM64", x86_64: "x86-64", riscv64: "RISC-V64" });
  const targetArchitectures = new Map([["aarch64-linux", "aarch64"], ["aarch64-macos", "aarch64"],
    ["x86_64-linux", "x86_64"], ["riscv64-linux", "riscv64"],
    ["aarch64-windows", "aarch64"], ["x86_64-windows", "x86_64"]]);
  const maxReleaseArtifacts = 14; // The accepted registry release bound.

  function architectureForTarget(target) {
    return typeof target === "string" ? targetArchitectures.get(target) || null : null;
  }

  function architectureLabel(architecture) {
    return typeof architecture === "string" && Object.hasOwn(architectures, architecture) ? architectures[architecture] : null;
  }

  function exactCount(value) {
    if (!Number.isSafeInteger(value) || value < 0) return null;
    return value === 0 ? "0" : value.toLocaleString("en-US");
  }

  function compactCount(value, options = {}) {
    if (exactCount(value) === null || !options || typeof options !== "object" || Array.isArray(options)) return null;
    const lowerBound = options.lowerBound === undefined ? false : options.lowerBound;
    if (typeof lowerBound !== "boolean") return null;
    if (value < 1000) return String(value);
    const units = [1000n, 1000000n, 1000000000n, 1000000000000n, 1000000000000000n];
    const suffixes = ["k", "M", "B", "T", "Q"];
    const number = BigInt(value);
    let index = 0;
    while (index + 1 < units.length && number >= units[index + 1]) index += 1;
    const precision = ((value >= 100000 && value < 1000000) ||
      (value >= 100000000 && value < 1000000000)) ? 0 : 1;
    const scale = precision === 0 ? 1n : 10n;
    // Integer arithmetic keeps rounding stable through MAX_SAFE_INTEGER.
    const rounded = (number * scale + (lowerBound ? 0n : units[index] / 2n)) / units[index];
    const fraction = rounded % scale;
    return `${rounded / scale}${fraction ? "." + fraction : ""}${suffixes[index]}`;
  }

  function packagePath(name, version) {
    if (typeof name !== "string" || !/^[a-z][a-z0-9-]{0,38}\/[a-z][a-z0-9-]{0,63}$/.test(name) ||
        name.split("/").some((part) => part.endsWith("-") || part.includes("--"))) return null;
    if (version !== undefined && version !== null) {
      if (typeof version !== "string" || !/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(version) ||
          version.split(".").some((part) => Number(part) > 2147483647)) return null;
    }
    return `/packages/${name}${version === undefined || version === null ? "" : "/" + version}`;
  }

  function parseSearchState(hash) {
    if (typeof hash !== "string" || !hash.startsWith("#search?")) return null;
    const invalid = () => { throw new RangeError("This search link contains unsupported filters. Clear the search to browse packages."); };
    // Percent encoding can use nine bytes per accepted UTF-16 character.
    if (hash.length > 8192) return invalid();
    const parameters = new URLSearchParams(hash.slice(8));
    for (const key of parameters.keys()) {
      if (!["q", "kind", "architecture", "target", "all"].includes(key) || parameters.getAll(key).length !== 1) return invalid();
    }
    const query = parameters.get("q") || "";
    const kind = parameters.get("kind") || "";
    const architecture = parameters.get("architecture") || "";
    const target = parameters.get("target") || "";
    const all = parameters.get("all") || "";
    if (query.length > 512 || target.length > 128 || !["", "source", "executable"].includes(kind) ||
        (architecture && architectureLabel(architecture) === null) || !["", "1"].includes(all)) return invalid();
    return { query, kind, architecture, target, all: all === "1" };
  }

  function searchStateHash(state) {
    const parameters = new URLSearchParams();
    if (state.query) parameters.set("q", state.query);
    if (state.kind) parameters.set("kind", state.kind);
    if (state.architecture) parameters.set("architecture", state.architecture);
    if (state.target) parameters.set("target", state.target);
    if (state.all) parameters.set("all", "1");
    const hash = parameters.size ? `#search?${parameters}` : "";
    if (hash) parseSearchState(hash);
    return hash;
  }

  function readReturnState(hash) {
    if (typeof hash !== "string" || hash.length > 16384) return null;
    const parameters = new URLSearchParams(hash.slice(1));
    if (parameters.getAll("from").length !== 1) return null;
    try { return parseSearchState(parameters.get("from")); }
    catch { return null; }
  }

  function matchesArtifact(kind, target, artifact, architecture = "") {
    return Boolean(artifact && (!kind || ["source", "executable"].includes(kind)) &&
      (!kind || artifact.kind === kind) && (!target || artifact.target === target) &&
      (!architecture || (architectureLabel(architecture) !== null && architectureForTarget(artifact.target) === architecture)));
  }

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
      return pkg && packagePath(pkg.name) !== null &&
        typeof pkg.summary === "string" && pkg.summary.length <= 2000 &&
        (pkg.latest === null || (typeof pkg.latest === "string" && packagePath(pkg.name, pkg.latest) !== null)) && Array.isArray(pkg.targets) &&
        pkg.targets.every((target) => typeof target === "string" && target.length <= 128) &&
        Array.isArray(pkg.versions);
    }).map((pkg) => ({
      ...pkg,
      versions: pkg.versions.filter((version) => version && typeof version.version === "string" && Array.isArray(version.artifacts)),
      targets: [...new Set(pkg.targets)]
    })).sort((a, b) => a.name.localeCompare(b.name));
  }

  function latestActiveRelease(pkg) {
    if (!pkg || typeof pkg.latest !== "string" || packagePath(pkg.name, pkg.latest) === null || !Array.isArray(pkg.versions)) return null;
    return pkg.versions.find((version) => version && version.version === pkg.latest && !version.yanked) || null;
  }

  function activeArtifacts(pkg) {
    const release = latestActiveRelease(pkg);
    return Array.isArray(release?.artifacts) ? release.artifacts.filter((artifact) =>
      validArtifact(artifact) && artifact.target.length > 0 && artifact.target.length <= 128) : [];
  }

  function architectureGroups(packages) {
    const members = new Map(Object.keys(architectures).map((key) => [key, new Set()]));
    for (const pkg of packages) {
      if (!pkg || packagePath(pkg.name) === null) continue;
      for (const artifact of activeArtifacts(pkg)) {
        const architecture = architectureForTarget(artifact.target);
        if (architecture !== null) members.get(architecture).add(pkg.name);
      }
    }
    return Object.keys(architectures).sort((first, second) => architectures[first].toLowerCase().localeCompare(architectures[second].toLowerCase()))
      .filter((key) => members.get(key).size > 0)
      .map((key) => ({ id: key, name: architectures[key], packages: [...members.get(key)].sort() }));
  }

  function searchResultMetadata(pkg, { kind = "", target = "", architecture = "" } = {}) {
    const release = latestActiveRelease(pkg);
    if (!release) return { version: null, license: null, formats: [] };
    const artifacts = activeArtifacts(pkg).filter((artifact) => matchesArtifact(kind, target, artifact, architecture));
    const formats = ["source", "executable"].map((kind) => ({ kind,
      targets: [...new Set(artifacts.filter((artifact) => artifact.kind === kind).map((artifact) => artifact.target))].sort()
    })).filter((format) => format.targets.length > 0);
    return { version: release.version, license: licenseIdentifier(release.license), formats };
  }

  function catalogStats(packages) {
    const names = new Set(), releases = new Set(), files = new Set(), targets = new Set();
    for (const pkg of packages) {
      if (!pkg || packagePath(pkg.name) === null) continue;
      names.add(pkg.name);
      if (!Array.isArray(pkg.versions)) continue;
      for (const release of pkg.versions) {
        if (!release || typeof release.version !== "string" || packagePath(pkg.name, release.version) === null) continue;
        releases.add(`${pkg.name}@${release.version}`);
        if (!Array.isArray(release.artifacts)) continue;
        for (const artifact of release.artifacts) {
          if (!validArtifact(artifact) || artifact.target.length === 0 || artifact.target.length > 128) continue;
          files.add(JSON.stringify([pkg.name, release.version, artifact.kind, artifact.target]));
          targets.add(artifact.target);
        }
      }
    }
    return { packages: names.size, releases: releases.size, files: files.size, targets: targets.size };
  }

  function normalizeSearchTopics(data, packages, source) {
    const require = (condition) => { if (!condition) throw new RangeError("Optional search topics are invalid."); };
    const keys = (value, allowed, required = allowed) => value && typeof value === "object" && !Array.isArray(value) &&
      Object.keys(value).every((key) => allowed.includes(key)) && required.every((key) => Object.hasOwn(value, key));
    const identifier = (value) => typeof value === "string" && /^[a-z][a-z0-9-]{0,39}$/.test(value) && !value.endsWith("-") && !value.includes("--");
    require(["keywords", "categories"].includes(source) && Array.isArray(packages) && packages.length <= 4096);
    const known = new Map(packages.map((pkg) => [pkg.name, pkg]));
    require(known.size === packages.length && [...known.keys()].every((name) => packagePath(name) !== null));
    const field = source === "keywords" ? "packages" : "categories", result = new Map(), seen = new Set(), tags = new Set();
    require(keys(data, ["schema", field]) && data.schema === 1 && Array.isArray(data[field]) &&
      data[field].length <= (source === "keywords" ? known.size : 32));
    const names = (values, limit) => Array.isArray(values) && values.length <= limit &&
      values.every((name) => typeof name === "string" && known.has(name)) && new Set(values).size === values.length;
    const add = (name, terms) => {
      const release = latestActiveRelease(known.get(name));
      if (release) result.set(name, { version: release.version, terms: [...(result.get(name)?.terms || []), ...terms] });
    };
    for (const entry of data[field]) {
      if (source === "keywords") {
        require(keys(entry, ["name", "keywords", "releases"], ["name"]) && known.has(entry.name) && !seen.has(entry.name));
        seen.add(entry.name);
        const words = entry.keywords === undefined ? [] : entry.keywords, releases = entry.releases === undefined ? [] : entry.releases;
        require(Array.isArray(words) && words.length <= 32 && words.every(identifier) && new Set(words).size === words.length);
        words.forEach((word) => tags.add(word)); require(tags.size <= 4096);
        require(Array.isArray(releases) && releases.length <= known.get(entry.name).versions.length);
        const versions = new Set();
        for (const release of releases) {
          require(keys(release, ["version", "source_commit", "dependencies"]) && packagePath(entry.name, release.version) !== null && !versions.has(release.version));
          versions.add(release.version);
          const recorded = known.get(entry.name).versions.find((item) => item.version === release.version);
          require(recorded && typeof release.source_commit === "string" && /^[a-f0-9]{40}$/.test(release.source_commit) &&
            release.source_commit !== "0".repeat(40) && recorded.source?.commit === release.source_commit &&
            names(release.dependencies, 256) && !release.dependencies.includes(entry.name));
        }
        add(entry.name, words);
      } else {
        require(keys(entry, ["id", "name", "packages"]) && identifier(entry.id) && !seen.has(entry.id));
        seen.add(entry.id);
        require(typeof entry.name === "string" && entry.name.trim() === entry.name && entry.name.length > 0 &&
          Array.from(entry.name).length <= 80 && !/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/.test(entry.name) && names(entry.packages, known.size));
        entry.packages.forEach((name) => add(name, [entry.id, entry.name]));
      }
    }
    return result;
  }

  function findPackages(packages, query, target, kind = "", architecture = "", topics = []) {
    if ((kind && !["source", "executable"].includes(kind)) || (architecture && architectureLabel(architecture) === null)) return [];
    const terms = String(query || "").trim().toLowerCase().split(/\s+/).filter(Boolean);
    const matches = packages.filter((pkg) => {
      const artifacts = activeArtifacts(pkg).filter((artifact) => matchesArtifact(kind, target, artifact, architecture));
      const aliases = artifacts.flatMap((artifact) => {
        const key = architectureForTarget(artifact.target);
        return key === null ? [] : [key, architectureLabel(key)];
      });
      const release = latestActiveRelease(pkg);
      const labels = release ? topics.flatMap((projection) => {
        const row = projection?.get(pkg.name);
        return row?.version === release.version ? row.terms : [];
      }) : [];
      const text = [pkg.name, pkg.summary, licenseIdentifier(release?.license), ...labels,
        ...artifacts.map((artifact) => artifact.target), ...aliases].join(" ").toLowerCase();
      const matchesSelection = (!kind && !target && !architecture) || artifacts.length > 0;
      return matchesSelection && terms.every((term) => text.includes(term));
    });
    if (terms.length !== 1) return matches;
    const rank = (pkg) => pkg.name.toLowerCase() === terms[0] ? 0
      : pkg.name.split("/")[1]?.toLowerCase() === terms[0] ? 1 : 2;
    return matches.sort((first, second) => rank(first) - rank(second));
  }

  function packageStatus(total, shown, { exact = false } = {}) {
    if (total === 0) return "The registry has no published packages yet. Browse the source examples.";
    if (shown === 0) return "No packages match. Try another name or clear the format, architecture, and target filters.";
    const noun = shown === 1 ? "package" : "packages";
    return `${exact ? exactCount(shown) : compactCount(shown)} ${noun} shown. Open a package to inspect its releases.`;
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

  function licenseIdentifier(value) {
    return typeof value === "string" && /^[A-Za-z0-9+.-]{1,100}$/.test(value) ? value : null;
  }

  function versionLicenseText(version) {
    const value = licenseIdentifier(version?.license);
    return value ? `License: ${value}` : "License: unavailable";
  }

  function formatDownloadCount(records, name) {
    const record = records?.packages?.[name];
    if (!record || !Number.isSafeInteger(record.total) || record.total < 0) return "GitHub asset downloads: unavailable";
    const date = typeof records.observed_at === "string" ? new Date(records.observed_at) : null;
    const observed = date && !Number.isNaN(date.getTime())
      ? ` · observed ${date.toISOString().slice(0, 10)}`
      : " · observation time unavailable";
    return `GitHub asset downloads: ${compactCount(record.total)}${observed}`;
  }

  function discoveryDate(value) {
    if (typeof value !== "string" || value.length > 40) return null;
    const parts = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|\+00:00)$/.exec(value);
    if (!parts) return null;
    const date = new Date(value);
    const actual = [date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate(),
      date.getUTCHours(), date.getUTCMinutes(), date.getUTCSeconds()];
    return Number.isFinite(date.getTime()) && actual.every((part, index) => part === Number(parts[index + 1])) ? date : null;
  }

  function formatDiscoveryDate(value, includeTime = false) {
    const date = discoveryDate(value);
    if (!date) return "Publication date unavailable";
    const day = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }).format(date);
    if (!includeTime) return day;
    const time = new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit", hourCycle: "h23", timeZone: "UTC" }).format(date);
    return `${day} at ${time} UTC`;
  }

  function formatDiscoveryCount(row, { exact = false } = {}) {
    if (!row || !Number.isSafeInteger(row.downloads_30d) || row.downloads_30d < 0 || typeof row.downloads_30d_exact !== "boolean") return "Downloads unavailable";
    const count = exact ? exactCount(row.downloads_30d)
      : compactCount(row.downloads_30d, { lowerBound: !row.downloads_30d_exact });
    return `${row.downloads_30d_exact === false ? "≥ " : ""}${count} ${row.downloads_30d === 1 ? "download" : "downloads"}`;
  }

  function discoveryFeedDate(row, key) {
    return key === "new" ? row?.first_published_at ?? null
      : key === "updated" ? row?.last_published_at ?? null : null;
  }

  function discoveryFreshness(snapshot) {
    if (!discoveryDate(snapshot?.observed_at)) return `${snapshot?.stale ? "Stale snapshot. " : ""}Observation time unavailable.${snapshot?.refresh_error ? " Latest refresh failed." : ""}`;
    const prefix = snapshot.stale ? "Stale snapshot from" : "Observed";
    return `${prefix} ${formatDiscoveryDate(snapshot.observed_at, true)}.${snapshot.refresh_error ? " Latest refresh failed." : ""}`;
  }

  function discoveryCoverageMessage(snapshot) {
    if (!snapshot?.collection_started_at) return "Download collection has not started. Counts are unavailable.";
    if (!snapshot.coverage.complete) return `Collecting downloads since ${formatDiscoveryDate(snapshot.collection_started_at)}. Coverage is incomplete for this window.`;
    return `Window ending ${formatDiscoveryDate(snapshot.window.end, true)}.`;
  }

  function discoveryEmptyMessage(snapshot, key) {
    if (!snapshot) return "Discovery data is unavailable. Open the complete list.";
    const active = snapshot.packages.filter((row) => row.targets.length > 0);
    if (!active.length) return "No active packages are available.";
    if (key === "popular") {
      if (!snapshot.collection_started_at) return "Download counts are unavailable. Collection has not started.";
      if (active.some((row) => row.downloads_30d === null)) return "Download observations are unavailable for this window.";
      if (!snapshot.coverage.complete && active.every((row) => row.downloads_30d === 0)) {
        return `Collecting downloads since ${formatDiscoveryDate(snapshot.collection_started_at)}. No downloads were recorded in the available part of this window.`;
      }
      if (active.some((row) => !row.downloads_30d_exact)) return "Download observations are incomplete for this window.";
      if (active.every((row) => row.downloads_30d === 0)) return "No downloads were observed in this window.";
      return "No ranked packages are listed in this snapshot.";
    }
    if (key === "updated") {
      if (active.every((row) => row.last_published_at === null)) return "Latest GitHub release dates are unavailable.";
      return "No updated packages are listed in this snapshot.";
    }
    if (active.every((row) => row.first_published_at === null)) return "First GitHub release dates are unavailable.";
    return "No new packages are listed in this snapshot.";
  }

  function normalizeDiscovery(data, catalog, now = Date.now()) {
    const require = (condition) => { if (!condition) throw new RangeError("The discovery snapshot is invalid or does not match the package catalog."); };
    const maxRows = 10000;
    const clockTolerance = 5 * 60 * 1000;
    require(Number.isFinite(now));
    require(data && data.schema === 1 && data.policy === "asm-deliveries-v1" && data.source === "asm-delivery-events");
    require(typeof data.stale === "boolean" && (data.refresh_error === null || (typeof data.refresh_error === "string" && data.refresh_error.length <= 2048)));
    require(Array.isArray(catalog) && catalog.length <= maxRows && Array.isArray(data.packages) && data.packages.length <= maxRows);
    const date = (value) => {
      if (value === null) return null;
      const parsed = discoveryDate(value);
      require(parsed && parsed.getTime() <= now + clockTolerance);
      return parsed.toISOString();
    };
    const observed = date(data.observed_at);
    const publicationObserved = data.publication_observed_at === undefined ? observed : date(data.publication_observed_at);
    require(data.window && data.window.days === 30 && data.window.basis === "rolling-observation");
    const start = date(data.window.start), end = date(data.window.end);
    require((start === null) === (end === null));
    if (start !== null) {
      require(Date.parse(end) - Date.parse(start) === 30 * 24 * 60 * 60 * 1000);
      require(observed !== null && end === observed);
    }
    const collectionStarted = date(data.collection_started_at);
    require(data.coverage && typeof data.coverage.complete === "boolean");
    const coverageStart = date(data.coverage.start), coverageEnd = date(data.coverage.end);
    require((coverageStart === null) === (coverageEnd === null));
    if (coverageStart !== null) {
      require(collectionStarted !== null && observed !== null && Date.parse(collectionStarted) <= Date.parse(coverageStart));
      require(Date.parse(coverageStart) <= Date.parse(coverageEnd) && Date.parse(coverageEnd) <= Date.parse(observed));
    }
    if (data.coverage.complete) {
      require(start !== null && coverageStart !== null && Date.parse(coverageStart) <= Date.parse(start) && Date.parse(coverageEnd) >= Date.parse(end));
    }
    const packages = new Map();
    for (const pkg of catalog) {
      require(pkg && packagePath(pkg.name) !== null && !packages.has(pkg.name));
      packages.set(pkg.name, pkg);
    }
    const rows = new Map();
    for (const item of data.packages) {
      require(item && packages.has(item.name) && !rows.has(item.name) && item.publication_source === "github-release");
      const first = date(item.first_published_at), last = date(item.last_published_at);
      require(first === null || last === null || Date.parse(first) <= Date.parse(last));
      require(publicationObserved === null || [first, last].every((value) => value === null || Date.parse(value) <= Date.parse(publicationObserved) + clockTolerance));
      const count = item.downloads_30d, exact = item.downloads_30d_exact, coverage = item.downloads_30d_coverage;
      require(typeof exact === "boolean" && ["complete", "lower-bound", "unavailable"].includes(coverage));
      require(count === null || (Number.isSafeInteger(count) && count >= 0));
      require(count === null ? coverage === "unavailable" && !exact : start !== null && (exact ? coverage === "complete" : coverage === "lower-bound"));
      require(count === null || (collectionStarted !== null && coverageStart !== null));
      require(!exact || data.coverage.complete);
      const pkg = packages.get(item.name);
      const release = Array.isArray(pkg.versions) ? pkg.versions.find((version) => version && version.version === pkg.latest && !version.yanked) : null;
      const artifacts = release && Array.isArray(release.artifacts) ? release.artifacts : [];
      const active = artifacts.length > 0 && artifacts.length <= maxReleaseArtifacts && artifacts.every((artifact) => validArtifact(artifact) && artifact.target.length > 0 && artifact.target.length <= 128);
      rows.set(item.name, { name: item.name, first_published_at: first, last_published_at: last,
        publication_source: item.publication_source, downloads_30d: count, downloads_30d_exact: exact,
        downloads_30d_coverage: coverage, package: pkg,
        targets: active ? [...new Set(artifacts.map((artifact) => artifact.target))].sort() : [] });
    }
    require(data.feeds && typeof data.feeds === "object");
    const feeds = {};
    for (const key of ["popular", "new", "updated"]) {
      const names = data.feeds[key];
      require(Array.isArray(names) && names.length <= maxRows && new Set(names).size === names.length);
      feeds[key] = names.map((name) => {
        const row = rows.get(name);
        require(row && row.targets.length > 0);
        require(key !== "popular" || row.downloads_30d > 0);
        require(key !== "new" || row.first_published_at !== null);
        require(key !== "updated" || row.last_published_at !== null);
        return row;
      });
    }
    const categories = data.categories === undefined ? [] : data.categories;
    require(Array.isArray(categories) && categories.length <= 64);
    const categoryIDs = new Set();
    const normalizedCategories = categories.map((category) => {
      require(category && typeof category.id === "string" && category.id.length <= 40 && /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(category.id) && !categoryIDs.has(category.id));
      require(typeof category.name === "string" && category.name.trim().length > 0 && category.name.length <= 80);
      require(Array.isArray(category.packages) && category.packages.length <= maxRows && new Set(category.packages).size === category.packages.length && category.packages.every((name) => rows.has(name)));
      categoryIDs.add(category.id);
      return { id: category.id, name: category.name, packages: category.packages.filter((name) => rows.get(name).targets.length > 0) };
    });
    const stale = data.stale || (observed !== null && now - Date.parse(observed) > 24 * 60 * 60 * 1000);
    return { schema: 1, source: data.source, policy: data.policy, observed_at: observed, publication_observed_at: publicationObserved, stale,
      refresh_error: data.refresh_error, window: { days: 30, start, end, basis: data.window.basis },
      collection_started_at: collectionStarted, coverage: { start: coverageStart, end: coverageEnd, complete: data.coverage.complete },
      packages: [...rows.values()], feeds, categories: normalizedCategories };
  }

  function rejoinDiscovery(snapshot, catalog, now = Date.now()) {
    if (!snapshot) return null;
    try {
      const feeds = Object.fromEntries(["popular", "new", "updated"].map((key) => [key, snapshot.feeds[key].map((row) => row.name)]));
      return normalizeDiscovery({ ...snapshot, feeds }, catalog, now);
    } catch { return null; }
  }

  // These pure functions are also used by the repository's Node checks.
  const publicAPI = { compactCount, exactCount, architectureForTarget, architectureLabel, architectureGroups,
    githubURL, normalizeIndex, normalizeSearchTopics, catalogStats, searchResultMetadata, findPackages, packageStatus, formatBytes, validArtifact,
    evidenceText, versionLicenseText, formatDownloadCount, packagePath, parseSearchState, searchStateHash, readReturnState, matchesArtifact,
    normalizeDiscovery, rejoinDiscovery, formatDiscoveryCount, formatDiscoveryDate, discoveryFreshness, discoveryEmptyMessage, discoveryCoverageMessage, discoveryFeedDate,
    packageAnchor, dependencyMetadata, mergeDependencyMetadata, mathSourcePath };
  if (typeof module !== "undefined" && module.exports) module.exports = publicAPI;
  if (typeof window !== "undefined") window.AsmSite = Object.freeze(publicAPI);
  if (typeof document === "undefined") return;
  document.documentElement.classList.add("js-enabled");

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function showCount(node, value, suffix = "") {
    const compact = compactCount(value), exact = exactCount(value);
    if (compact === null) return;
    const full = exact + suffix;
    const visible = element("span", "", compact + suffix);
    visible.setAttribute("aria-hidden", "true");
    node.title = full;
    node.setAttribute("aria-label", full);
    node.replaceChildren(visible, element("span", "sr-only", full));
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
        await navigator.clipboard.writeText(button.hasAttribute("data-copy-verbatim") ? code.textContent : code.textContent.trim());
        const previousContent = Array.from(button.childNodes).map((node) => node.cloneNode(true));
        const previousLabel = button.getAttribute("aria-label");
        button.textContent = "Copied";
        button.setAttribute("aria-label", "Copied");
        status.textContent = "Copied to clipboard.";
        window.setTimeout(() => {
          button.replaceChildren(...previousContent);
          if (previousLabel === null) button.removeAttribute("aria-label");
          else button.setAttribute("aria-label", previousLabel);
          button.removeAttribute("aria-disabled");
        }, 1800);
      } catch {
        button.removeAttribute("aria-disabled");
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(code);
        selection?.removeAllRanges();
        selection?.addRange(range);
        status.textContent = "Text selected. Use your keyboard’s copy command to copy it.";
      }
  });

  document.querySelectorAll("[data-copy][hidden]").forEach((button) => { button.hidden = false; });

  const list = document.getElementById("package-list");
  const status = document.getElementById("registry-status");
  const search = document.getElementById("package-search");
  const targetSelect = document.getElementById("package-target");
  const kindSelect = document.getElementById("package-kind");
  const architectureSelect = document.getElementById("package-architecture");
  if (!list || !status || !search || !targetSelect || !kindSelect || !architectureSelect) return;
  const homepageTitle = document.title;

  // Restore the search geometry before a navigation snapshot, without waiting for the index.
  // The existing restore path applies filters and reports invalid links after the catalog loads.
  try {
    const pending = parseSearchState(window.location.hash);
    if (pending) {
      search.value = pending.query;
      document.body.classList.toggle("has-search-results", Boolean(
        pending.all || pending.query.trim() || pending.kind || pending.architecture || pending.target));
    }
  } catch (_) { /* The normal recovery path retains the invalid-link explanation. */ }

  function setRegistryStatus(visibleText, exactText = visibleText) {
    if (visibleText === exactText) {
      status.textContent = visibleText;
      status.removeAttribute("title");
      status.removeAttribute("aria-label");
    } else {
      const visible = element("span", "", visibleText);
      visible.setAttribute("aria-hidden", "true");
      status.title = exactText;
      status.setAttribute("aria-label", exactText);
      status.replaceChildren(visible, element("span", "sr-only", exactText));
    }
  }

  const searchForm = document.getElementById("registry-controls");
  const searchSubmit = document.getElementById("search-submit");
  const resetSearch = document.getElementById("reset-search");
  const catalogHeading = document.getElementById("catalog-heading");
  const fallback = document.getElementById("registry-fallback");
  const discovery = document.getElementById("package-discovery");
  const toolbar = document.getElementById("results-toolbar");
  const browseAll = document.getElementById("browse-all");
  const catalogNote = document.getElementById("catalog-note");
  let showAll = false;
  let compactSearch = false;
  let invalidSearchMessage = "";

  searchForm.addEventListener("submit", (event) => {
    event.preventDefault();
    if (search.disabled) return;
    showAll = true;
    compactSearch = true;
    writeSearchHistory(true);
    renderPackages();
    catalogHeading.focus();
  });
  resetSearch?.addEventListener("click", () => {
    search.value = "";
    targetSelect.value = "";
    kindSelect.value = "";
    architectureSelect.value = "";
    showAll = false;
    compactSearch = false;
    writeSearchHistory(true);
    renderPackages();
    search.focus();
  });

  browseAll.addEventListener("click", () => {
    search.value = "";
    targetSelect.value = "";
    kindSelect.value = "";
    architectureSelect.value = "";
    showAll = true;
    compactSearch = true;
    writeSearchHistory(true);
    renderPackages();
    catalogHeading.focus();
  });

  let packages = [];
  let catalogReady = false;
  let discoverySnapshot = null;
  let discoveryObservedAt = null;
  let discoveryLoading = true;
  let discoveryRenderPending = false;
  let pendingRefresh = null;
  let refreshRunning = false;
  let lastRefreshStarted = 0;
  let searchTopics = [null, null];
  let topicsLoading = true;
  function currentSearchState() {
    return { query: search.value, kind: kindSelect.value, architecture: architectureSelect.value, target: targetSelect.value, all: showAll };
  }

  function writeSearchHistory(push = false) {
    invalidSearchMessage = "";
    const hash = searchStateHash(currentSearchState());
    const address = window.location.pathname + window.location.search + hash;
    if (window.location.hash === hash) return;
    try { window.history[push ? "pushState" : "replaceState"](null, "", address); }
    catch { /* Search remains available when the browser refuses history changes. */ }
  }

  function packageLink(pkg, version) {
    const path = packagePath(pkg.name, version);
    const from = searchStateHash(currentSearchState());
    return path + (from ? `#from=${encodeURIComponent(from)}` : "");
  }

  function renderPackage(pkg) {
    const metadata = searchResultMetadata(pkg,
      { kind: kindSelect.value, target: targetSelect.value, architecture: architectureSelect.value });
    const record = element("article", "package-result");
    const heading = element("div", "package-result-heading");
    const title = element("h3");
    title.append(link(pkg.name, packageLink(pkg), "package-name"));
    heading.append(title);
    if (metadata.version) heading.append(link(metadata.version, packageLink(pkg, metadata.version), "package-version"));
    else heading.append(element("span", "package-version", "No active release"));
    record.append(heading, element("p", "package-description", pkg.summary));
    if (metadata.version) {
      const facts = element("dl", "package-result-meta");
      const formatLabel = (kind) => kind === "source" ? "Source" : "Executable";
      for (const [label, value] of [["License", metadata.license || "Unavailable"],
        ["Formats", metadata.formats.map((format) => formatLabel(format.kind)).join(" · ") || "Unavailable"]]) {
        const fact = element("div");
        fact.append(element("dt", "", label), element("dd", "", value));
        facts.append(fact);
      }
      record.append(facts);
      if (metadata.formats.length) {
        const targets = element("dl", "package-result-targets");
        metadata.formats.forEach((format) => {
          const group = element("div", "package-result-target-group");
          const values = element("dd");
          const items = element("ul", "package-result-target-list");
          format.targets.forEach((target) => {
            const item = element("li", "package-result-target");
            item.append(element("code", "", target));
            items.append(item);
          });
          values.append(items);
          group.append(element("dt", "package-result-target-label", `${formatLabel(format.kind)} targets`), values);
          targets.append(group);
        });
        record.append(targets);
      } else record.append(element("p", "package-result-note", "Artifact targets are unavailable for this release."));
    }
    return record;
  }

  function discoveryHasFocus() {
    return discovery.contains(document.activeElement);
  }

  function discoveryGroup(key, title, caption) {
    const group = element("section", "discovery-group");
    group.dataset.discoveryFeed = key;
    const heading = element("div", "discovery-group-heading");
    const label = element("h3");
    label.id = `browse-${key}`;
    group.setAttribute("aria-labelledby", label.id);
    const more = link(title, `/browse/${key}`, "discovery-heading-link");
    more.setAttribute("aria-label", `View all ${key === "updated" ? "recently updated" : key === "popular" ? "most downloaded" : "new"} packages`);
    label.append(more);
    heading.append(label);
    const header = element("div", "discovery-group-header");
    header.append(heading, element("p", "discovery-group-caption", caption));
    group.append(header);
    const rows = discoverySnapshot?.feeds[key] || [];
    if (rows.length) {
      const items = element("ul", "discovery-items");
      rows.slice(0, 5).forEach((row) => {
        const item = element("li");
        const anchor = link(undefined, packagePath(row.package.name), "discovery-item");
        const signal = element("span", "discovery-signal");
        if (key === "popular") {
          const fullCount = formatDiscoveryCount(row, { exact: true });
          const visible = element("span", "", formatDiscoveryCount(row).replace(/ downloads?$/, ""));
          visible.setAttribute("aria-hidden", "true");
          signal.title = fullCount;
          signal.append(visible, element("span", "sr-only", fullCount));
        }
        else {
          const date = discoveryFeedDate(row, key);
          const time = element("time", "", formatDiscoveryDate(date));
          time.dateTime = date;
          signal.append(time);
        }
        const targets = element("span", "discovery-targets");
        row.targets.forEach((target, index) => {
          if (index) targets.append(" · ");
          targets.append(element("span", "discovery-target", target));
        });
        anchor.append(element("span", "discovery-name", row.name), signal,
          element("span", "discovery-summary", row.package.summary), targets);
        item.append(anchor);
        items.append(item);
      });
      group.append(items);
    } else {
      const message = discoveryLoading ? "Loading discovery data…" : discoveryEmptyMessage(discoverySnapshot, key);
      group.append(element("p", "discovery-group-note", message));
    }
    if (key === "popular" && rows.length && discoverySnapshot) {
      group.append(element("p", "discovery-group-note", discoveryCoverageMessage(discoverySnapshot)));
    }
    return group;
  }

  function renderDiscovery() {
    if (discoveryHasFocus()) { discoveryRenderPending = true; return; }
    discoveryRenderPending = false;
    const nodes = [];
    if (!discoveryLoading && (!discoverySnapshot || !discoverySnapshot.observed_at || discoverySnapshot.stale || discoverySnapshot.refresh_error)) {
      let state = !discoverySnapshot ? "Discovery snapshot unavailable."
        : !discoverySnapshot.observed_at ? "Download observations are unavailable."
        : discoverySnapshot.stale ? "Download observations are stale." : "";
      if (discoverySnapshot?.refresh_error) state += (state ? " " : "") + "The latest download refresh failed.";
      nodes.push(element("p", "discovery-state", state));
    }
    const groups = element("div", "discovery-groups");
    groups.append(discoveryGroup("new", "New packages", "First GitHub release"),
      discoveryGroup("popular", "Most downloaded", "Last 30 days"),
      discoveryGroup("updated", "Recently updated", "Latest GitHub release"));
    nodes.push(groups);
    discovery.replaceChildren(...nodes);
  }

  function renderPackages() {
    const filtered = findPackages(packages, search.value, targetSelect.value, kindSelect.value, architectureSelect.value, searchTopics);
    const hasFilters = Boolean(search.value.trim() || targetSelect.value || kindSelect.value || architectureSelect.value);
    const showResults = showAll || hasFilters;
    if (!showResults) document.title = homepageTitle;
    else {
      // Local-view titles do not change canonical or social metadata or request paths.
      const plainTitle = (value) => {
        const text = value.normalize("NFC").replace(/[\t\n\r\f\v]/g, " ")
          .replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
          .replace(/\s+/gu, " ").trim();
        const characters = Array.from(text);
        return characters.length > 80 ? characters.slice(0, 80).join("") + "…" : text;
      };
      const query = plainTitle(search.value);
      let title = query ? `Search results for ${query}` : search.value.trim() ? "Search results" : "All packages";
      if (!search.value.trim() && hasFilters) {
        title = kindSelect.value === "source" ? "Source packages"
          : kindSelect.value === "executable" ? "Executable packages" : "Assembly packages";
        if (architectureSelect.value) title += ` for ${architectureLabel(architectureSelect.value)}`;
        if (targetSelect.value) title += ` on ${plainTitle(targetSelect.value)}`;
      }
      document.title = title + " | Asm";
    }
    document.body.classList.toggle("has-search-results", showResults && compactSearch);
    list.replaceChildren(...(showResults ? filtered.map(renderPackage) : []));
    list.hidden = !showResults;
    discovery.hidden = showResults;
    toolbar.hidden = !showResults;
    catalogNote.hidden = !showResults;
    browseAll.hidden = !packages.length || (showResults && !hasFilters);
    const registryStatus = (exact) => showResults || !packages.length
      ? packageStatus(packages.length, filtered.length, { exact })
      : `${exact ? exactCount(packages.length) : compactCount(packages.length)} ${packages.length === 1 ? "package" : "packages"} in the registry. Search or explore the discovery lists.`;
    const topicStatus = !search.value.trim() ? "" : topicsLoading ? " Topic labels are loading."
      : searchTopics.some((source) => source === null) ? " Some topic labels are unavailable. Results may omit keyword or category matches." : "";
    setRegistryStatus(invalidSearchMessage || registryStatus(false) + topicStatus,
      invalidSearchMessage || registryStatus(true) + topicStatus);
    status.classList.toggle("sr-only", !invalidSearchMessage && !showResults && packages.length > 0);
    catalogHeading.textContent = hasFilters ? "Search results" : showResults ? "All packages" : "Browse packages";
    if (resetSearch) resetSearch.hidden = !invalidSearchMessage && !showResults;
    if (fallback) fallback.hidden = packages.length > 0;
  }

  function updateSearch(event) {
    if (event?.type === "change") compactSearch = true;
    writeSearchHistory(event?.type === "change");
    renderPackages();
  }

  function restoreSearch() {
    invalidSearchMessage = "";
    let state;
    try { state = parseSearchState(window.location.hash); }
    catch (error) {
      invalidSearchMessage = error.message;
      search.value = "";
      kindSelect.value = "";
      architectureSelect.value = "";
      targetSelect.value = "";
      showAll = false;
      compactSearch = false;
      renderPackages();
      return;
    }
    search.value = state?.query || "";
    kindSelect.value = state?.kind || "";
    updateArchitectureOptions(state?.architecture || "");
    const target = state?.target || "";
    targetSelect.querySelectorAll("[data-unavailable-target]").forEach((option) => option.remove());
    if (target && !Array.from(targetSelect.options).some((option) => option.value === target)) {
      const option = element("option", "", `Unavailable target: ${target}`);
      option.value = target;
      option.dataset.unavailableTarget = "true";
      targetSelect.append(option);
    }
    targetSelect.value = target;
    showAll = Boolean(state?.all);
    compactSearch = Boolean(state);
    renderPackages();
  }

  async function getJSON(path, limit = 0) {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 12000);
    let reader;
    try {
      const response = await fetch(path, { signal: controller.signal, credentials: "omit", redirect: "error" });
      if (!response.ok) throw new Error("Record unavailable");
      if (limit) {
        if (!response.body || Number(response.headers.get("content-length")) > limit) throw new Error("Record exceeds limit");
        reader = response.body.getReader();
        const decoder = new TextDecoder("utf-8", { fatal: true });
        let bytes = 0, text = "";
        for (let reads = 0; reads < 4096; reads++) {
          const { done, value } = await reader.read();
          if (done) return JSON.parse(text + decoder.decode());
          bytes += value.byteLength;
          if (bytes > limit) throw new Error("Record exceeds limit");
          text += decoder.decode(value, { stream: true });
        }
        throw new Error("Record exceeds read limit");
      }
      return await response.json();
    } finally {
      window.clearTimeout(timeout);
      controller.abort();
      reader?.cancel().catch(() => {});
    }
  }

  function updateArchitectureOptions(selected) {
    const groups = architectureGroups(packages);
    const options = [element("option", "", "All architectures")];
    options[0].value = "";
    groups.forEach((group) => {
      const option = element("option", "", `${group.name} (${group.id})`);
      option.value = group.id;
      options.push(option);
    });
    if (selected && !groups.some((group) => group.id === selected)) {
      const option = element("option", "", `Unavailable architecture: ${architectureLabel(selected)} (${selected})`);
      option.value = selected;
      options.push(option);
    }
    architectureSelect.replaceChildren(...options);
    architectureSelect.value = selected;
  }

  function updateCatalog(next) {
    const initial = !catalogReady;
    const selectedTarget = targetSelect.value;
    const selectedArchitecture = architectureSelect.value;
    packages = next;
    const stats = catalogStats(packages);
    document.querySelectorAll("dd[data-catalog-stat]").forEach((node) => {
      const value = stats[node.dataset.catalogStat];
      showCount(node, value);
    });
    updateArchitectureOptions(selectedArchitecture);
    const targets = [...new Set(packages.flatMap(activeArtifacts).map((artifact) => artifact.target))].sort();
    const options = [element("option", "", "All targets")];
    options[0].value = "";
    targets.forEach((target) => {
      const option = element("option", "", target);
      option.value = target;
      options.push(option);
    });
    if (selectedTarget && !targets.includes(selectedTarget)) {
      const option = element("option", "", `Unavailable target: ${selectedTarget}`);
      option.value = selectedTarget;
      option.dataset.unavailableTarget = "true";
      options.push(option);
    }
    targetSelect.replaceChildren(...options);
    targetSelect.value = selectedTarget;
    catalogReady = true;
    if (initial) {
      search.disabled = false;
      targetSelect.disabled = false;
      kindSelect.disabled = false;
      architectureSelect.disabled = false;
      if (searchSubmit) searchSubmit.disabled = false;
      search.addEventListener("input", updateSearch);
      targetSelect.addEventListener("change", updateSearch);
      kindSelect.addEventListener("change", updateSearch);
      architectureSelect.addEventListener("change", updateSearch);
      restoreSearch();
      window.addEventListener("popstate", restoreSearch);
      window.addEventListener("hashchange", restoreSearch);
    } else renderPackages();
  }

  function refreshHasFocus() {
    return discoveryHasFocus() || list.contains(document.activeElement) || toolbar.contains(document.activeElement);
  }

  function applyRefresh(result) {
    if (result.catalog.status === "fulfilled" && !result.initial) {
      updateCatalog(result.catalog.value);
      discoverySnapshot = rejoinDiscovery(discoverySnapshot, packages);
    }
    searchTopics = result.topics.status === "fulfilled" ? result.topics.value.map((source, index) => {
      try { return source.status === "fulfilled" ? normalizeSearchTopics(source.value, packages, index ? "categories" : "keywords") : null; }
      catch { return null; }
    }) : [null, null];
    topicsLoading = false;
    if (catalogReady) renderPackages();
    if (!catalogReady) {
      document.body.classList.remove("has-search-results");
      status.classList.remove("sr-only");
      setRegistryStatus("The package index could not be loaded. Browse all packages or open the index link below.");
      if (fallback) fallback.hidden = false;
    }
    let failed = result.catalog.status === "rejected" || result.discovery.status === "rejected";
    if (catalogReady && result.discovery.status === "fulfilled") {
      try {
        const next = normalizeDiscovery(result.discovery.value, packages);
        if (discoveryObservedAt && (!next.observed_at || Date.parse(next.observed_at) < Date.parse(discoveryObservedAt))) {
          throw new RangeError("Discovery observations cannot move backwards.");
        }
        discoverySnapshot = next;
        discoveryObservedAt = next.observed_at;
      } catch { failed = true; }
    }
    if (failed && discoverySnapshot) {
      discoverySnapshot = { ...discoverySnapshot, stale: true, refresh_error: "The latest refresh failed." };
    }
    discoveryLoading = false;
    renderDiscovery();
  }

  async function refreshData(initial = false) {
    if (refreshRunning || (!initial && document.hidden)) return;
    refreshRunning = true;
    lastRefreshStarted = Date.now();
    if (initial) setRegistryStatus("Loading package records…");
    const catalogRequest = getJSON("registry/v1/index.json").then(normalizeIndex).then((next) => {
      if (initial) { updateCatalog(next); renderDiscovery(); }
      return next;
    });
    const discoveryRequest = getJSON("registry/v1/discovery.json");
    const topicRequest = catalogRequest.then(() => Promise.allSettled([
      getJSON("registry/v1/discovery-metadata.json", 256 * 1024), getJSON("registry/v1/categories.json", 64 * 1024)]));
    const [catalog, snapshot, topics] = await Promise.allSettled([catalogRequest, discoveryRequest, topicRequest]);
    refreshRunning = false;
    const result = { catalog, discovery: snapshot, topics, initial };
    if (refreshHasFocus()) pendingRefresh = result;
    else applyRefresh(result);
  }

  document.addEventListener("focusout", () => {
    queueMicrotask(() => {
      if (pendingRefresh && !refreshHasFocus()) {
        const result = pendingRefresh;
        pendingRefresh = null;
        applyRefresh(result);
      } else if (discoveryRenderPending && !discoveryHasFocus()) renderDiscovery();
    });
  });
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && Date.now() - lastRefreshStarted >= 60000) refreshData();
  });
  window.setInterval(() => { if (!document.hidden) refreshData(); }, 60000);
  function loadRegistry() { return refreshData(true); }
  loadRegistry();
})();
