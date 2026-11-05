"""Build/test codecs for the Windows CLI layout. No installed runtime logic.

The installed launcher and updater must implement this contract in assembly.
These helpers never load or execute an artifact, or change an installation.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import re
import struct

if __package__:
    from .registry import MAX_ARTIFACT_BYTES, WINDOWS_TARGETS, validate_pe, version_tuple
else:
    from registry import MAX_ARTIFACT_BYTES, WINDOWS_TARGETS, validate_pe, version_tuple


LAYOUT_MARKER = b'# asm-cli-layout-v1\n'
RECORD_HEADER = b'# asm-cli-current-v1\n'
MAX_RECORD_BYTES = 256
METADATA_SIZE = 64
METADATA_MAGIC = b'ASMCLI1\0'
PROTOCOL = 1


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _target(target: str) -> None:
    _require(isinstance(target, str) and target in WINDOWS_TARGETS,
             'unsupported Windows CLI target')


def encode_record(version: str, target: str, size: int, sha256: str,
                  minimum_launcher: str = '0.6.0') -> bytes:
    """Return one canonical selection record; size is in 1..64 MiB.

    Versions have three components, each in 0..2147483647. Digests use
    exactly 64 lowercase hexadecimal characters. No field supplies a path.
    """
    version_tuple(version)
    version_tuple(minimum_launcher)
    _target(target)
    _require(type(size) is int and 1 <= size <= MAX_ARTIFACT_BYTES,
             'invalid Windows CLI artifact size')
    _require(isinstance(sha256, str) and re.fullmatch(r'[0-9a-f]{64}', sha256) is not None,
             'invalid Windows CLI artifact digest')
    data = RECORD_HEADER + f'{version}\t{target}\t{size}\t{sha256}\t1\t{minimum_launcher}\n'.encode('ascii')
    _require(len(data) <= MAX_RECORD_BYTES, 'Windows CLI selection record is too large')
    return data


def decode_record(data: bytes, target: str) -> dict:
    """Read exact canonical bytes for this target, or raise ValueError.

    Return version, target, size, sha256, protocol, and minimum_launcher.
    Versions remain strings; size and protocol are integers.
    """
    _target(target)
    _require(isinstance(data, bytes) and len(data) <= MAX_RECORD_BYTES,
             'invalid Windows CLI selection record size')
    _require(data.startswith(RECORD_HEADER) and data.endswith(b'\n'),
             'invalid Windows CLI selection record header or ending')
    fields = data[len(RECORD_HEADER):-1].decode('ascii').split('\t')
    _require(len(fields) == 6, 'Windows CLI selection record needs six fields')
    version, selected_target, size_text, digest, protocol, minimum = fields
    _require(re.fullmatch(r'[1-9][0-9]{0,7}', size_text) is not None,
             'invalid Windows CLI selection record size')
    _require(selected_target == target, 'Windows CLI selection target mismatch')
    _require(protocol == '1', 'unsupported Windows CLI launcher protocol')
    size = int(size_text)
    _require(encode_record(version, selected_target, size, digest, minimum) == data,
             'noncanonical Windows CLI selection record')
    return {'version': version, 'target': target, 'size': size, 'sha256': digest,
            'protocol': PROTOCOL, 'minimum_launcher': minimum}


def metadata_bytes(version: str, minimum_launcher: str = '0.6.0') -> bytes:
    """Encode schema 1 metadata using the actual built-source version.

    The schema and three protocol fields are 1. The final 16 bytes are zero.
    All numeric fields use little-endian uint32 encoding.
    """
    artifact = version_tuple(version)
    minimum = version_tuple(minimum_launcher)
    return struct.pack('<8s10I16x', METADATA_MAGIC, 1, PROTOCOL, PROTOCOL, PROTOCOL,
                       *artifact, *minimum)


def read_pe_metadata(data: bytes, target: str, *, expected_version: str | None = None) -> dict:
    """Read a bounded PE32+ CLI's unique, read-only .asmmeta section.

    Return schema, protocol, minimum_protocol, maximum_protocol, version,
    and minimum_launcher. Bind to a release version with expected_version.
    The shared PE validator checks target, headers, alignment, section and
    directory bounds, and section overlap before metadata is inspected.
    This is a CLI-specific profile, not a general Windows loader or proof
    of provenance, instruction validity, or native runtime support.

    Microsoft PE/COFF reference, checked 2026-11-05:
    https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
    """
    _target(target)
    _require(isinstance(data, bytes), 'Windows CLI artifact must be bytes')
    if expected_version is not None:
        version_tuple(expected_version)
    validate_pe(data, target)
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    count = struct.unpack_from('<H', data, pe + 6)[0]
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    table = pe + 24 + optional_size
    sections = [table + index * 40 for index in range(count)
                if data[table + index * 40:table + index * 40 + 8] == b'.asmmeta']
    _require(len(sections) == 1, 'Windows CLI needs one .asmmeta section')
    section = sections[0]
    virtual_size, _, raw_size, raw = struct.unpack_from('<IIII', data, section + 8)
    flags = struct.unpack_from('<I', data, section + 36)[0]
    _require(virtual_size == METADATA_SIZE and raw_size >= METADATA_SIZE,
             'invalid Windows CLI metadata section size')
    # Initialized data and read access are required. Code, uninitialized
    # data, execute access, and write access are forbidden.
    _require(flags & 0x40000040 == 0x40000040 and flags & 0xa00000a0 == 0,
             'Windows CLI metadata section must contain read-only initialized data')
    metadata = data[raw:raw + METADATA_SIZE]
    magic, schema, protocol, minimum_protocol, maximum_protocol, *versions = struct.unpack(
        '<8s10I16x', metadata)
    _require(magic == METADATA_MAGIC and schema == 1, 'invalid Windows CLI metadata schema')
    _require((protocol, minimum_protocol, maximum_protocol) == (1, 1, 1),
             'unsupported Windows CLI launcher protocol')
    _require(metadata[48:] == bytes(16), 'Windows CLI metadata reserved bytes must be zero')
    version = '.'.join(map(str, versions[:3]))
    minimum = '.'.join(map(str, versions[3:]))
    version_tuple(version)
    version_tuple(minimum)
    _require(expected_version is None or version == expected_version,
             'Windows CLI metadata version does not match the selected release')
    return {'schema': schema, 'protocol': protocol, 'minimum_protocol': minimum_protocol,
            'maximum_protocol': maximum_protocol, 'version': version, 'minimum_launcher': minimum}


def metadata_assembly(version: str, syntax: str) -> str:
    """Emit a 64-byte read-only COFF section for x86_64 or aarch64.

    Both LLVM assemblers accept the same byte directives. The caller must
    obtain version from the source being built, not the build tool's checkout.
    """
    _require(syntax in ('x86_64', 'aarch64'), 'unsupported Windows CLI assembly syntax')
    data = metadata_bytes(version)
    return '.section .asmmeta,"dr"\n.p2align 2\n.byte ' + ', '.join(map(str, data)) + '\n'
