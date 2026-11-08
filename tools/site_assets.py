"""Prepare first-party browser assets in an unpublished static-site stage.

The document policy is delivered through HTML, not an HTTP response header.
It does not establish HSTS or protect against framing through frame-ancestors.
Those controls require configuration at the serving origin.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from functools import lru_cache
import hashlib
from html import escape
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import shutil

import registry
from registry_admin import AdminError, run_bounded

MAX_SCRIPT_BYTES = 1024 * 1024
MAX_BATCH_BYTES = 4 * MAX_SCRIPT_BYTES
BUNDLE_SHA256 = "379f8758191b03c07745486e785cbf4bed6a7ae368aa40a5a819556743f3ad1c"
CONTENT_POLICY = ("default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
                  "img-src 'self'; font-src 'self'; connect-src 'self' https://api.github.com; "
                  "base-uri 'none'; form-action 'self'; object-src 'none'")


class _PolicyHead(HTMLParser):
    def __init__(self):
        super().__init__()
        self.heads = 0
        self.in_head = False
        self.charsets = []
        self.resources = []

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "head":
            self.heads += 1
            self.in_head = True
        if tag == "meta":
            self.charsets.extend((self.getpos(), self.get_starttag_text(), value, self.in_head)
                                 for name, value in attributes if name == "charset")
            registry.require((attrs.get("http-equiv") or "").lower() != "content-security-policy",
                             "site page already declares a document policy")
        if tag in {"script", "link", "style", "base", "img", "iframe", "video", "audio", "source", "object", "embed"}:
            self.resources.append(self.getpos())
        registry.require(not any(name.startswith("on") for name, _ in attributes),
                         "site policy prohibits inline event handlers")
        if tag == "script" and not attrs.get("src"):
            registry.require((attrs.get("type") or "").strip().lower() in {"application/json", "application/ld+json"},
                             "site policy prohibits inline executable scripts")

    def handle_endtag(self, tag):
        if tag == "head":
            self.in_head = False


def with_content_policy(content: str) -> str:
    """Insert the reviewed document policy after one UTF-8 declaration."""
    head = _PolicyHead()
    head.feed(content)
    head.close()
    registry.require(head.heads == 1 and len(head.charsets) == 1,
                     "site page needs one head and one charset declaration")
    position, token, charset, in_head = head.charsets[0]
    registry.require(in_head and isinstance(charset, str) and charset.strip().lower() == "utf-8",
                     "site charset must declare UTF-8 in the head")
    registry.require(all(position < resource for resource in head.resources),
                     "site charset must precede resource elements")
    line, column = position
    offset = sum(len(row) + 1 for row in content.split("\n")[:line - 1]) + column + len(token)
    policy = '\n<meta http-equiv="Content-Security-Policy" content="' + escape(CONTENT_POLICY, quote=True) + '">'
    return content[:offset] + policy + content[offset:]


@lru_cache(maxsize=4)
def _minify(sources: tuple[tuple[str, bytes], ...], node: str) -> tuple[tuple[str, bytes], ...]:
    tools = Path(__file__).resolve().parent
    bundle = registry.read_regular(tools, "vendor/terser/bundle.min.js", 2 * MAX_SCRIPT_BYTES)
    registry.require(hashlib.sha256(bundle).hexdigest() == BUNDLE_SHA256, "reviewed JavaScript minifier bytes differ")
    packet = json.dumps({name: source.decode("utf-8") for name, source in sources}, ensure_ascii=False).encode("utf-8")
    registry.require(len(packet) <= 2 * MAX_BATCH_BYTES, "browser source input exceeds its byte limit")
    try:
        raw = run_bounded([node, "--no-addons", "--max-old-space-size=256", str(tools / "minify_site.cjs")],
                          data=packet, environment={"PATH": os.defpath, "LANG": "C.UTF-8"},
                          output_limit=2 * MAX_BATCH_BYTES, timeout=20)
    except (AdminError, OSError) as error:
        raise registry.RegistryError("JavaScript minification failed. Check Node.js 18 or later and browser source syntax.") from error
    result = registry.strict_json(raw)
    registry.require(isinstance(result, dict), "invalid JavaScript minifier response")
    if isinstance(result.get("error"), str):
        raise registry.RegistryError("JavaScript minification failed: " + result["error"][:1024])
    registry.require(set(result) == {name for name, _ in sources}, "JavaScript minifier files differ")
    output = []
    for name, source in sources:
        registry.require(isinstance(result[name], str), "invalid minified JavaScript")
        text, notice = source.decode("utf-8"), ""
        if text.startswith("/*") and not text.startswith("/*!"):
            end = text.find("*/")
            registry.require(end >= 0, "browser script has an unterminated source notice")
            notice = text[:end + 2] + "\n"
        output.append((name, (notice + result[name] + "\n").encode("utf-8")))
    return tuple(output)


def minify_scripts(stage: Path) -> None:
    """Transform only staged JavaScript; a failure leaves publication to the caller."""
    sources = tuple((path.name, registry.read_regular(stage, path.name, MAX_SCRIPT_BYTES))
                    for path in sorted(stage.glob("*.js")))
    if not sources:
        return
    registry.require(len(sources) <= 16 and sum(len(source) for _, source in sources) <= MAX_BATCH_BYTES,
                     "browser source collection exceeds its bounds")
    node = shutil.which("node")
    registry.require(node is not None, "Install Node.js 18 or later to build the website.")
    for name, content in _minify(sources, str(Path(node).resolve())):
        registry.write_atomic(stage / name, content)
