"""Load repository-authored articles without publishing or executing content.

Relative Markdown links refer to the maintained GitHub main/blog/posts source,
not an immutable release snapshot. Metadata remains plain text for the caller
to escape; only each record's html value contains safe rendered markup.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

from datetime import date, datetime, timezone
import os
from pathlib import Path
import re
import tomllib
import unicodedata

import package_pages
import registry

MAX_POSTS = 128
MAX_BYTES = 128 * 1024
MAX_BODY_LINES = 4096
SLUG = re.compile(r"[a-z][a-z0-9-]{0,63}\Z")
FIELDS = {"title", "summary", "author", "draft", "date", "updated"}
SOURCE = {"repository": "https://github.com/stubbi/asm", "commit": "main", "path": "blog/posts"}


def _names(repo: Path) -> list[str]:
    """Inspect only the bounded flat source directory; do not follow links."""
    descriptors = []
    try:
        descriptor = os.open(repo, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(descriptor)
        for part in ("blog", "posts"):
            try:
                descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            except FileNotFoundError:
                return []
            descriptors.append(descriptor)
        names = []
        with os.scandir(descriptor) as entries:
            for entry in entries:
                registry.require(len(names) < MAX_POSTS, "too many repository blog posts")
                name = entry.name
                slug = name[:-3] if name.endswith(".md") else ""
                registry.require(SLUG.fullmatch(slug) is not None and not slug.endswith("-") and "--" not in slug,
                                 "invalid repository blog post filename")
                registry.require(entry.is_file(follow_symlinks=False), "blog posts must be regular files without links")
                names.append(name)
        return sorted(names)
    except OSError as error:
        raise registry.RegistryError("cannot safely read repository blog posts") from error
    finally:
        for descriptor in reversed(descriptors): os.close(descriptor)


def _text(value, maximum: int, field: str) -> str:
    registry.require(isinstance(value, str) and 0 < len(value) <= maximum and value == value.strip()
                     and all(char.isprintable() for char in value), "invalid blog " + field)
    return value


def _date(value, field: str) -> date:
    # datetime is a date subclass; TOML timestamps must not acquire date meaning.
    registry.require(type(value) is date, "blog " + field + " must be a TOML calendar date")
    return value


def _body_heading(lines: list[str]) -> None:
    fence, width, previous_text = None, 0, False
    for line in lines:
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if marker:
            if fence is None:
                fence, width = marker[1][0], len(marker[1])
            elif marker[1][0] == fence and len(marker[1]) >= width and not marker[2].strip():
                fence = None
            previous_text = False
            continue
        if fence is not None: continue
        registry.require(re.match(r"^ {0,3}#(?:\s|$)", line) is None
                         and not (previous_text and re.fullmatch(r" {0,3}=+\s*", line)),
                         "blog body must not contain a top-level heading")
        previous_text = bool(line.strip())


def _post(repo: Path, name: str, today: date) -> dict:
    try:
        text = registry.read_regular(repo, "blog/posts/" + name, MAX_BYTES).decode("utf-8")
    except UnicodeError as error:
        raise registry.RegistryError("blog posts must contain valid UTF-8") from error
    registry.require(all(char in "\t\r\n" or unicodedata.category(char) not in {"Cc", "Cf", "Cs", "Cn"} for char in text),
                     "blog post contains unsupported control characters")
    lines = text.splitlines(keepends=True)
    registry.require(lines and lines[0].rstrip("\r\n") == "+++", "blog post needs TOML front matter")
    end = next((index for index in range(1, len(lines)) if lines[index].rstrip("\r\n") == "+++"), None)
    registry.require(end is not None, "blog front matter has no closing delimiter")
    try:
        metadata = tomllib.loads("".join(lines[1:end]))
    except (ValueError, RecursionError) as error:
        raise registry.RegistryError("invalid blog TOML front matter") from error
    registry.require(set(metadata) <= FIELDS, "unknown blog metadata field")
    title = _text(metadata.get("title"), 120, "title")
    summary = _text(metadata.get("summary"), 240, "summary")
    author = _text(metadata.get("author"), 80, "author")
    draft = metadata.get("draft")
    registry.require(type(draft) is bool, "blog draft must be an explicit boolean")
    published = _date(metadata["date"], "date") if "date" in metadata else None
    updated = _date(metadata["updated"], "updated") if "updated" in metadata else None
    registry.require(draft or published is not None and published <= today, "published blog post needs a date no later than today")
    registry.require(updated is None or (published is None or updated >= published) and (draft or updated <= today),
                     "blog update date precedes publication or is in the future")
    body_lines = lines[end + 1:]
    registry.require(len(body_lines) <= MAX_BODY_LINES and "".join(body_lines).strip(), "blog body is empty or exceeds its line bound")
    _body_heading([line.rstrip("\r\n") for line in body_lines])
    iso = lambda value: value.isoformat() + "T00:00:00Z" if value is not None else None
    return {"kind": "article", "title": title, "summary": summary, "author": author,
            "date": iso(published), "updated": iso(updated), "route": "blog/articles/" + name[:-3] + "/",
            "html": package_pages._markdown("".join(body_lines), SOURCE, name, heading_offset=0),
            "source": SOURCE["repository"] + "/blob/main/blog/posts/" + name, "draft": draft}


def load_posts(repo: Path, *, include_drafts=False, now=None) -> list[dict]:
    """Validate all authored posts; return public records unless preview is explicit.

    Missing blog/posts means no authored articles. Invalid sources raise
    RegistryError before a result is returned. This function writes no files.
    """
    registry.require(type(include_drafts) is bool, "blog draft selection must be boolean")
    if now is None: now = datetime.now(timezone.utc)
    registry.require(isinstance(now, datetime) and now.utcoffset() is not None, "blog current time must have a timezone")
    today = now.astimezone(timezone.utc).date()
    posts = []
    for name in _names(repo):
        try:
            posts.append(_post(repo, name, today))
        except (registry.RegistryError, OSError) as error:
            raise registry.RegistryError("blog/posts/" + name + ": " + str(error) +
                                         ". Check this post against blog/README.md.") from error
    posts = [post for post in posts if include_drafts or not post["draft"]]
    # The first stable sort preserves ascending slug order for equal dates.
    posts.sort(key=lambda post: post["route"])
    posts.sort(key=lambda post: post["date"] or "", reverse=True)
    return posts
