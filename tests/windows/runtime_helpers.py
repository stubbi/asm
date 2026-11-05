"""Small helpers for safe Windows test fixtures, not CLI runtime behavior.

SPDX-License-Identifier: AGPL-3.0-or-later
"""


def final_replacement_failure(source, arm64):
    begin_marker = "\nself_commit_update:\n"
    end_marker = "\nself_update_cleanup:\n"
    if source.count(begin_marker) != 1 or source.count(end_marker) != 1:
        raise ValueError("The final replacement routine boundary is ambiguous.")
    begin = source.index(begin_marker)
    end = source.index(end_marker, begin)
    commit = source[begin:end]
    if arm64:
        anchor = "    ARM_CALL arm_renameat\n"
        replacement = "    mov x2, #-1\n" + anchor
    else:
        anchor = ("    mov eax, 264\n"
                  "    mov rdi, [rip + self_stage_fd]\n"
                  "    lea rsi, [rip + self_payload_name]\n"
                  "    mov rdx, [rip + self_parent_fd]\n"
                  "    lea r10, [rip + self_binary_name]\n"
                  "    call win_syscall\n")
        replacement = anchor.replace("    call win_syscall\n", "    mov rdx, -1\n    call win_syscall\n")
    if commit.count(anchor) != 1:
        raise ValueError("The final replacement call is absent or ambiguous.")
    mutated = commit.replace(anchor, replacement, 1)
    return source[:begin] + mutated + source[end:]


def assert_complete_provenance(calls):
    actual = [call for call in calls if call != "curl"]
    expected = ["manifest-identity", "manifest-exact", "candidate-exact"]
    if actual != expected:
        raise AssertionError(f"Expected provenance bindings {expected}; observed {actual}.")


def absolute_archive_cases(directory):
    """Return hostile absolute names whose actual targets belong to directory.

    The caller owns this directory and keeps it alive until checks finish.
    A Windows rooted name uses the current working directory's drive.
    """
    if not directory.is_absolute():
        raise ValueError("The hostile archive root must be absolute.")
    drive_target = directory / "drive-absolute"
    rooted_target = directory / "rooted-absolute"
    if directory.drive:
        if not directory.drive.endswith(":"):
            raise ValueError("The hostile archive root must use a local drive.")
        rooted_name = rooted_target.as_posix()[len(directory.drive):]
    else:
        rooted_name = rooted_target.as_posix()
    return [(drive_target.as_posix(), drive_target), (rooted_name, rooted_target)]


def capture_deadline_source(root, arm64):
    if arm64:
        source = (root / "cli/windows/aarch64/pipe.s").read_text()
        begin = source.index("win_pump_capture:\n")
        end = source.index("\n.section .rdata", begin)
        body = source[begin:end]
        macros = (root / "cli/aarch64/platform.inc").read_text().replace(".arch armv8-a\n", "")
        template = (root / "tests/windows/capture_deadline_arm64.s").read_text()
        return template.replace("/* CAPTURE_MACROS */", macros).replace("/* CAPTURE_BODY */", body)
    source = (root / "cli/windows/x86_64/platform.s").read_text()
    begin = source.index(".Lwp_poll:\n")
    end = source.index(".Lwp_complete:\n", begin)
    body = source[begin:end]
    return (root / "tests/windows/capture_deadline_x64.s").read_text().replace("/* CAPTURE_BODY */", body)


def displaced_running_image(installed, version, environment, cwd, *, own_replacement, timeout=15):
    """Suspend a real CLI before startup, then replace its original pathname.

    Windows-only test fixture. CPython's own CreateProcess adapter supplies
    literal arguments and an explicit inherited-handle list. Kernel class44
    observations and file IDs establish distinct files despite equal bytes.
    Unsupported APIs, failed renames, and timeouts are errors, never skips.
    """
    import ctypes
    from ctypes import wintypes
    import hashlib
    import os
    import subprocess
    import threading

    report = {"fixture": "error", "stage": "host", "timeout_seconds": timeout,
              "identity_api": "NtQueryInformationProcess/ProcessImageFileMapping(44)",
              "rename_api": "SetFileInformationByHandle/FileRenameInfoEx/POSIX_SEMANTICS",
              "native_api_qualification": False}
    if os.name != "nt":
        report["error"] = "The displaced-image fixture requires native Windows."
        return report
    import _winapi
    import msvcrt

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    HANDLE, DWORD, VOID = wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p
    invalid = ctypes.c_void_p(-1).value
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, DWORD, DWORD, VOID, DWORD, DWORD, HANDLE]
    kernel.CreateFileW.restype = HANDLE
    kernel.GetModuleHandleW.argtypes = [wintypes.LPCWSTR]
    kernel.GetModuleHandleW.restype = HANDLE
    kernel.GetProcAddress.argtypes = [HANDLE, ctypes.c_char_p]
    kernel.GetProcAddress.restype = VOID
    kernel.GetFileInformationByHandle.argtypes = [HANDLE, VOID]
    kernel.GetFileInformationByHandle.restype = wintypes.BOOL
    kernel.SetFileInformationByHandle.argtypes = [HANDLE, ctypes.c_int, VOID, DWORD]
    kernel.SetFileInformationByHandle.restype = wintypes.BOOL
    kernel.ResumeThread.argtypes = [HANDLE]
    kernel.ResumeThread.restype = DWORD
    kernel.CloseHandle.argtypes = [HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL

    class FileInformation(ctypes.Structure):
        _fields_ = [("attributes", DWORD), ("created", wintypes.FILETIME),
                    ("accessed", wintypes.FILETIME), ("written", wintypes.FILETIME),
                    ("volume", DWORD), ("size_high", DWORD), ("size_low", DWORD),
                    ("links", DWORD), ("index_high", DWORD), ("index_low", DWORD)]

    class RenameInformation(ctypes.Structure):
        _fields_ = [("flags", DWORD), ("root", HANDLE), ("length", DWORD),
                    ("name", wintypes.WCHAR * 1)]

    def require(condition, message):
        if not condition:
            raise RuntimeError(message)

    def file_handle(path, *, delete=False):
        # READ_DATA, EXECUTE, READ_ATTRIBUTES, READ_CONTROL, SYNCHRONIZE.
        handle = kernel.CreateFileW(str(path), 0x1200A1 | (0x10000 if delete else 0),
                                    7, None, 3, 0x200000, None)
        if handle == invalid:
            raise ctypes.WinError(ctypes.get_last_error())
        return handle

    def identity(handle):
        info = FileInformation()
        if not kernel.GetFileInformationByHandle(handle, ctypes.byref(info)):
            raise ctypes.WinError(ctypes.get_last_error())
        require(not info.attributes & 0x410, "The image fixture must be a regular file without reparse points.")
        require(info.links == 1, "The image fixture must have exactly one hard link.")
        return {"volume_serial": info.volume, "file_index": info.index_high << 32 | info.index_low,
                "links": info.links, "bytes": info.size_high << 32 | info.size_low}

    process = thread = original = replacement = None
    descriptors, readers, captured = [], [], {"stdout": bytearray(), "stderr": bytearray()}
    overflow, reader_errors = threading.Event(), []
    completed = False
    try:
        report["stage"] = "resolve-kernel-query"
        address = kernel.GetProcAddress(kernel.GetModuleHandleW("ntdll.dll"), b"NtQueryInformationProcess")
        require(address, "NtQueryInformationProcess is unavailable; no path-only fallback is permitted.")
        query = ctypes.WINFUNCTYPE(wintypes.LONG, HANDLE, ctypes.c_int, VOID, DWORD, VOID)(address)
        require(ctypes.sizeof(HANDLE) == 8, "The fixture requires a 64-bit native Python process.")
        require(installed.stat().st_size <= 8 * 1024 * 1024, "The fixture CLI exceeds its 8 MiB byte limit.")
        before = installed.read_bytes()
        before_digest = hashlib.sha256(before).hexdigest()
        report["sha256_before"] = before_digest
        displaced = installed.with_name("displaced-running-image.exe")
        require(not displaced.exists(), "The displacement destination already exists.")
        output_read, output_write = os.pipe()
        error_read, error_write = os.pipe()
        null_input = os.open(os.devnull, os.O_RDONLY)
        descriptors.extend([output_read, output_write, error_read, error_write, null_input])
        handles = [msvcrt.get_osfhandle(fd) for fd in (null_input, output_write, error_write)]
        startup = subprocess.STARTUPINFO()
        startup.dwFlags = subprocess.STARTF_USESTDHANDLES
        startup.hStdInput, startup.hStdOutput, startup.hStdError = handles
        startup.lpAttributeList = {"handle_list": handles}
        arguments = [str(installed), "self", "update", version, "--json"]
        report["argv"] = arguments
        report["stage"] = "create-suspended-cli"
        for handle in handles:
            os.set_handle_inheritable(handle, True)
        try:
            process, thread, process_id, _ = _winapi.CreateProcess(
                str(installed), subprocess.list2cmdline(arguments), None, None, True,
                0x4 | 0x400, dict(environment), str(cwd), startup)
        finally:
            for handle in handles:
                os.set_handle_inheritable(handle, False)
        report["process_id"] = process_id
        for fd in (output_write, error_write, null_input):
            os.close(fd)
            descriptors.remove(fd)

        def read_output(fd, name):
            try:
                while data := os.read(fd, 4096):
                    remaining = 65536 - len(captured[name])
                    captured[name].extend(data[:remaining])
                    if len(data) > remaining:
                        overflow.set()
                        _winapi.TerminateProcess(process, 124)
                        break
            except OSError as error:
                reader_errors.append(str(error))

        for fd, name in ((output_read, "stdout"), (error_read, "stderr")):
            reader = threading.Thread(target=read_output, args=(fd, name), daemon=True)
            reader.start()
            readers.append(reader)
        report["stage"] = "open-mapped-original"
        original = file_handle(installed, delete=True)
        report["original_identity"] = identity(original)

        def mapping_status(handle):
            value = HANDLE(handle)
            return query(process, 44, ctypes.byref(value), 8, None) & 0xFFFFFFFF

        report["original_mapping_before"] = mapping_status(original)
        require(report["original_mapping_before"] == 0, "The original file does not match the suspended process image.")
        report["stage"] = "rename-mapped-original"
        name = str(displaced).encode("utf-16-le")
        buffer = ctypes.create_string_buffer(max(ctypes.sizeof(RenameInformation), RenameInformation.name.offset + len(name)))
        rename = RenameInformation.from_buffer(buffer)
        rename.flags = 2  # FILE_RENAME_FLAG_POSIX_SEMANTICS; destination must be absent.
        rename.root = None
        rename.length = len(name)
        ctypes.memmove(ctypes.byref(buffer, RenameInformation.name.offset), name, len(name))
        if not kernel.SetFileInformationByHandle(original, 22, buffer, len(buffer)):
            raise ctypes.WinError(ctypes.get_last_error())
        report["rename_succeeded"] = True
        report["stage"] = "create-byte-identical-replacement"
        with installed.open("xb") as output:
            output.write(before)
        # Match the undisplaced positive control's owner. Elevated Python's
        # default Administrators owner must not create a false rejection.
        own_replacement(installed)
        replacement = file_handle(installed)
        report["replacement_identity"] = identity(replacement)
        identity_fields = ("volume_serial", "file_index")
        require(tuple(report["replacement_identity"][key] for key in identity_fields) !=
                tuple(report["original_identity"][key] for key in identity_fields),
                "The replacement did not create a distinct file identity.")
        report["original_mapping_after"] = mapping_status(original)
        report["replacement_mapping_after"] = mapping_status(replacement)
        require(report["original_mapping_after"] == 0, "The held original lost its process image binding.")
        require(report["replacement_mapping_after"] == 0xC0000001,
                "The separate replacement did not receive STATUS_UNSUCCESSFUL from the kernel identity check.")
        report["stage"] = "resume-displaced-cli"
        require(kernel.ResumeThread(thread) == 1, "The suspended CLI thread did not resume exactly once.")
        result = _winapi.WaitForSingleObject(process, int(timeout * 1000))
        require(result == 0, "The displaced CLI exceeded its execution deadline.")
        completed = True
        report["exit_code"] = _winapi.GetExitCodeProcess(process)
        report["stage"] = "check-preserved-files"
        report["original_identity_after"] = identity(original)
        report["replacement_identity_after"] = identity(replacement)
        require(report["original_identity_after"] == report["original_identity"], "The original file identity changed.")
        require(report["replacement_identity_after"] == report["replacement_identity"], "The replacement file identity changed.")
        report["sha256_displaced_after"] = hashlib.sha256(displaced.read_bytes()).hexdigest()
        report["sha256_replacement_after"] = hashlib.sha256(installed.read_bytes()).hexdigest()
        require(report["sha256_displaced_after"] == report["sha256_replacement_after"] == before_digest,
                "The displaced or replacement bytes changed.")
        report["native_api_qualification"] = True
        report["fixture"] = "complete"
    except Exception as error:
        report["error"] = str(error)
    finally:
        if process is not None and not completed:
            try:
                _winapi.TerminateProcess(process, 124)
                _winapi.WaitForSingleObject(process, 5000)
            except OSError as error:
                report["cleanup_error"] = str(error)
        for reader in readers:
            reader.join(timeout=5)
        if any(reader.is_alive() for reader in readers) or reader_errors or overflow.is_set():
            report["fixture"] = "error"
            report["capture_error"] = {"reader_errors": reader_errors, "overflow": overflow.is_set(),
                                       "unfinished_readers": any(reader.is_alive() for reader in readers)}
        for fd in descriptors:
            os.close(fd)
        for handle in (replacement, original, thread, process):
            if handle is not None:
                kernel.CloseHandle(handle)
        report["stdout"] = captured["stdout"].decode("utf-8", errors="replace")
        report["stderr"] = captured["stderr"].decode("utf-8", errors="replace")
    return report
