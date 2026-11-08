"""Export clean page URLs while retaining native legacy paths and raw assets.

Only known HTML pages receive new public names. Input generators retain their
directory-relative contract; this adapter changes links in the staged output.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from html import escape, unescape
from html.parser import HTMLParser
from pathlib import Path
import re
import stat
from urllib.parse import unquote, urljoin, urlsplit, urlunsplit
from xml.etree import ElementTree

import registry

SITE = "https://asm.build"
MAX_HTML_BYTES = 4 * 1024 * 1024
MAX_PAGES = 32768
URL_ATTRIBUTES = {"href", "src", "action", "data-activity-url"}
# Page spelling is independent of the registry's literal architecture ID.
PUBLIC_NAMES = {"/browse/architectures/x86_64": "/browse/architectures/x86-64"}
ATTRIBUTE = re.compile(r'''(?P<name>[^\s"'<>/=]+)(?:(?P<equals>\s*=\s*)(?:(?P<quote>["'])(?P<quoted>.*?)(?P=quote)|(?P<bare>[^\s"'=<>`]+)))?''', re.S)


def _path(value: str) -> str:
    registry.require(isinstance(value, str) and 0 < len(value) <= 8192, "invalid public page path")
    parsed = urlsplit(value)
    decoded = unquote(parsed.path, errors="strict")
    registry.require(not parsed.scheme and not parsed.netloc and not parsed.query and not parsed.fragment
                     and value.startswith("/") and "\\" not in decoded
                     and all(ord(char) >= 32 and ord(char) != 127 for char in decoded)
                     and not any(part in {".", ".."} for part in decoded.split("/")),
                     "public page path must stay within the site")
    return value


class _HTML(HTMLParser):
    """Edit URL attribute values without reserializing unrelated HTML."""
    def __init__(self, routes, content, base):
        super().__init__(convert_charrefs=False)
        self.routes, self.content, self.base = routes, content, base
        self.offsets, self.edits, self.opaque = [0], [], []
        self.offsets.extend(match.end() for match in re.finditer("\n", content))

    def handle_starttag(self, tag, attrs):
        protected = {"script", "style", "textarea", "pre", "code", "title"}
        if not self.opaque:
            values = dict(attrs)
            canonical = tag == "link" and "canonical" in (values.get("rel") or "").split()
            metadata = tag == "meta" and (values.get("property") or values.get("name")) in {"og:url", "twitter:url"}
            names = [name for name, _ in attrs if name in URL_ATTRIBUTES or metadata and name == "content"]
            registry.require(len(names) == len(set(names)), "ambiguous HTML URL attributes")
            raw = self.get_starttag_text()
            def replace(match):
                name = match["name"].lower()
                if not match["equals"] or name not in URL_ATTRIBUTES and not (metadata and name == "content"):
                    return match[0]
                original = unescape(match["quoted"] if match["quote"] else match["bare"])
                updated = self.routes._url(original, self.base, absolute=(canonical and name == "href") or metadata)
                if updated == original:
                    return match[0]
                quote = match["quote"] or '"'
                return match["name"] + match["equals"] + quote + escape(updated, quote=True) + quote
            updated = ATTRIBUTE.sub(replace, raw)
            if updated != raw:
                line, column = self.getpos()
                offset = self.offsets[line - 1] + column
                self.edits.append((offset, offset + len(raw), updated))
        if tag in protected:
            self.opaque.append(tag)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if tag in self.opaque:
            del self.opaque[self.opaque.index(tag):]

    def result(self):
        self.feed(self.content)
        self.close()
        result, previous = [], 0
        for start, end, value in self.edits:
            result.extend((self.content[previous:start], value))
            previous = end
        result.append(self.content[previous:])
        return "".join(result)


class PageRoutes:
    @classmethod
    def from_directory(cls, stage: Path):
        root = Path(stage)
        registry.require(root.is_dir() and not root.is_symlink(), "page directory must be regular")
        result = cls()
        result.root, result.aliases, result.pages = root.resolve(), {}, {}
        for file in sorted(root.rglob("*.html")):
            registry.require(not file.is_symlink(), "HTML pages cannot be symlinks")
            if file.is_dir(): continue
            relative = file.relative_to(root)
            registry.portable_path(relative.as_posix())
            data = registry.read_regular(root, relative.as_posix(), MAX_HTML_BYTES)
            try: data.decode("utf-8")
            except UnicodeError as error: raise registry.RegistryError("HTML pages must use UTF-8") from error
            raw = "/" + relative.as_posix()
            legacy = raw[:-10] if raw.endswith("index.html") and (raw == "/index.html" or raw.endswith("/index.html")) else raw
            canonical = legacy.rstrip("/") if legacy.endswith("/") else legacy[:-5]
            canonical = canonical or "/"
            original = canonical
            canonical = PUBLIC_NAMES.get(original, original)
            existing = result.pages.get(canonical)
            registry.require(existing is None or existing["data"] == data, "different pages claim the same canonical route")
            if existing is None:
                result.pages[canonical] = {"data": data, "files": [], "legacy": legacy, "file": relative, "original_names": set()}
            page = result.pages[canonical]
            page["original_names"].add(original)
            page["files"].append(relative)
            if relative.name == "index.html":
                page.update(legacy=legacy, file=relative)
            aliases = {canonical, original, raw, legacy}
            if original != "/": aliases.update({original + "/", original + "/index.html", original + ".html"})
            if canonical != "/": aliases.update({canonical + "/", canonical + "/index.html", canonical + ".html"})
            else: aliases.add("/index.html")
            for alias in aliases:
                registry.require(alias not in result.aliases or result.aliases[alias] == canonical,
                                 "ambiguous HTML page alias")
                result.aliases[alias] = canonical
            registry.require(len(result.pages) <= MAX_PAGES, "too many HTML pages")
        return result

    def canonical_path(self, path: str) -> str:
        return self.aliases.get(_path(path), path)

    def legacy_path(self, path: str) -> str | None:
        page = self.pages.get(self.canonical_path(path))
        return page["legacy"] if page else None

    def file_for(self, path: str) -> Path | None:
        page = self.pages.get(self.canonical_path(path))
        return page["file"] if page else None

    def _url(self, value: str, base: str, *, absolute=False) -> str:
        if value.startswith("#"): return value
        parsed = urlsplit(value)
        if parsed.scheme or parsed.netloc:
            if parsed.scheme not in {"", "https"} or parsed.netloc != "asm.build": return value
        resolved = urlsplit(urljoin(SITE + base, value))
        path = self.canonical_path(resolved.path or "/")
        return urlunsplit(("https" if absolute else "", "asm.build" if absolute else "", path, resolved.query, resolved.fragment))

    def html(self, content: str, old_public_path: str) -> str:
        registry.require(isinstance(content, str) and len(content.encode("utf-8")) <= MAX_HTML_BYTES,
                         "HTML exceeds four MiB")
        return _HTML(self, content, _path(old_public_path)).result()

    def _xml(self, content: bytes, kind: str) -> bytes:
        try:
            parser = ElementTree.XMLParser(target=ElementTree.TreeBuilder(insert_comments=True))
            root = ElementTree.fromstring(content, parser=parser)
        except ElementTree.ParseError as error:
            raise registry.RegistryError("invalid page URL metadata") from error
        namespace = "http://www.sitemaps.org/schemas/sitemap/0.9" if kind == "sitemap" else "http://www.w3.org/2005/Atom"
        tag = lambda name: "{" + namespace + "}" + name
        registry.require(root.tag == tag("urlset" if kind == "sitemap" else "feed"), "unsupported page URL metadata")
        if kind == "sitemap":
            seen = set()
            for entry in list(root):
                if entry.tag != tag("url"): continue
                location = entry.find(tag("loc"))
                registry.require(location is not None and isinstance(location.text, str), "sitemap URL lacks a location")
                location.text = self._url(location.text, "/sitemap.xml", absolute=True)
                if location.text in seen: root.remove(entry)
                else: seen.add(location.text)
        else:
            # Atom IDs, timestamps, and escaped article content are permanent
            # data, not navigation links. Only clickable link hrefs change.
            for link in root.iter(tag("link")):
                if "href" in link.attrib:
                    link.set("href", self._url(link.get("href"), "/blog/atom.xml", absolute=True))
        ElementTree.register_namespace("", namespace)
        return ElementTree.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"

    def export(self, stage: Path) -> None:
        """Preflight all content/collisions, then write into the private stage.

        The caller atomically publishes this stage. This method does not claim
        an atomic multi-file update or protection against same-user races.
        """
        registry.require(Path(stage).resolve() == self.root and not Path(stage).is_symlink(), "page export root changed")
        planned = {}
        for canonical, page in self.pages.items():
            rewritten = self.html(page["data"].decode("utf-8"), page["legacy"]).encode("utf-8")
            registry.require(len(rewritten) <= MAX_HTML_BYTES, "rewritten HTML exceeds four MiB")
            for relative in page["files"]:
                registry.require(registry.read_regular(self.root, relative.as_posix(), MAX_HTML_BYTES) == page["data"],
                                 "HTML page changed before export")
                planned[relative] = rewritten
            if canonical != "/": planned[Path(canonical.lstrip("/") + ".html")] = rewritten
            for original in page["original_names"] - {canonical, "/"}:
                planned[Path(original.lstrip("/") + ".html")] = rewritten
        for relative, kind in ((Path("sitemap.xml"), "sitemap"), (Path("blog/atom.xml"), "atom")):
            path = self.root / relative
            if path.exists() or path.is_symlink():
                planned[relative] = self._xml(registry.read_regular(self.root, relative.as_posix(), MAX_HTML_BYTES), kind)
        for relative in planned:
            registry.portable_path(relative.as_posix())
            current = self.root
            for part in relative.parts:
                current /= part
                if current.exists() or current.is_symlink():
                    info = current.lstat()
                    registry.require(not stat.S_ISLNK(info.st_mode), "page export cannot follow symlinks")
                    registry.require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 if current == self.root / relative else stat.S_ISDIR(info.st_mode),
                                     "page export path is not regular")
        for relative, data in planned.items():
            registry.write_atomic(self.root / relative, data)
