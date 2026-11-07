#!/usr/bin/env python3
"""Build the static Asm site and generated registry. Nothing is uploaded."""

from __future__ import annotations

import argparse
import hashlib
from html import escape
from pathlib import Path
import re
import sys
import subprocess
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from xml.etree import ElementTree

import registry
import bootstrap
import package_pages
import discovery
import discovery_metadata
import registry_explore
import registry_stats
import release_blog
import site_docs
import repository_stars
from release import materialize, output_path, publish_directory, resolve_commit


ASSET_HOSTS = {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"}
MAX_HTML_BYTES = 4 * 1024 * 1024
API_PATTERN = re.compile(r"https://api\.github\.com/repos/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}/releases/tags/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")


def check_https_url(url: str, hosts: set[str]) -> None:
    registry.require(isinstance(url, str) and len(url) <= 16384, "download URL is invalid")
    registry.require(all(33 <= ord(char) <= 126 for char in url), "download URL contains whitespace or control characters")
    parsed = urlsplit(url)
    registry.require(parsed.scheme == "https" and parsed.netloc in hosts,
                     "download redirect uses an unapproved origin")
    registry.require(not parsed.fragment, "download URL cannot contain a fragment")
    if parsed.netloc == "github.com":
        registry.artifact_url(url)
    elif parsed.netloc == "api.github.com":
        registry.require(API_PATTERN.fullmatch(url) is not None or url == repository_stars.API_URL,
                         "metrics URL must identify an approved GitHub resource")


class RestrictedRedirects(HTTPRedirectHandler):
    max_redirections = 4
    max_repeats = 2

    def __init__(self, hosts: set[str]):
        self.hosts = hosts
        super().__init__()

    def redirect_request(self, request, response, code, message, headers, newurl):
        check_https_url(newurl, self.hosts)
        return super().redirect_request(request, response, code, message, headers, newurl)


def read_https(url: str, limit: int, hosts: set[str], *, expected_size: int | None = None, opener=None) -> bytes:
    check_https_url(url, hosts)
    registry.require(type(limit) is int and 0 < limit <= registry.MAX_ARTIFACT_BYTES, "download limit is invalid")
    if expected_size is not None:
        registry.require(type(expected_size) is int and 0 < expected_size <= limit, "declared download size is invalid")
    opener = opener or build_opener(RestrictedRedirects(hosts))
    headers = {"User-Agent": "asm-site-builder/1", "Accept-Encoding": "identity"}
    if urlsplit(url).netloc == "api.github.com":
        headers.update({"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
    request = Request(url, headers=headers)
    with opener.open(request, timeout=20) as response:
        check_https_url(response.geturl(), hosts)
        registry.require(response.status == 200, "download did not return HTTP 200")
        encoding = response.headers.get("Content-Encoding", "identity").lower()
        registry.require(encoding == "identity", "unexpected download content encoding")
        length = response.headers.get("Content-Length")
        if length is not None:
            registry.require(re.fullmatch(r"[0-9]+", length) is not None, "invalid Content-Length")
            registry.require(int(length) <= limit, "download exceeds the byte limit")
            if expected_size is not None:
                registry.require(int(length) == expected_size, "download Content-Length differs from the release record")
        data = response.read(min(limit, expected_size) + 1 if expected_size is not None else limit + 1)
        registry.require(len(data) <= limit, "download exceeds the byte limit")
        if expected_size is not None:
            registry.require(len(data) == expected_size, "download size differs from the release record")
        return data


def verify_artifacts(records: list[dict], read=read_https, *, dependency_metadata: dict | None = None) -> set[tuple[str, str]]:
    checked = set()
    for record in registry.check_records(records):
        for artifact in record["artifacts"]:
            registry.artifact_url(artifact["url"])
            data = read(artifact["url"], registry.MAX_ARTIFACT_BYTES, ASSET_HOSTS, expected_size=artifact["bytes"])
            registry.validate_artifact(data, record, artifact, dependency_metadata=dependency_metadata)
        checked.add((record["name"], record["version"]))
    return checked


def metrics_json(url: str) -> dict:
    registry.require(API_PATTERN.fullmatch(url) is not None, "untrusted metrics URL")
    value = registry.strict_json(read_https(url, 2 * 1024 * 1024, {"api.github.com"}))
    registry.require(isinstance(value, dict), "metrics response must be an object")
    return value


def repository_json(url: str) -> dict:
    registry.require(url == repository_stars.API_URL, "untrusted repository metrics URL")
    value = registry.strict_json(read_https(url, 256 * 1024, {"api.github.com"}))
    registry.require(isinstance(value, dict), "repository response must be an object")
    return value


def unknown_counts(records: list[dict]) -> dict:
    packages = {}
    for record in records:
        package = packages.setdefault(record["name"], {"total": None, "versions": {}})
        package["versions"][record["version"]] = None
    return {"schema": 1, "source": "github-release-assets", "observed_at": None, "packages": packages}


def extend_sitemap(stage: Path, routes: list[str]) -> None:
    path = stage / "sitemap.xml"
    try:
        tree = ElementTree.parse(path)
    except ElementTree.ParseError as error:
        raise registry.RegistryError("site sitemap is invalid") from error
    namespace = "http://www.sitemaps.org/schemas/sitemap/0.9"
    tag = "{" + namespace + "}"
    registry.require(tree.getroot().tag == tag + "urlset", "site sitemap needs a URL set")
    existing = {item.text for item in tree.findall(f"{tag}url/{tag}loc")}
    for route in sorted(routes):
        if route == "404.html":
            continue
        location = "https://asm.build/" + route
        if location not in existing:
            entry = ElementTree.SubElement(tree.getroot(), tag + "url")
            ElementTree.SubElement(entry, tag + "loc").text = location
            existing.add(location)
    ElementTree.register_namespace("", namespace)
    ElementTree.indent(tree, space="  ")
    registry.write_atomic(path, ElementTree.tostring(tree.getroot(), encoding="utf-8", xml_declaration=True) + b"\n")


def write_reference(repo: Path, commit: str, output: Path) -> None:
    files = registry.git_files(repo, commit, "cli")
    selected = {name: data for name, data in files.items() if name.endswith((".s", ".inc")) or name == "commands.json"}
    registry.require(selected, "source commit has no CLI reference files")
    materialize(selected, output)
    rows = []
    for name, (data, _) in sorted(selected.items()):
        rows.append(f'<li><a href="{escape(name, quote=True)}">{escape(name)}</a><code>{hashlib.sha256(data).hexdigest()}</code></li>')
    page = f'''<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="theme-color" content="#f5f5f4">
    <meta name="description" content="Read the Asm CLI source for Linux and Apple Silicon macOS. Inspect the source commit and SHA-256 file digests.">
    <meta property="og:type" content="website">
    <meta property="og:title" content="CLI source reference — asm">
    <meta property="og:description" content="Read the Asm CLI source for Linux and Apple Silicon macOS. Inspect the source commit and SHA-256 file digests.">
    <meta property="og:url" content="https://asm.build/reference/">
    <meta property="og:image" content="https://asm.build/social-preview.png">
    <meta property="og:image:alt" content="Asm package search, with the &gt;asm wordmark and asm.build.">
    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:title" content="CLI source reference — asm">
    <meta name="twitter:description" content="Read the Asm CLI source for Linux and Apple Silicon macOS. Inspect the source commit and SHA-256 file digests.">
    <meta name="twitter:image" content="https://asm.build/social-preview.png">
    <link rel="canonical" href="https://asm.build/reference/">
    <link rel="icon" type="image/svg+xml" href="../icon.svg">
    <link rel="stylesheet" href="../styles.css">
    <script src="../navigation.js"></script>
    <script src="../repository-stars.js" defer></script>
    <title>CLI source reference — asm</title>
  </head>
  <body class="reference-page">
    <a class="skip-link" href="#main">Skip to content</a>
    <header class="site-header">
      <div class="masthead-surface" aria-hidden="true"></div>
      <div class="container header-inner">
        <a class="wordmark" href="../index.html" aria-label="Asm home"><img src="../wordmark.svg" width="232" height="72" alt="asm"></a>
        <form class="header-search" data-header-search action="../index.html" method="get" role="search" aria-label="Package search" hidden>
          <div class="search-box header-search-box">
            <label for="header-package-search">Search</label>
            <input id="header-package-search" name="q" type="search" maxlength="512" autocomplete="off" spellcheck="false" placeholder="Packages" enterkeyhint="search">
            <button type="submit" aria-label="Search packages" title="Search packages"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true" focusable="false"><circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/></svg></button>
          </div>
        </form>
        <a class="header-search-fallback" data-header-search-fallback href="../packages/">Browse packages</a>
        <nav aria-label="Main navigation">
          <a href="../explore/">Explore</a>
          <a href="../stats/">Stats</a>
          <a href="../blog/">Blog</a>
          <a href="../docs/" aria-current="page">Docs</a>
        </nav>
        <!-- github-stars:start --><a class="github-stars" href="https://github.com/stubbi/asm"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="m12 3 2.8 5.7 6.3.9-4.6 4.4 1.1 6.3-5.6-3-5.6 3 1.1-6.3L2.9 9.6l6.3-.9Z"/></svg><span>Star on GitHub</span></a><!-- github-stars:end -->
      </div>
    </header>

    <main id="main" class="container section">
      <p class="eyebrow">SOURCE REFERENCE</p>
      <h1>Read the CLI.</h1>
      <p>These files come from commit <code>{commit}</code>.</p>
      <p>Each file has a SHA-256 digest. A digest identifies bytes; it does not prove code safety.</p>
      <ul class="reference-files">{"".join(rows)}</ul>
      <p><a class="text-link" href="https://github.com/stubbi/asm/tree/{commit}/cli">Browse this commit on GitHub <span aria-hidden="true">↗</span></a></p>
    </main>

<footer class="site-footer">
      <div class="container registry-footer-grid">
        <div class="footer-brand">
          <a class="wordmark" href="../index.html" aria-label="Asm home"><img src="../wordmark.svg" width="232" height="72" alt="asm"></a>
          <p>A home for assembly.</p>
        </div>
        <div class="footer-navs">
          <nav aria-label="Learn"><h2>Learn</h2><a href="../docs/">Docs</a><a href="../guide.html">Guide</a><a href="https://github.com/stubbi/asm#install-the-command">Install Asm</a><a href="../reference/">CLI source</a><a href="../agents.md">For AI agents</a></nav>
          <nav aria-label="Registry"><h2>Registry</h2><a href="../explore/">Explore</a><a href="../packages/">All packages</a><a href="../browse/new/">New packages</a><a href="../browse/popular/">Most downloaded</a><a href="../stats/">Statistics</a></nav>
          <nav aria-label="Project"><h2>Project</h2><a href="../guide.html#why">Why Asm</a><a href="../blog/">Blog</a><a href="https://github.com/stubbi/asm">Source code</a><a href="https://github.com/stubbi/asm/blob/main/docs/roadmap.md">Roadmap</a><a href="../sponsors.html">Sponsorship</a></nav>
          <nav aria-label="Help"><h2>Help</h2><a href="https://github.com/stubbi/asm/issues">Report an issue</a><a href="https://github.com/stubbi/asm/blob/main/docs/specs/security.md">Security model</a><a href="https://github.com/stubbi/asm/blob/main/CONTRIBUTING.md">Contribute</a><a href="https://github.com/stubbi/asm#status">Supported hosts</a></nav>
        </div>
      </div>
      <div class="footer-support">
        <div class="container footer-support-inner">
          <div><h2>Help build Asm</h2><p>Contribute code, improve the guide, or support the project.</p></div>
          <div class="footer-support-actions"><a class="button button-secondary" href="https://github.com/stubbi/asm/blob/main/CONTRIBUTING.md">Contribute</a><a class="button button-primary" href="../sponsors.html">Sponsor Asm</a></div>
        </div>
      </div>
    </footer>
  </body>
</html>'''
    (output / "index.html").write_text(page, encoding="utf-8")


def build_site(repo: Path, registry_path: Path, output: Path, *, verify: bool = False,
               downloads: bool = False, reference: str = "HEAD", artifact_reader=read_https,
               metrics_fetcher=metrics_json, discovery_state: Path | None = None, publication_state: Path | None = None,
               repository_state: Path | None = None, refresh_repository: bool = False, repository_fetcher=repository_json,
               include_blog_drafts: bool = False,
               delivery: bool = False, trust_publication: Path | None = None,
               trust_verifier: Path | None = None, trust_inspector: Path | None = None) -> dict:
    output = output_path(output)
    for private_path in (discovery_state, publication_state, repository_state):
        if private_path is not None:
            private_state = private_path.resolve()
            registry.require(not any(private_state.is_relative_to(root.resolve()) for root in
                                     (output, repo / "site", repo / "skills/asm-build")),
                             "keep discovery state outside published site sources and output")
    commit = resolve_commit(repo, reference)
    records = registry.read_records(registry_path)
    dependency_metadata = {}
    checked = verify_artifacts(records, artifact_reader, dependency_metadata=dependency_metadata) if verify else set()
    tsv, index = registry.make_indexes(records, checked, dependency_metadata=dependency_metadata)
    declarations = {"schema": 1, "sources": []}
    for package in index["packages"]:
        for version in package["versions"]:
            for artifact in version["artifacts"]:
                metadata = artifact.pop("dependency_metadata", None)
                if metadata is not None:
                    declarations["sources"].append({"name": package["name"], "version": version["version"],
                                                  "target": artifact["target"], "metadata": metadata})
    registry.require(len(declarations["sources"]) <= registry.MAX_ROWS, "dependency declarations have too many source entries")
    declaration_bytes = registry.json_bytes(declarations)
    registry.require(len(declaration_bytes) <= 4 * 1024 * 1024, "dependency declarations exceed four MiB")
    fetched = {}
    def cached_metrics(url):
        if url not in fetched:
            try:
                fetched[url] = metrics_fetcher(url)
            except (registry.RegistryError, OSError, ValueError, HTTPError, URLError) as error:
                fetched[url] = registry.RegistryError("Release metadata could not be read.") if isinstance(error, ValueError) else error
        if isinstance(fetched[url], Exception):
            raise fetched[url]
        return fetched[url]
    publication = discovery.unknown_snapshot(records)
    if publication_state is not None:
        if downloads:
            try:
                publication = discovery.collect(records, publication_state, fetch=cached_metrics)
            except (registry.RegistryError, OSError, ValueError, HTTPError, URLError):
                publication = discovery.load_snapshot(publication_state, records)
        else:
            publication = discovery.load_snapshot(publication_state, records)
    observation = None
    if discovery_state is not None and discovery_state.exists():
        import download_data
        try:
            observation = download_data.Store(discovery_state, records).snapshot()
        except (registry.RegistryError, OSError, ValueError):
            pass
    snapshot = discovery.delivery_snapshot(records, publication, observation)
    counts = discovery.delivery_counts(records, observation)
    stars = repository_stars.unknown_snapshot()
    if repository_state is not None:
        stars = (repository_stars.collect(repository_state, repository_fetcher) if refresh_repository
                 else repository_stars.load_snapshot(repository_state))
    categories = package_pages.read_discovery_categories(registry_path, index)
    metadata = discovery_metadata.read_metadata(registry_path, index)
    with tempfile.TemporaryDirectory(prefix=".asm-site-", dir=output.parent) as temporary:
        stage = Path(temporary) / "site"
        materialize(registry.collect_files(repo / "site"), stage)
        package_pages.write_catalog_stats(stage, index)
        package_pages.write_architecture_browse(stage, index)
        (stage / "skills").mkdir(exist_ok=True)
        materialize(registry.collect_files(repo / "skills/asm-build"), stage / "skills/asm-build")
        # Source references use a recorded commit, never an uncommitted file.
        write_reference(repo, commit, stage / "reference")
        destination = stage / "registry/v1"
        registry.write_atomic(destination / "index.tsv", registry.legacy_tsv(tsv).encode("ascii"))
        registry.write_atomic(destination / "index-macos.tsv", registry.macos_compat_tsv(tsv).encode("ascii"))
        registry.write_atomic(destination / "index-all.tsv", tsv.encode("ascii"))
        registry.write_atomic(destination / "index.json", registry.json_bytes(index))
        registry.write_atomic(destination / "dependencies.json", declaration_bytes)
        registry.write_atomic(destination / "downloads.json", registry.json_bytes(counts))
        registry.write_atomic(destination / "github.json", registry.json_bytes(stars))
        registry.write_atomic(destination / "categories.json", registry.json_bytes({"schema": 1, "categories": categories}))
        metadata_file = registry_path / "discovery-metadata.json"
        metadata_bytes = (registry.read_regular(registry_path, "discovery-metadata.json", discovery_metadata.MAX_BYTES)
                          if metadata_file.exists() or metadata_file.is_symlink() else registry.json_bytes({"schema": 1, "packages": []}))
        registry.write_atomic(destination / "discovery-metadata.json", metadata_bytes)
        snapshot = package_pages.with_discovery_categories(stage, index, snapshot)
        registry.write_atomic(destination / "discovery.json", registry.json_bytes(snapshot))
        activities = {}
        identities = [(package["name"], None) for package in index["packages"]]
        identities.extend((record["name"], record["version"]) for record in records)
        for name, version in identities:
            activity = discovery.delivery_activity(records, name, observation, version=version)
            route = "activity/" + name + ("/" + version if version else "") + ".json"
            registry.write_atomic(destination / route, registry.json_bytes(activity))
            activities[(name, version)] = activity
        for record in records:
            registry.write_atomic(destination / "packages" / record["name"] / (record["version"] + ".json"), registry.json_bytes(record))
        routes = package_pages.write_package_pages(repo, stage, records, index, counts, delivery=delivery,
                                                   activities=activities, publications=snapshot, dependency_metadata=declarations)
        routes.extend(package_pages.write_discovery_pages(stage, index, snapshot))
        retained = discovery.retained_counts(records, observation)
        routes.extend(registry_explore.write_explore(stage, index, snapshot, metadata, retained))
        routes.extend(registry_stats.write_stats(stage, index, snapshot, observation, records))
        dates = discovery.release_dates(publication_state, records) if publication_state is not None else {}
        cli_dates = {record["version"]: dates.get(record["name"] + "@" + record["version"])
                     for record in records if record["name"] == release_blog.NAME}
        routes.extend(release_blog.write_release_blog(repo, stage, index, snapshot, release_dates=cli_dates,
                                                     include_drafts=include_blog_drafts))
        routes.extend(site_docs.write_docs(repo, stage))
        extend_sitemap(stage, routes)
        installer = bootstrap.write_bootstrap(
            stage, records, checked,
            bundle_reader=lambda url, limit: artifact_reader(url, limit, ASSET_HOSTS))
        if trust_publication is not None:
            import trusted_site
            registry.require(verify and trust_verifier is not None and trust_inspector is not None,
                             "trusted site requires artifact checks, verifier, and inspector")
            trusted_site.attach(stage, repo, trust_publication, installer,
                                lambda url, limit: artifact_reader(url, limit, ASSET_HOSTS), trust_verifier, trust_inspector)
        build = {"schema": 1, "reference_commit": commit, "releases": len(records),
                 "artifact_checked_releases": len(checked), "historical_publication_refresh_requested": downloads,
                 "download_source": "asm-delivery-events",
                 "blog_drafts_included": include_blog_drafts,
                 "bootstrap_version": installer["version"] if installer else None,
                 "discovery_policy": snapshot["policy"], "discovery_observed_at": snapshot["observed_at"]}
        registry.write_atomic(stage / "build.json", registry.json_bytes(build))
        for page in stage.rglob("*.html"):
            relative = page.relative_to(stage).as_posix()
            content = registry.read_regular(stage, relative, MAX_HTML_BYTES).decode("utf-8")
            # Cached HTML must not keep an expired numeric observation visible.
            registry.write_atomic(page, repository_stars.render_header(content, repository_stars.unknown_snapshot()).encode("utf-8"))
        publish_directory(stage, output)
    return build


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--registry", type=Path, default=Path("registry"))
    parser.add_argument("--output", type=Path, default=Path(".pages"), help="new output directory")
    parser.add_argument("--reference-commit", default="HEAD")
    parser.add_argument("--verify-artifacts", action="store_true", help="download and validate every declared artifact")
    parser.add_argument("--refresh-publications", "--download-counts", "--downloads", action="store_true", dest="downloads", help="refresh historical upstream publication metadata; counters do not affect Popular")
    parser.add_argument("--discovery-state", type=Path, default=Path("build/download-data/events.sqlite3"),
                        help="private retained download observations, outside the published site")
    parser.add_argument("--publication-state", type=Path, default=Path("build/discovery-state/history.sqlite3"),
                        help="historical publication adapter state, separate from download events")
    parser.add_argument("--repository-state", type=Path, default=Path("build/repository-state/github.json"),
                        help="private cached GitHub star observation")
    parser.add_argument("--refresh-repository", action="store_true", help="refresh GitHub stars when the cache is due")
    parser.add_argument("--include-blog-drafts", action="store_true", help="include labelled, noindex blog drafts for a local preview")
    parser.add_argument("--artifact-delivery", action="store_true", help="link checked files to the Asm delivery endpoint")
    parser.add_argument("--trust-publication", type=Path, help="fresh signed Asm TUF publication")
    parser.add_argument("--trust-verifier", type=Path, help="locally built asm-verify")
    parser.add_argument("--trust-inspector", type=Path, help="locally built asm-trust")
    args = parser.parse_args(argv)
    try:
        build = build_site(args.repo, args.registry, args.output, verify=args.verify_artifacts,
                           downloads=args.downloads, reference=args.reference_commit, discovery_state=args.discovery_state,
                           publication_state=args.publication_state, delivery=args.artifact_delivery,
                           repository_state=args.repository_state, refresh_repository=args.refresh_repository,
                           include_blog_drafts=args.include_blog_drafts,
                           trust_publication=args.trust_publication, trust_verifier=args.trust_verifier, trust_inspector=args.trust_inspector)
        print(f"Built {args.output} with {build['releases']} release records.")
        print(f"Checked artifact bytes for {build['artifact_checked_releases']} releases.")
        if not args.verify_artifacts:
            print("Artifact evidence remains not-run. Use --verify-artifacts after the release assets are public.")
        return 0
    except (registry.RegistryError, OSError, UnicodeError, ValueError, HTTPError, URLError, subprocess.SubprocessError) as error:
        print(f"build-site: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
