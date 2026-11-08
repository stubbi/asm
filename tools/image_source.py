"""Read the immutable runtime image's source identity.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import os
from pathlib import Path
import re
import stat

import registry

SOURCE = Path("/app/SOURCE.json")


def source_revision():
    descriptor = os.open(SOURCE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        registry.require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == 0
            and not info.st_mode & 0o022 and 1 <= info.st_size <= 16384, "Invalid image source marker.")
        body = os.read(descriptor, 16385)
        registry.require(len(body) == info.st_size, "Image source marker size differs.")
        marker = registry.strict_json(body)
        registry.require(isinstance(marker, dict), "Invalid image source marker shape.")
        value = marker.get("source_revision")
        registry.require(type(marker.get("schema")) is int and marker.get("schema") == 1
            and marker.get("repository") == "https://github.com/stubbi/asm"
            and isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) and value != "0" * 40,
            "Invalid image source identity.")
        return value
    finally:
        os.close(descriptor)
