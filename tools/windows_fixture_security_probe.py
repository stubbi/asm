"""Read owner and DACL evidence without changing Windows fixture security.

This diagnostic does not authorize an installation or establish race freedom.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import ctypes
from datetime import datetime, timezone
import os
from pathlib import PureWindowsPath


def path_chain(value):
    """Keep all local-drive prefixes, including the leaf, with explicit bounds."""
    text = str(value).replace('/', '\\')
    path = PureWindowsPath(text)
    if (len(text.encode('utf-8')) > 4096 or len(path.drive) != 2
            or not path.drive[0].isascii() or not path.drive[0].isalpha()
            or path.drive[1] != ':' or path.root != '\\'):
        raise ValueError('Require a bounded absolute local-drive path.')
    parts = text[3:].split('\\') if len(text) > 3 else []
    if len(parts) > 32 or any(not part or part in ('.', '..') or part.endswith(('.', ' '))
            or any(char in part for char in ':\x00*?<>|"') for part in parts):
        raise ValueError('The path contains an ambiguous component.')
    return [str(PureWindowsPath(path.anchor, *parts[:index])) for index in range(len(parts) + 1)]


def path_requests(home, source, extra_paths=()):
    if len(extra_paths) > 16:
        raise ValueError('At most 16 additional fixture paths are permitted.')
    rows, seen = [], {}
    for role, path in [('home', home), ('source_artifact', source)] + [
            (f'generated_fixture_{index}', value) for index, value in enumerate(extra_paths)]:
        chain = path_chain(path)
        for index, value in enumerate(chain):
            key = value.casefold()
            if key not in seen:
                if len(rows) >= 64:
                    raise ValueError('The security snapshot exceeds 64 paths.')
                seen[key] = {'path': value, 'roles': [], 'private_home_leaf': False,
                             'private_owner_required': False}
                rows.append(seen[key])
            seen[key]['roles'].append({'role': role, 'leaf': index == len(chain) - 1})
            if role == 'home' and index == len(chain) - 1:
                seen[key]['private_home_leaf'] = True
                seen[key]['private_owner_required'] = True
    return rows


class Reader:
    def __init__(self):
        self.k = ctypes.WinDLL('kernel32', use_last_error=True)
        self.a = ctypes.WinDLL('advapi32', use_last_error=True)
        p, u = ctypes.c_void_p, ctypes.c_uint32
        for dll, name, args, result in (
            (self.k, 'GetCurrentProcess', [], p),
            (self.k, 'CloseHandle', [p], ctypes.c_int),
            (self.k, 'LocalFree', [p], p),
            (self.k, 'CreateFileW', [ctypes.c_wchar_p, u, u, p, u, u, p], p),
            (self.k, 'GetFileInformationByHandleEx', [p, ctypes.c_int, p, u], ctypes.c_int),
            (self.a, 'OpenProcessToken', [p, u, ctypes.POINTER(p)], ctypes.c_int),
            (self.a, 'GetTokenInformation', [p, ctypes.c_int, p, u, ctypes.POINTER(u)], ctypes.c_int),
            (self.a, 'ConvertSidToStringSidW', [p, ctypes.POINTER(p)], ctypes.c_int),
            (self.a, 'GetSecurityInfo', [p, u, u] + [ctypes.POINTER(p)] * 5, u),
            (self.a, 'GetSecurityDescriptorLength', [p], u),
            (self.a, 'ConvertSecurityDescriptorToStringSecurityDescriptorW',
                [p, u, u, ctypes.POINTER(p), ctypes.POINTER(u)], ctypes.c_int),
        ):
            function = getattr(dll, name)
            function.argtypes, function.restype = args, result

    def sid(self, pointer):
        result = ctypes.c_void_p()
        if not pointer or not self.a.ConvertSidToStringSidW(pointer, ctypes.byref(result)):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            # The trusted API returns a terminated SID string from a validated SID.
            value = ctypes.wstring_at(result.value)
            if not value.startswith('S-1-') or len(value) > 184:
                raise ValueError('The SID string exceeds its format bound.')
            return value
        finally:
            self.k.LocalFree(result)

    def token(self):
        handle = ctypes.c_void_p()
        if not self.a.OpenProcessToken(self.k.GetCurrentProcess(), 8, ctypes.byref(handle)):
            raise ctypes.WinError(ctypes.get_last_error())
        rows = {}
        try:
            for name, kind in (('user', 1), ('default_owner', 4), ('elevation_type', 18), ('elevation', 20)):
                size = ctypes.c_uint32()
                if self.a.GetTokenInformation(handle, kind, None, 0, ctypes.byref(size)):
                    raise RuntimeError('The zero-capacity token query unexpectedly succeeded.')
                if ctypes.get_last_error() != 122 or not 4 <= size.value <= 65536:
                    raise RuntimeError('Cannot bound the token observation.')
                buffer = ctypes.create_string_buffer(size.value)
                if not self.a.GetTokenInformation(handle, kind, buffer, len(buffer), ctypes.byref(size)):
                    raise ctypes.WinError(ctypes.get_last_error())
                row = {'raw_hex': buffer.raw.hex(), 'bytes': size.value}
                if kind in (1, 4):
                    pointer = ctypes.c_void_p.from_buffer(buffer).value
                    if not ctypes.addressof(buffer) <= pointer < ctypes.addressof(buffer) + len(buffer):
                        raise RuntimeError('The token SID pointer is outside its buffer.')
                    row['sid'] = self.sid(pointer)
                else:
                    row['value'] = int.from_bytes(buffer.raw[:4], 'little')
                rows[name] = row
        finally:
            if not self.k.CloseHandle(handle):
                raise ctypes.WinError(ctypes.get_last_error())
        return rows

    def inspect(self, row):
        row.update(requested_access=0x20080, share=7, create_disposition=3,
                   open_flags=0x02200000, handle_closed=False)
        handle = self.k.CreateFileW(row['path'], 0x20080, 7, None, 3, 0x02200000, None)
        if handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        descriptor = ctypes.c_void_p()
        try:
            tag, identity = ctypes.create_string_buffer(8), ctypes.create_string_buffer(24)
            if not self.k.GetFileInformationByHandleEx(handle, 9, tag, len(tag)):
                raise ctypes.WinError(ctypes.get_last_error())
            row['attribute_tag_raw_hex'] = tag.raw.hex()
            if int.from_bytes(tag.raw[:4], 'little') & 0x400:
                raise ValueError('A prefix is a reparse point; no later prefix may be inspected.')
            if not self.k.GetFileInformationByHandleEx(handle, 18, identity, len(identity)):
                raise ctypes.WinError(ctypes.get_last_error())
            row['file_id_raw_hex'] = identity.raw.hex()
            owner, group, dacl, sacl = (ctypes.c_void_p() for _ in range(4))
            status = self.a.GetSecurityInfo(handle, 1, 5, ctypes.byref(owner), ctypes.byref(group),
                ctypes.byref(dacl), ctypes.byref(sacl), ctypes.byref(descriptor))
            row['get_security_info_status'] = status
            if status:
                raise ctypes.WinError(status)
            size = self.a.GetSecurityDescriptorLength(descriptor)
            if not 20 <= size <= 65536:
                raise ValueError('The descriptor exceeds its byte bound.')
            row.update(security_descriptor_hex=ctypes.string_at(descriptor, size).hex(),
                       security_descriptor_bytes=size, owner_sid=self.sid(owner.value), dacl_null=not bool(dacl.value))
            text, length = ctypes.c_void_p(), ctypes.c_uint32()
            if not self.a.ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor, 1, 5,
                    ctypes.byref(text), ctypes.byref(length)):
                raise ctypes.WinError(ctypes.get_last_error())
            try:
                if not 1 <= length.value <= 65536:
                    raise ValueError('The SDDL string exceeds its bound.')
                row['sddl'] = ctypes.wstring_at(text.value, length.value).rstrip('\x00')
            finally:
                self.k.LocalFree(text)
        finally:
            if descriptor.value:
                self.k.LocalFree(descriptor)
            if not self.k.CloseHandle(handle):
                row['close_error'] = ctypes.get_last_error()
                raise ctypes.WinError(row['close_error'])
            row['handle_closed'] = True


def snapshot(home, source, extra_paths=()):
    """Return read-only evidence for every requested prefix.

    Supply default TEMP, USERPROFILE, and generated fixture paths in extra_paths.
    The caller retains this dictionary with its exact-source installer report.
    """
    rows = path_requests(home, source, extra_paths)
    if os.name != 'nt':
        raise RuntimeError('Native Windows is required for fixture security observations.')
    reader = Reader()
    report = {'schema': 'asm-windows-fixture-security-v1', 'changes_security': False,
              'qualifies_installer': False, 'observed_utc': datetime.now(timezone.utc).isoformat(),
              'scope': 'Owner and DACL snapshot; no effective-access or race-free claim',
              'token': reader.token(), 'paths': rows, 'complete': True}
    blocked = []
    for row in rows:
        path = PureWindowsPath(row['path'])
        if any(path.is_relative_to(prefix) for prefix in blocked):
            row['error'] = {'message': 'An earlier prefix observation failed; traversal was refused.'}
            report['complete'] = False
            continue
        try:
            reader.inspect(row)
        except Exception as error:
            row['error'] = {'type': type(error).__name__, 'message': str(error),
                            'winerror': getattr(error, 'winerror', None)}
            report['complete'] = False
            blocked.append(path)
    return report
