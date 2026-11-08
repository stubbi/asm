/* Progressive package navigation and artifact filters. AGPL-3.0-or-later. */
"use strict";
(function () {
  const site = window.AsmSite;
  if (!site) return;
  const from = site.readReturnState(window.location.hash);
  if (from) {
    const searchHash = site.searchStateHash(from);
    document.querySelectorAll("[data-back-to-search]").forEach((anchor) => {
      anchor.href = anchor.href.split("#")[0] + searchHash;
      anchor.textContent = "Back to results";
    });
    document.querySelectorAll("a[data-package-link]").forEach((anchor) => {
      const destination = new URL(anchor.href);
      if (destination.origin === window.location.origin && !destination.hash && searchHash) {
        destination.hash = "from=" + encodeURIComponent(searchHash);
        anchor.href = destination.href;
      }
    });
  }

  const sectionLinks = Array.from(document.querySelectorAll('.package-section-nav a[href^="#"]'));
  function updateSectionNavigation() {
    const selected = sectionLinks.find((anchor) => anchor.hash === window.location.hash) || sectionLinks[0];
    sectionLinks.forEach((anchor) => {
      if (anchor === selected) anchor.setAttribute("aria-current", "location");
      else anchor.removeAttribute("aria-current");
    });
  }
  if (sectionLinks.length) {
    updateSectionNavigation();
    window.addEventListener("hashchange", updateSectionNavigation);
  }

  const form = document.querySelector(".package-filter-form");
  const target = document.getElementById("artifact-target");
  const kind = document.getElementById("artifact-kind");
  const architecture = document.getElementById("artifact-architecture");
  const status = document.getElementById("artifact-filter-status");
  const empty = document.querySelector(".package-artifact-empty");
  const artifacts = Array.from(document.querySelectorAll(".package-artifact[data-artifact-kind][data-artifact-target]"));
  if (!form || !target || !kind || !architecture || !status || !empty || !artifacts.length) return;

  function selectFilter(select, value) {
    if (value && !Array.from(select.options).some((option) => option.value === value)) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = `Unavailable in this release: ${value}`;
      select.append(option);
    }
    select.value = value || "";
  }

  function update() {
    let shown = 0;
    let selected = null;
    artifacts.forEach((artifact) => {
      const matches = site.matchesArtifact(kind.value, target.value,
        { kind: artifact.dataset.artifactKind, target: artifact.dataset.artifactTarget }, architecture.value);
      artifact.hidden = !matches;
      if (matches) { shown += 1; selected = artifact; }
    });
    empty.hidden = shown > 0;
    const noun = shown === 1 ? "artifact" : "artifacts";
    status.textContent = `${site.compactCount(shown)} ${noun} shown.`;
    status.title = `${site.exactCount(shown)} ${noun} shown.`;
    status.setAttribute("aria-label", status.title);
    const quick = document.querySelector("[data-selected-fetch]");
    const command = document.getElementById("selected-fetch-command");
    const label = document.querySelector("[data-selected-fetch-label]");
    const selection = document.querySelector("[data-fetch-selection]");
    if (quick && command && label && selection) {
      const source = shown === 1 && selected?.querySelector(".command-block code");
      quick.hidden = !source;
      selection.hidden = Boolean(source);
      command.textContent = source ? selected.dataset.fetchCommand || source.textContent : "";
      if (source) label.textContent = `${selected.querySelector("h3").textContent} · ${selected.dataset.artifactTarget}`;
      selection.textContent = shown === 0 ? "No files match. Clear the file filters or choose another option."
        : "Choose a release file below. Each file includes its exact fetch command.";
    }
  }

  selectFilter(target, from?.target);
  selectFilter(kind, from?.kind);
  selectFilter(architecture, from?.architecture);
  form.addEventListener("submit", (event) => event.preventDefault());
  target.addEventListener("change", update);
  kind.addEventListener("change", update);
  architecture.addEventListener("change", update);
  document.querySelectorAll("[data-clear-artifact-filters]").forEach((button) => {
    button.addEventListener("click", () => {
      target.value = "";
      kind.value = "";
      architecture.value = "";
      update();
    });
  });
  form.hidden = artifacts.length === 1 && (!from || site.matchesArtifact(from.kind, from.target,
    { kind: artifacts[0].dataset.artifactKind, target: artifacts[0].dataset.artifactTarget }, from.architecture));
  update();
})();
