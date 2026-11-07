"""Give disposable private fixtures their required current-user owner.

This changes fixture ownership only. It preserves every access-control entry.
SPDX-License-Identifier: AGPL-3.0-or-later
"""

import ctypes
from ctypes import wintypes
from pathlib import Path


def own_path(path, root):
    """Set TokenUser as owner inside root; retain the existing DACL.

    Elevated Windows tokens can default to Administrators ownership. Private
    directory fixtures require the actual user, just like ordinary-user paths.
    No token setting, privilege, production path, or permission grant changes.
    """
    path, root = Path(path), Path(root).resolve()
    if not path.resolve().is_relative_to(root) or path.lstat().st_file_attributes & 0x400:
        raise ValueError("The owner fixture must be a direct path inside its temporary root.")
    if not (path.is_dir() or path.is_file()):
        raise ValueError("The owner fixture must be an existing file or directory.")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    advapi.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    advapi.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                          wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    advapi.SetNamedSecurityInfoW.argtypes = [wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD,
                                            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    advapi.SetNamedSecurityInfoW.restype = wintypes.DWORD
    token = wintypes.HANDLE()
    if not advapi.OpenProcessToken(kernel.GetCurrentProcess(), 0x0008, ctypes.byref(token)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        size = wintypes.DWORD()
        if advapi.GetTokenInformation(token, 1, None, 0, ctypes.byref(size)):
            raise RuntimeError("A zero-capacity TokenUser query unexpectedly succeeded.")
        if ctypes.get_last_error() != 122 or not 16 <= size.value <= 65536:
            raise RuntimeError("Cannot bound the fixture's TokenUser information.")
        data = ctypes.create_string_buffer(size.value)
        if not advapi.GetTokenInformation(token, 1, data, size.value, ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        sid = ctypes.c_void_p.from_buffer(data).value
        # OWNER_SECURITY_INFORMATION alone leaves the DACL and inheritance intact.
        status = advapi.SetNamedSecurityInfoW(str(path), 1, 1, sid, None, None, None)
        if status:
            raise ctypes.WinError(status)
    finally:
        kernel.CloseHandle(token)


def own_directory(path, root):
    """Require a directory before assigning the disposable fixture's owner."""
    if not Path(path).is_dir():
        raise ValueError("The owner fixture must be an existing directory.")
    own_path(path, root)


def own_home_directories(home, root):
    """Set ownership on the existing HOME, .local, state, and bin fixtures."""
    home = Path(home)
    for relative in (".", ".local", ".local/state", ".local/bin"):
        path = home / relative
        if path.exists() and not path.is_symlink():
            own_directory(path, root)
