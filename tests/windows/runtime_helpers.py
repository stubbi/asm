"""Small helpers for safe Windows test fixtures, not CLI runtime behavior.

SPDX-License-Identifier: AGPL-3.0-or-later
"""


def fault_observation(arm64, stage):
    """Observe one test-only fault point without changing native call inputs.

    The managed boundaries carry integer state, not live AVX or SVE state.
    Preserve every volatile integer/vector register, flags, and the return
    address across the standard Windows C ABI. Nonvolatile registers remain
    the callee's responsibility. The entry stack is already 16-byte aligned.
    Link snapshot_barrier.c only into these deliberately instrumented variants.
    """
    stages = {'payload_flush': 1, 'record_write': 2, 'record_flush': 3,
              'activation_rename': 4}
    if stage not in stages:
        raise ValueError('Unknown managed fault observation boundary.')
    if arm64:
        # 160 bytes: x0..x17, LR, NZCV. 512 bytes: all q registers.
        # q8..q15 also have volatile upper halves under the Windows ABI.
        lines = ['    sub sp, sp, #672']
        for index in range(0, 18, 2):
            lines.append(f'    stp x{index}, x{index + 1}, [sp, #{index * 8}]')
        lines += ['    str x30, [sp, #144]', '    mrs x16, nzcv',
                  '    str x16, [sp, #152]']
        vectors = list(range(0, 32, 2))
        for offset, index in enumerate(vectors):
            lines.append(f'    stp q{index}, q{index + 1}, [sp, #{160 + offset * 32}]')
        lines += [f'    mov x0, #{stages[stage]}', '    bl asm_test_fault_reached']
        for offset, index in enumerate(vectors):
            lines.append(f'    ldp q{index}, q{index + 1}, [sp, #{160 + offset * 32}]')
        lines += ['    ldr x16, [sp, #152]', '    msr nzcv, x16',
                  '    ldr x30, [sp, #144]']
        for index in range(0, 18, 2):
            lines.append(f'    ldp x{index}, x{index + 1}, [sp, #{index * 8}]')
        lines.append('    add sp, sp, #672')
    else:
        registers = ['rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11']
        lines = ['    pushfq'] + ['    push ' + reg for reg in registers]
        # 32 bytes of shadow space, then the six volatile XMM registers.
        lines.append('    sub rsp, 128')
        lines += [f'    movdqu [rsp + {32 + index * 16}], xmm{index}' for index in range(6)]
        lines += [f'    mov ecx, {stages[stage]}', '    call asm_test_fault_reached']
        lines += [f'    movdqu xmm{index}, [rsp + {32 + index * 16}]' for index in range(6)]
        lines += ['    add rsp, 128'] + ['    pop ' + reg for reg in reversed(registers)]
        lines.append('    popfq')
    return '\n'.join(lines) + '\n'


def snapshot_source(source, arm64):
    marker = '\nwin_managed_snapshot_ready:\n'
    if source.count(marker) != 1:
        raise ValueError('The launcher snapshot boundary is absent or ambiguous.')
    hook = ('    ARM_CALL asm_test_snapshot_barrier\n' if arm64 else
            '    sub rsp, 32\n    call asm_test_snapshot_barrier\n    add rsp, 32\n')
    return source.replace(marker, marker + hook, 1)


def preparation_failure(source, arm64, stage):
    native = {'record_write': 'arm_write', 'record_flush': 'arm_fsync',
              'payload_flush': 'arm_fsync'}
    if stage not in native:
        raise ValueError('Unknown managed preparation boundary.')
    label = '\nwin_managed_' + stage + ':\n'
    call = '    ARM_CALL ' + native[stage] + '\n' if arm64 else '    call win_syscall\n'
    anchor = label + call
    if source.count(label) != 1 or source.count(anchor) != 1:
        raise ValueError('The managed preparation boundary is absent or ambiguous.')
    bad = '    mov x0, #-1\n' if arm64 else '    mov rdi, -1\n'
    return source.replace(anchor, label + fault_observation(arm64, stage) + bad + call, 1)


def final_replacement_failure(source, arm64):
    # The managed commit holds the exact flushed record HANDLE. Fault only
    # its destination directory after verification and payload publication.
    managed = '\nwin_managed_activation_rename:\n'
    if managed in source:
        call = ('    ARM_CALL win_managed_rename_fd\n' if arm64 else
                '    call win_managed_rename_fd\n')
        anchor = managed + call
        if source.count(managed) != 1 or source.count(anchor) != 1:
            raise ValueError('The managed activation call is absent or ambiguous.')
        bad = '    mov x1, #-1\n' if arm64 else '    mov rsi, -1\n'
        return source.replace(anchor, managed + fault_observation(arm64, 'activation_rename') + bad + call, 1)
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
    import ntpath
    import os
    import subprocess
    import threading

    report = {"fixture": "error", "stage": "host", "timeout_seconds": timeout,
              "identity_api": "NtQueryInformationProcess/ProcessImageFileMapping(44)",
              "rename_api": "NtSetInformationFile/FileRenameInformationEx(65)/POSIX_SEMANTICS",
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
    kernel.GetFinalPathNameByHandleW.argtypes = [HANDLE, wintypes.LPWSTR, DWORD, DWORD]
    kernel.GetFinalPathNameByHandleW.restype = DWORD
    kernel.SetFilePointerEx.argtypes = [HANDLE, ctypes.c_longlong, VOID, DWORD]
    kernel.SetFilePointerEx.restype = wintypes.BOOL
    kernel.ReadFile.argtypes = [HANDLE, VOID, DWORD, ctypes.POINTER(DWORD), VOID]
    kernel.ReadFile.restype = wintypes.BOOL
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

    class IoStatusResult(ctypes.Union):
        _fields_ = [("status", wintypes.LONG), ("pointer", VOID)]

    class IoStatusBlock(ctypes.Structure):
        _anonymous_ = ("result",)
        _fields_ = [("result", IoStatusResult), ("information", ctypes.c_size_t)]

    def require(condition, message):
        if not condition:
            raise RuntimeError(message)

    def file_handle(path, *, delete=False, directory=False):
        # READ_DATA, EXECUTE, READ_ATTRIBUTES, READ_CONTROL, SYNCHRONIZE.
        access = 0x1200A0 if directory else 0x1200A1
        flags = 0x200000 | (0x2000000 if directory else 0)
        handle = kernel.CreateFileW(str(path), access | (0x10000 if delete else 0),
                                    7, None, 3, flags, None)
        if handle == invalid:
            raise ctypes.WinError(ctypes.get_last_error())
        return handle

    def identity(handle, *, directory=False):
        info = FileInformation()
        if not kernel.GetFileInformationByHandle(handle, ctypes.byref(info)):
            raise ctypes.WinError(ctypes.get_last_error())
        require(not info.attributes & 0x400 and bool(info.attributes & 0x10) == directory,
                "The fixture handle has the wrong file type or a reparse point.")
        require(directory or info.links == 1, "The image fixture must have exactly one hard link.")
        return {"volume_serial": info.volume, "file_index": info.index_high << 32 | info.index_low,
                "links": info.links, "bytes": info.size_high << 32 | info.size_low}

    def final_path(handle):
        path = ctypes.create_unicode_buffer(4096)
        length = kernel.GetFinalPathNameByHandleW(handle, path, len(path), 0)
        if not length:
            raise ctypes.WinError(ctypes.get_last_error())
        require(length < len(path), "The final fixture path exceeds its WCHAR capacity.")
        return path.value

    def namespace_identity(path, expected):
        handle = file_handle(path)
        try:
            actual = identity(handle)
            require(actual == expected, "The intended pathname does not identify the held fixture file.")
            return actual
        finally:
            kernel.CloseHandle(handle)

    def handle_digest(handle, size):
        require(size <= 8 * 1024 * 1024, "The held image exceeds the fixture byte limit.")
        if not kernel.SetFilePointerEx(handle, 0, None, 0):
            raise ctypes.WinError(ctypes.get_last_error())
        digest, remaining = hashlib.sha256(), size
        buffer = ctypes.create_string_buffer(65536)
        while remaining:
            count = DWORD()
            if not kernel.ReadFile(handle, buffer, min(remaining, len(buffer)), ctypes.byref(count), None):
                raise ctypes.WinError(ctypes.get_last_error())
            require(0 < count.value <= min(remaining, len(buffer)), "The held image read ended early or exceeded its bound.")
            digest.update(buffer.raw[:count.value])
            remaining -= count.value
        count = DWORD()
        if not kernel.ReadFile(handle, buffer, 1, ctypes.byref(count), None):
            raise ctypes.WinError(ctypes.get_last_error())
        require(count.value == 0, "The held image has unexpected trailing bytes.")
        return digest.hexdigest()

    process = thread = original = replacement = parent = None
    descriptors, readers, captured = [], [], {"stdout": bytearray(), "stderr": bytearray()}
    overflow, reader_errors = threading.Event(), []
    completed = False
    try:
        report["stage"] = "resolve-kernel-query"
        address = kernel.GetProcAddress(kernel.GetModuleHandleW("ntdll.dll"), b"NtQueryInformationProcess")
        require(address, "NtQueryInformationProcess is unavailable; no path-only fallback is permitted.")
        query = ctypes.WINFUNCTYPE(wintypes.LONG, HANDLE, ctypes.c_int, VOID, DWORD, VOID)(address)
        address = kernel.GetProcAddress(kernel.GetModuleHandleW("ntdll.dll"), b"NtSetInformationFile")
        require(address, "NtSetInformationFile is unavailable; no pathname-only rename fallback is permitted.")
        set_information = ctypes.WINFUNCTYPE(wintypes.LONG, HANDLE, ctypes.POINTER(IoStatusBlock),
                                             VOID, DWORD, ctypes.c_int)(address)
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
        parent = file_handle(installed.parent, directory=True)
        report["parent_identity"] = identity(parent, directory=True)
        report["parent_final_path"] = final_path(parent)
        original = file_handle(installed, delete=True)
        report["original_identity"] = identity(original)
        report["original_final_path_before"] = final_path(original)

        def mapping_status(handle):
            value = HANDLE(handle)
            return query(process, 44, ctypes.byref(value), 8, None) & 0xFFFFFFFF

        report["original_mapping_before"] = mapping_status(original)
        require(report["original_mapping_before"] == 0, "The original file does not match the suspended process image.")
        report["stage"] = "rename-mapped-original"
        # Native class 65 consumes the held parent and relative basename directly.
        # FileName is terminated, while its byte length excludes NUL.
        name = displaced.name.encode("utf-16-le")
        buffer = ctypes.create_string_buffer(ctypes.sizeof(RenameInformation) + len(name) + 2)
        rename = RenameInformation.from_buffer(buffer)
        rename.flags = 2  # FILE_RENAME_FLAG_POSIX_SEMANTICS; destination must be absent.
        rename.root = parent
        rename.length = len(name)
        ctypes.memmove(ctypes.byref(buffer, RenameInformation.name.offset), name, len(name))
        report["rename_input"] = {"name": displaced.name, "file_name_length_bytes": len(name),
                                  "buffer_bytes": len(buffer), "terminated": True, "held_parent": True}
        completion = IoStatusBlock()
        completion.status = 0x103  # STATUS_PENDING sentinel; the file HANDLE uses synchronous I/O.
        status = set_information(original, ctypes.byref(completion), buffer, len(buffer), 65) & 0xFFFFFFFF
        report["rename_status"] = status
        report["rename_io_status"] = completion.status & 0xFFFFFFFF
        report["rename_io_information"] = completion.information
        require(status == 0 and report["rename_io_status"] == 0,
                f"The native held-parent rename failed: NTSTATUS 0x{status:08X}, "
                f"IO_STATUS_BLOCK 0x{report['rename_io_status']:08X}.")
        report["rename_succeeded"] = True
        report["original_final_path_after_rename"] = final_path(original)
        expected_displaced = report["parent_final_path"].rstrip("\\") + "\\" + displaced.name
        require(ntpath.normcase(report["original_final_path_after_rename"]) == ntpath.normcase(expected_displaced),
                "The renamed handle does not have the intended destination path.")
        report["displaced_namespace_identity_before_resume"] = namespace_identity(displaced, report["original_identity"])
        report["stage"] = "create-byte-identical-replacement"
        with installed.open("xb") as output:
            output.write(before)
        # Match the undisplaced positive control's owner. Elevated Python's
        # default Administrators owner must not create a false rejection.
        own_replacement(installed)
        replacement = file_handle(installed)
        report["replacement_identity"] = identity(replacement)
        report["replacement_final_path"] = final_path(replacement)
        expected_replacement = report["parent_final_path"].rstrip("\\") + "\\" + installed.name
        require(ntpath.normcase(report["replacement_final_path"]) == ntpath.normcase(expected_replacement),
                "The replacement handle does not have the intended installation path.")
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
        report["parent_identity_after"] = identity(parent, directory=True)
        require(all(report["parent_identity_after"][key] == report["parent_identity"][key] for key in identity_fields),
                "The fixture parent identity changed.")
        report["displaced_namespace_identity_after"] = namespace_identity(displaced, report["original_identity"])
        report["replacement_namespace_identity_after"] = namespace_identity(installed, report["replacement_identity"])
        report["sha256_displaced_after"] = handle_digest(original, report["original_identity"]["bytes"])
        report["sha256_replacement_after"] = handle_digest(replacement, report["replacement_identity"]["bytes"])
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
        for handle in (replacement, original, parent, thread, process):
            if handle is not None:
                kernel.CloseHandle(handle)
        report["stdout"] = captured["stdout"].decode("utf-8", errors="replace")
        report["stderr"] = captured["stderr"].decode("utf-8", errors="replace")
    return report
