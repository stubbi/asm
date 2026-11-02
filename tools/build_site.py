#!/usr/bin/env python3
"""Build the static asm site and generated registry. Nothing is uploaded."""

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

import registry
import bootstrap
from release import materialize, output_path, publish_directory, resolve_commit


ASSET_HOSTS = {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"}
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
        registry.require(API_PATTERN.fullmatch(url) is not None, "metrics URL must identify a GitHub release")


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
    request = Request(url, headers={"User-Agent": "asm-site-builder/1", "Accept-Encoding": "identity"})
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


def verify_artifacts(records: list[dict], read=read_https) -> set[tuple[str, str]]:
    checked = set()
    for record in registry.check_records(records):
        for artifact in record["artifacts"]:
            registry.artifact_url(artifact["url"])
            data = read(artifact["url"], registry.MAX_ARTIFACT_BYTES, ASSET_HOSTS, expected_size=artifact["bytes"])
            registry.validate_artifact(data, record, artifact)
        checked.add((record["name"], record["version"]))
    return checked


def metrics_json(url: str) -> dict:
    registry.require(API_PATTERN.fullmatch(url) is not None, "untrusted metrics URL")
    value = registry.strict_json(read_https(url, 2 * 1024 * 1024, {"api.github.com"}))
    registry.require(isinstance(value, dict), "metrics response must be an object")
    return value


def unknown_counts(records: list[dict]) -> dict:
    packages = {}
    for record in records:
        package = packages.setdefault(record["name"], {"total": None, "versions": {}})
        package["versions"][record["version"]] = None
    return {"schema": 1, "source": "github-release-assets", "observed_at": None, "packages": packages}


def write_reference(repo: Path, commit: str, output: Path) -> None:
    files = registry.git_files(repo, commit, "cli")
    selected = {name: data for name, data in files.items() if name.endswith((".s", ".inc")) or name == "commands.json"}
    registry.require(selected, "source commit has no CLI reference files")
    materialize(selected, output)
    rows = []
    for name, (data, _) in sorted(selected.items()):
        rows.append(f'<li><a href="{escape(name, quote=True)}">{escape(name)}</a><code>{hashlib.sha256(data).hexdigest()}</code></li>')
    page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>CLI source reference — asm</title>
<meta name="description" content="Read the asm CLI source for Linux and Apple Silicon macOS. Inspect the source commit and SHA-256 file digests.">
<link rel="canonical" href="https://asm.build/reference/">
<link rel="stylesheet" href="../styles.css"></head>
<body class="reference-page"><main class="container section"><a href="../">← asm.build</a>
<p class="eyebrow">SOURCE REFERENCE</p><h1>Read the CLI.</h1>
<p>These files come from commit <code>{commit}</code>.</p>
<p>Each file has a SHA-256 digest. A digest identifies bytes; it does not prove code safety.</p>
<ul class="reference-files">{"".join(rows)}</ul>
<p><a href="https://github.com/stubbi/asm/tree/{commit}/cli">Browse this commit on GitHub ↗</a></p>
</main></body></html>'''
    (output / "index.html").write_text(page, encoding="utf-8")


def build_site(repo: Path, registry_path: Path, output: Path, *, verify: bool = False,
               downloads: bool = False, reference: str = "HEAD", artifact_reader=read_https,
               metrics_fetcher=metrics_json, trust_publication: Path | None = None,
               trust_verifier: Path | None = None, trust_inspector: Path | None = None) -> dict:
    output = output_path(output)
    commit = resolve_commit(repo, reference)
    records = registry.read_records(registry_path)
    checked = verify_artifacts(records, artifact_reader) if verify else set()
    tsv, index = registry.make_indexes(records, checked)
    counts = registry.download_counts(records, fetch=metrics_fetcher) if downloads else unknown_counts(records)
    with tempfile.TemporaryDirectory(prefix=".asm-site-", dir=output.parent) as temporary:
        stage = Path(temporary) / "site"
        materialize(registry.collect_files(repo / "site"), stage)
        # Source references use a recorded commit, never an uncommitted file.
        write_reference(repo, commit, stage / "reference")
        destination = stage / "registry/v1"
        registry.write_atomic(destination / "index.tsv", registry.legacy_tsv(tsv).encode("ascii"))
        registry.write_atomic(destination / "index-macos.tsv", tsv.encode("ascii"))
        registry.write_atomic(destination / "index.json", registry.json_bytes(index))
        registry.write_atomic(destination / "downloads.json", registry.json_bytes(counts))
        for record in records:
            registry.write_atomic(destination / "packages" / record["name"] / (record["version"] + ".json"), registry.json_bytes(record))
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
                 "artifact_checked_releases": len(checked), "download_counts_requested": downloads,
                 "bootstrap_version": installer["version"] if installer else None}
        registry.write_atomic(stage / "build.json", registry.json_bytes(build))
        publish_directory(stage, output)
    return build


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--registry", type=Path, default=Path("registry"))
    parser.add_argument("--output", type=Path, default=Path(".pages"), help="new output directory")
    parser.add_argument("--reference-commit", default="HEAD")
    parser.add_argument("--verify-artifacts", action="store_true", help="download and validate every declared artifact")
    parser.add_argument("--download-counts", "--downloads", action="store_true", dest="downloads", help="read optional GitHub asset counters")
    parser.add_argument("--trust-publication", type=Path, help="fresh signed asm TUF publication")
    parser.add_argument("--trust-verifier", type=Path, help="locally built asm-verify")
    parser.add_argument("--trust-inspector", type=Path, help="locally built asm-trust")
    args = parser.parse_args(argv)
    try:
        build = build_site(args.repo, args.registry, args.output, verify=args.verify_artifacts,
                           downloads=args.downloads, reference=args.reference_commit,
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
