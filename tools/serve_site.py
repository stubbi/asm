#!/usr/bin/env python3
"""Serve a built site and live, cached discovery observations on loopback.

This local registry tool supplies checked artifacts and Asm delivery events.
It does not execute packages or claim production deployment qualification.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
from copy import deepcopy
from datetime import datetime, timezone
from io import BytesIO
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import math
from pathlib import Path
import re
import sys
import threading
from urllib.parse import unquote, urlsplit

import build_site
import discovery
import download_data
import package_pages
import package_activity
import discovery_metadata
import registry_explore
import registry_stats
import registry
import repository_stars
import site_routes


class DiscoveryService:
    """Cache a projection of Asm events independently of requests and hosting."""

    def __init__(self, records: list[dict], state_path: Path, *, refresh_seconds=5,
                 publication_state: Path | None = None, publication: dict | None = None):
        registry.require(isinstance(refresh_seconds, (int, float)) and
                         math.isfinite(refresh_seconds) and 0 < refresh_seconds <= 30,
                         "refresh interval must be positive and at most 30 seconds")
        self.records = registry.check_records(deepcopy(records))
        self.state_path = Path(state_path)
        self.refresh_seconds = refresh_seconds
        self.publication = publication or (discovery.load_snapshot(publication_state, self.records)
                                          if publication_state is not None else discovery.unknown_snapshot(self.records))
        self.store = download_data.Store(self.state_path, self.records)
        self.session_id = None
        self._current = discovery.delivery_snapshot(self.records, self.publication)
        self._counts = discovery.delivery_counts(self.records, None)
        self._observation = None
        self._lock = threading.Lock()
        self._refresh_lock = threading.Lock()
        self._stop = threading.Event()
        self._worker = None

    def snapshot(self) -> dict:
        with self._lock:
            result = deepcopy(self._current)
        observed = result.get("observed_at")
        if observed is None or (datetime.now(timezone.utc) -
                datetime.fromisoformat(observed.replace("Z", "+00:00"))).total_seconds() > 60:
            result["stale"] = True
        return result

    def counts_snapshot(self) -> dict:
        with self._lock:
            result = deepcopy(self._counts)
        observed = result.get("observed_at")
        if observed is None or (datetime.now(timezone.utc) -
                datetime.fromisoformat(observed.replace("Z", "+00:00"))).total_seconds() > 60:
            result["stale"] = True
        return result

    def activity_snapshot(self, name, version=None) -> dict:
        with self._lock:
            observation = deepcopy(self._observation)
        result = discovery.delivery_activity(self.records, name, observation, version=version)
        observed = result.get("observed_at")
        if observed is None or (datetime.now(timezone.utc) -
                datetime.fromisoformat(observed.replace("Z", "+00:00"))).total_seconds() > 60:
            result["stale"] = True
        return result

    def page_snapshot(self) -> tuple[dict, dict | None]:
        """Pin totals and daily observations to one cached reporting cutoff."""
        with self._lock:
            counts, observation = deepcopy(self._counts), deepcopy(self._observation)
        observed = counts.get("observed_at")
        if observed is None or (datetime.now(timezone.utc) -
                datetime.fromisoformat(observed.replace("Z", "+00:00"))).total_seconds() > 60:
            counts["stale"] = True
            if observation is not None:
                observation["stale"] = True
        return counts, observation

    def hub_snapshot(self) -> tuple[dict, dict | None]:
        """Keep discovery and cumulative statistics at the same cached cutoff."""
        with self._lock:
            snapshot, observation = deepcopy(self._current), deepcopy(self._observation)
        observed = snapshot.get("observed_at")
        if observed is None or (datetime.now(timezone.utc) -
                datetime.fromisoformat(observed.replace("Z", "+00:00"))).total_seconds() > 60:
            snapshot["stale"] = True
            if observation is not None:
                observation["stale"] = True
        return snapshot, observation

    def refresh(self) -> dict:
        if not self._refresh_lock.acquire(blocking=False):
            return self.snapshot()
        try:
            try:
                if self.session_id is None:
                    self.session_id = self.store.begin()
                self.store.heartbeat(self.session_id)
                observation = self.store.snapshot()
                current = discovery.delivery_snapshot(self.records, self.publication, observation)
                counts = discovery.delivery_counts(self.records, observation)
            except Exception:
                self.session_id = None
                with self._lock:
                    self._current["stale"] = True
                    self._current["refresh_error"] = "Download reporting is unavailable. Showing the last available observation."
                    self._counts["stale"] = True
                    if self._observation is not None:
                        self._observation["stale"] = True
            else:
                with self._lock:
                    self._current = current
                    self._counts = counts
                    self._observation = observation
            return self.snapshot()
        finally:
            self._refresh_lock.release()

    def start(self) -> None:
        if self._worker is not None and self._worker.is_alive():
            return
        self._stop.clear()
        self.refresh()
        self._worker = threading.Thread(target=self._run, name="asm-download-projection", daemon=True)
        self._worker.start()

    def _run(self) -> None:
        while not self._stop.wait(self.refresh_seconds):
            self.refresh()

    def stop(self) -> None:
        self._stop.set()
        if self._worker is not None and self._worker is not threading.current_thread():
            self._worker.join(timeout=1)
        if self.session_id is not None:
            try:
                self.store.finish(self.session_id)
            except Exception:
                pass
            self.session_id = None


class LoopbackHTTPServer(ThreadingHTTPServer):
    """The local data tool cannot be changed into a public listener by a flag."""

    daemon_threads = True
    request_queue_size = 16

    def __init__(self, address, handler):
        if address[0] != "127.0.0.1":
            raise ValueError("The local site server must bind to 127.0.0.1.")
        super().__init__(address, handler)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        return connection, address


def build_handler(site: Path, index: dict, service: DiscoveryService, delivery=None, repository=None):
    site = Path(site).resolve(strict=True)
    registry.require(site.is_dir(), "site must be a directory")
    registry.require(not service.state_path.resolve().is_relative_to(site),
                     "keep discovery state outside the public site directory")
    registry.require(index.get("schema") == 1 and isinstance(index.get("packages"), list),
                     "unsupported website index")
    expected = registry.make_indexes(service.records)[1]
    metadata = deepcopy(index)
    for catalog in (expected, metadata):
        for package in catalog["packages"]:
            registry.require(isinstance(package, dict) and isinstance(package.get("versions"), list),
                             "invalid website package metadata")
            for release in package["versions"]:
                registry.require(isinstance(release, dict), "invalid website release metadata")
                # Byte checks belong to the built index; identity comes from records.
                release.pop("evidence", None)
    registry.require(metadata == expected,
                     "build the site from this registry before starting the server")
    routes = site_routes.PageRoutes.from_directory(site)

    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(site), **kwargs)

        def log_message(self, format, *args):
            # Requests can contain private queries. No request URLs are logged.
            pass

        def end_headers(self):
            self.send_header("X-Content-Type-Options", "nosniff")
            super().end_headers()

        def _path(self):
            authorities = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
            if self.server.server_port == 80:
                authorities.update({"127.0.0.1", "localhost"})
            hosts = self.headers.get_all("Host", [])
            origins = self.headers.get_all("Origin", [])
            if len(hosts) != 1 or hosts[0] not in authorities or len(origins) > 1 or (
                    origins and origins[0] not in {"http://" + value for value in authorities}):
                self.send_error(403, "Use the local site address.")
                return None
            try:
                parsed = urlsplit(self.path)
                path = unquote(parsed.path, errors="strict")
                if (len(self.path) > 8192 or parsed.scheme or parsed.netloc or not path.startswith("/") or
                        "\\" in path or any(ord(char) < 32 or ord(char) == 127 for char in path) or
                        any(part in {".", ".."} for part in path.split("/"))):
                    raise ValueError("invalid local path")
                # Apply the route parser's decoding checks before dispatch or
                # custom error HTML can use the path as a document base.
                routes.canonical_path(path)
                destination = site.joinpath(path.lstrip("/")).resolve()
                if not destination.is_relative_to(site):
                    raise ValueError("path leaves site")
            except (ValueError, UnicodeError, OSError, RuntimeError):
                self.send_error(400, "Use a path within the local site.")
                return None
            return path

        def _send(self, status, data, content_type, head=False, *, fresh=False):
            if content_type.startswith("text/html"):
                request_path = unquote(urlsplit(self.path).path, errors="strict")
                content = routes.html(data.decode("utf-8"), routes.legacy_path(request_path) or request_path)
                if repository is not None:
                    content = repository_stars.render_header(content, repository_stars.unknown_snapshot())
                    fresh = True
                data = content.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            if fresh:
                self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if not head:
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            return data

        def _github_snapshot(self):
            try:
                return repository.snapshot()
            except (OSError, ValueError, TypeError):
                return repository_stars.unknown_snapshot()

        def _serve(self, head=False):
            path = self._path()
            if path is None:
                return
            if delivery is not None and delivery.handle(self, path, head=head):
                return
            # Keep the generators' directory routes while accepting every
            # known public alias. Raw APIs, sources, and downloads are unmapped.
            path = routes.legacy_path(path) or path
            if path == "/registry/v1/github.json" and repository is not None:
                self._send(200, registry.json_bytes(self._github_snapshot()), "application/json; charset=utf-8", head, fresh=True)
                return
            explore_routes = {"/explore/": "explore", "/browse/categories/": "categories",
                              "/browse/architectures/": "architectures",
                              "/browse/keywords/": "keywords", "/browse/depended-on/": "depended-on",
                              "/browse/downloaded/": "downloaded"}
            explore_kind = explore_routes.get(path)
            keyword = re.fullmatch(r"/browse/keywords/([a-z][a-z0-9-]{0,39})/", path)
            if keyword:
                explore_kind = "keywords/" + keyword[1]
            architecture = re.fullmatch(r"/browse/architectures/([a-z][a-z0-9_]{0,15})/", path)
            if architecture:
                explore_kind = "architectures/" + architecture[1]
            if explore_kind == "architectures" or (explore_kind and explore_kind.startswith("architectures/")):
                try:
                    data = registry_explore.explore_page(site, index, None, None, None, explore_kind).encode("utf-8")
                    self._send(200, data, "text/html; charset=utf-8", head, fresh=True)
                except KeyError:
                    self.send_error(404)
                except (registry.RegistryError, OSError, UnicodeError, ValueError, TypeError):
                    self._send(503, b"Architecture data is unavailable. Retry later.\n", "text/plain; charset=utf-8", head, fresh=True)
                return
            if explore_kind or path in {"/stats/", "/registry/v1/stats.json"}:
                try:
                    snapshot, observation = service.hub_snapshot()
                    if path == "/registry/v1/stats.json":
                        data = registry.json_bytes(registry_stats.stats_snapshot(index, observation, service.records))
                        content_type = "application/json; charset=utf-8"
                    elif path == "/stats/":
                        data = registry_stats.stats_page(site, index, snapshot, observation, service.records).encode("utf-8")
                        content_type = "text/html; charset=utf-8"
                    else:
                        metadata = discovery_metadata.read_metadata(site, index, "registry/v1/discovery-metadata.json")
                        retained = discovery.retained_counts(service.records, observation)
                        data = registry_explore.explore_page(site, index, snapshot, metadata, retained, explore_kind).encode("utf-8")
                        content_type = "text/html; charset=utf-8"
                    self._send(200, data, content_type, head, fresh=True)
                except KeyError:
                    self.send_error(404)
                except (registry.RegistryError, OSError, UnicodeError, ValueError, TypeError):
                    self._send(503, b"Registry statistics are unavailable. Retry later.\n", "text/plain; charset=utf-8", head, fresh=True)
                return
            if path.startswith(("/browse/keywords/", "/browse/architectures/")):
                self.send_error(404)
                return
            category = re.fullmatch(r"/browse/categories/([a-z][a-z0-9-]{0,39})/", path)
            kind = path.split("/")[2] if path in {"/browse/popular/", "/browse/new/", "/browse/updated/"} else None
            if path == "/discovery/":
                kind = "metrics"
            if category:
                kind = "categories/" + category[1]
            if path == "/registry/v1/downloads.json":
                self._send(200, registry.json_bytes(service.counts_snapshot()), "application/json; charset=utf-8", head, fresh=True)
                return
            activity_route = re.fullmatch(r"/registry/v1/activity/([a-z0-9-]+/[a-z0-9-]+)(?:/([0-9.]+))?\.json", path)
            if activity_route:
                name, version = activity_route.groups()
                if not any(record["name"] == name and (version is None or record["version"] == version) for record in service.records):
                    self.send_error(404)
                    return
                try:
                    self._send(200, registry.json_bytes(service.activity_snapshot(name, version)), "application/json; charset=utf-8", head, fresh=True)
                except (registry.RegistryError, OSError, ValueError, TypeError):
                    self._send(503, b"Download history is unavailable. Retry later.\n", "text/plain; charset=utf-8", head, fresh=True)
                return
            if path in {"/api/discovery", "/registry/v1/discovery.json"} or kind:
                try:
                    if kind:
                        body = package_pages.discovery_page(site, index, service.snapshot(), kind).encode("utf-8")
                        self._send(200, body, "text/html; charset=utf-8", head, fresh=True)
                    else:
                        snapshot = package_pages.with_discovery_categories(site, index, service.snapshot())
                        self._send(200, registry.json_bytes(snapshot), "application/json; charset=utf-8", head, fresh=True)
                except KeyError:
                    self.send_error(404)
                except (registry.RegistryError, OSError, UnicodeError, ValueError, TypeError):
                    self._send(503, b"Discovery data is unavailable. Retry later.\n", "text/plain; charset=utf-8", head, fresh=True)
            elif path.startswith("/browse/categories/"):
                self.send_error(404)
            elif head:
                super().do_HEAD()
            else:
                super().do_GET()

        def do_GET(self):
            self._serve()

        def do_HEAD(self):
            self._serve(head=True)

        def send_head(self):
            destination = Path(self.translate_path(self.path))
            request_path = unquote(urlsplit(self.path).path, errors="strict")
            page = routes.file_for(request_path)
            candidate = site / page if page is not None else destination
            if page is None and destination.is_dir():
                candidate = destination / "index.html"
            readable_page = page is not None or not destination.is_dir() or request_path.endswith("/")
            if (request_path.startswith("/packages/") and candidate.suffix == ".html" and candidate.exists()
                    and readable_page):
                try:
                    relative = candidate.relative_to(site).as_posix()
                    content = registry.read_regular(site, relative, build_site.MAX_HTML_BYTES).decode("utf-8")
                    pattern = r'<p class="package-note" data-downloads-name="([a-z0-9_/-]+)" data-downloads-version="([0-9.]*)">.*?</p>'
                    counts, observation = service.page_snapshot()
                    def update_count(match):
                        return match.group(0).split(">", 1)[0] + ">" + package_pages.counts_html(counts, match[1], match[2] or None) + "</p>"
                    updated, replacements = re.subn(pattern, update_count, content, flags=re.S)
                    def update_activity(match):
                        name, version = match[1], match[2] or None
                        prefix = "../" * relative.count("/")
                        # Relative assets use the page directory, not index.html.
                        route = prefix + "registry/v1/activity/" + name + ("/" + version if version else "") + ".json"
                        activity = discovery.delivery_activity(service.records, name, observation, version=version)
                        rendered = package_activity.render_activity(activity, prefix + "discovery/", route)
                        return '<!-- package-activity:start ' + name + ' ' + (version or '') + ' -->' + rendered + '<!-- package-activity:end -->'
                    updated, graphs = re.subn(r'<!-- package-activity:start ([a-z0-9-]+/[a-z0-9-]+) ([0-9.]*) -->.*?<!-- package-activity:end -->', update_activity, updated, flags=re.S)
                    if replacements or graphs:
                        data = updated.encode("utf-8")
                        data = self._send(200, data, "text/html; charset=utf-8", True, fresh=True)
                        return BytesIO(data)
                except (OSError, registry.RegistryError, UnicodeError, ValueError):
                    pass
            if destination.is_dir():
                for name in ("index.html", "index.htm"):
                    linked_index = destination / name
                    if linked_index.exists() and not linked_index.resolve().is_relative_to(site):
                        self.send_error(403, "Use a path within the local site.")
                        return None
            if ((page is not None or repository is not None) and candidate.suffix == ".html"
                    and candidate.is_file() and readable_page):
                try:
                    content = registry.read_regular(site, candidate.relative_to(site).as_posix(), build_site.MAX_HTML_BYTES)
                    data = self._send(200, content, "text/html; charset=utf-8", True)
                    return BytesIO(data)
                except (OSError, registry.RegistryError, UnicodeError, ValueError):
                    self.send_error(503, "The page is unavailable. Retry later.")
                    return None
            return super().send_head()

        def list_directory(self, path):
            self.send_error(404)
            return None

        def send_error(self, code, message=None, explain=None):
            if code == 404:
                try:
                    content = registry.read_regular(site, "404.html", 128 * 1024)
                except (OSError, registry.RegistryError):
                    pass
                else:
                    self._send(404, content, "text/html; charset=utf-8", self.command == "HEAD")
                    return
            super().send_error(code, message, explain)

    return Handler


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site", type=Path, required=True, help="built public site directory")
    parser.add_argument("--registry", type=Path, default=Path("registry"))
    parser.add_argument("--state", type=Path, required=True, help="private persistent observation database")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--refresh-seconds", type=float, default=5)
    parser.add_argument("--artifact-cache", type=Path, default=Path("build/artifact-cache"),
                        help="private content-addressed checked artifacts")
    parser.add_argument("--publication-state", type=Path,
                        help="optional historical publication metadata adapter state")
    parser.add_argument("--repository-state", type=Path, default=Path("build/repository-state/github.json"),
                        help="private cached GitHub star observation")
    args = parser.parse_args(argv)
    service = repository = None
    try:
        registry.require(0 <= args.port <= 65535, "port must be between 0 and 65535")
        records = registry.read_records(args.registry)
        index = registry.strict_json(registry.read_regular(args.site, "registry/v1/index.json", 16 * 1024 * 1024))
        registry.require(isinstance(index, dict), "website index must be an object")
        for private_path in (args.state, args.artifact_cache, args.publication_state, args.repository_state):
            registry.require(private_path is None or not private_path.resolve().is_relative_to(args.site.resolve()),
                             "keep private delivery data outside the public site")
        publication = registry.strict_json(registry.read_regular(args.site, "registry/v1/discovery.json", 4 * 1024 * 1024))
        service = DiscoveryService(records, args.state, refresh_seconds=args.refresh_seconds,
                                   publication_state=args.publication_state, publication=publication)
        service.start()
        repository = repository_stars.RepositoryStats(args.repository_state, build_site.repository_json)
        repository.start()
        import artifact_delivery
        delivery = artifact_delivery.ArtifactDelivery(records, args.artifact_cache, service.store, lambda: service.session_id)
        handler = build_handler(args.site, index, service, delivery, repository)
        with LoopbackHTTPServer(("127.0.0.1", args.port), handler) as server:
            print(f"Local site: http://127.0.0.1:{server.server_port}/", flush=True)
            try:
                server.serve_forever(poll_interval=0.25)
            except KeyboardInterrupt:
                pass
        return 0
    except (OSError, registry.RegistryError, ValueError) as error:
        print(f"serve-site: {error}", file=sys.stderr)
        return 1
    finally:
        if repository is not None:
            repository.stop()
        if service is not None:
            service.stop()


if __name__ == "__main__":
    raise SystemExit(main())
