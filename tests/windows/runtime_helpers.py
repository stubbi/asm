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
