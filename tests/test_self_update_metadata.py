"""Bounded native release-metadata checks; no network or package execution."""

import copy
import json
from pathlib import Path
import random
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.2.1"
DIGEST = "0123456789abcdef" * 4
COMMIT = "1234567890abcdef" * 2 + "12345678"
SIZE = 71664
LIMIT = 1048576

# This harness maps borrowed input immediately before a PROT_NONE page and
# makes the input mapping read-only. It also checks every callee-saved register,
# stack balance, and cleared output after rejection.
HARNESS = r"""
.intel_syntax noprefix
.global _start
.extern self_parse_release, self_source_commit
.text
_start:
    cld
    cmp qword ptr [rsp], 4
    jne harness_error
    mov rax, [rsp + 16]
    mov [rip + harness_row + 8], rax
    mov rax, [rsp + 24]
    mov [rip + harness_row + 32], rax
    mov rax, [rsp + 32]
    mov [rip + harness_row + 48], rax
    xor r12d, r12d
harness_read:
    cmp r12, 1048577
    jae harness_read_done
    xor eax, eax
    xor edi, edi
    lea rsi, [rip + harness_input]
    add rsi, r12
    mov edx, 1048577
    sub rdx, r12
    syscall
    cmp rax, -4
    je harness_read
    test rax, rax
    js harness_error
    jz harness_read_done
    add r12, rax
    jmp harness_read
harness_read_done:
    mov [rip + harness_length], r12
    lea rdi, [rip + harness_input]
    cmp r12, 1048576
    ja harness_call
    mov eax, 9
    xor edi, edi
    mov esi, 1056768
    mov edx, 3
    mov r10d, 34
    mov r8, -1
    xor r9d, r9d
    syscall
    cmp rax, -4095
    jae harness_error
    mov r14, rax
    mov eax, 10
    mov rdi, r14
    mov esi, 4096
    xor edx, edx
    syscall
    test rax, rax
    js harness_error
    mov eax, 10
    lea rdi, [r14 + 1052672]
    mov esi, 4096
    xor edx, edx
    syscall
    test rax, rax
    js harness_error
    lea rdi, [r14 + 1052672]
    sub rdi, r12
    mov [rip + harness_start], rdi
    lea rsi, [rip + harness_input]
    mov rcx, r12
    rep movsb
    mov eax, 10
    lea rdi, [r14 + 4096]
    mov esi, 1048576
    mov edx, 1
    syscall
    test rax, rax
    js harness_error
    mov rdi, [rip + harness_start]
harness_call:
    mov [rip + harness_start], rdi
    lea rdi, [rip + self_source_commit]
    mov eax, 'X'
    mov ecx, 41
    rep stosb
    mov rdi, [rip + harness_start]
    mov rsi, [rip + harness_length]
    lea rdx, [rip + harness_row]
    mov ebx, 0x1111
    mov ebp, 0x2222
    mov r12d, 0x3333
    mov r13d, 0x4444
    mov r14d, 0x5555
    mov r15d, 0x6666
    mov [rip + harness_stack], rsp
    call self_parse_release
    cmp rsp, [rip + harness_stack]
    jne harness_error
    cmp rbx, 0x1111
    jne harness_error
    cmp rbp, 0x2222
    jne harness_error
    cmp r12, 0x3333
    jne harness_error
    cmp r13, 0x4444
    jne harness_error
    cmp r14, 0x5555
    jne harness_error
    cmp r15, 0x6666
    jne harness_error
    test eax, eax
    jz harness_success
    cmp eax, 1
    jne harness_error
    lea rdi, [rip + self_source_commit]
    xor ecx, ecx
harness_cleared:
    cmp byte ptr [rdi + rcx], 0
    jne harness_error
    inc ecx
    cmp ecx, 41
    jb harness_cleared
    mov edi, 1
    jmp harness_exit
harness_success:
    cmp byte ptr [rip + self_source_commit + 40], 0
    jne harness_error
    mov eax, 1
    mov edi, 1
    lea rsi, [rip + self_source_commit]
    mov edx, 40
    syscall
    cmp rax, 40
    jne harness_error
    xor edi, edi
    jmp harness_exit
harness_error:
    mov edi, 3
harness_exit:
    mov eax, 60
    syscall
.section .rodata
harness_package: .asciz "stubbi/asm"
harness_target: .asciz "x86_64-linux"
harness_kind: .asciz "executable"
harness_unused: .asciz ""
.data
harness_row:
    .quad harness_package, 0, harness_target, harness_kind
    .quad 0, harness_unused, 0, harness_unused
.bss
.balign 8
harness_length: .skip 8
harness_start: .skip 8
harness_stack: .skip 8
harness_input: .skip 1048577
.section .note.GNU-stack,"",@progbits
"""


def release():
    return {
        "schema": 1,
        "project": "asm",
        "repository": "https://github.com/stubbi/asm",
        "version": VERSION,
        "tag": "v" + VERSION,
        "source_commit": COMMIT,
        "assets": [{"file": f"asm-{VERSION}-x86_64-linux",
                    "bytes": SIZE, "sha256": DIGEST}],
    }


def encode(value):
    return json.dumps(value, sort_keys=True, indent=2).encode()


class SelfUpdateMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / "build").mkdir(exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(
            prefix="self-metadata-", dir=ROOT / "build")
        cls.work = Path(cls.temporary.name)
        (cls.work / "harness.s").write_text(HARNESS)
        cls.binary = cls.work / "harness"
        for source, output in (
                (cls.work / "harness.s", cls.work / "harness.o"),
                (ROOT / "cli/self_update_metadata.s", cls.work / "metadata.o")):
            subprocess.run(["as", "--64", "--fatal-warnings", "-o", str(output),
                            str(source)], check=True, capture_output=True, timeout=10)
        subprocess.run(
            ["ld", "-z", "noexecstack", "-z", "relro", "-z", "now",
             "--build-id=none", "-o", str(cls.binary),
             str(cls.work / "harness.o"), str(cls.work / "metadata.o")],
            check=True, capture_output=True, timeout=10)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def parse(self, data, *, ok=True, version=VERSION, digest=DIGEST, size=SIZE):
        if not isinstance(data, bytes):
            data = encode(data)
        result = subprocess.run(
            [str(self.binary), version, digest, str(size)],
            input=data, capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 0 if ok else 1,
                         (len(data), data[:180], result.returncode, result.stderr))
        self.assertEqual(result.stdout, COMMIT.encode() if ok else b"")
        self.assertEqual(result.stderr, b"")

    def test_release_fields_and_asset_match_selected_record(self):
        self.parse(release())
        self.parse(json.dumps(release(), separators=(",", ":")).encode())
        self.parse(b"\r\n \t" + encode(release()) + b"\r\n \t")
        document = release()
        document["assets"].insert(0, {
            "file": f"asm-{VERSION}-source.tar.gz", "bytes": 1234,
            "sha256": "a" * 64})
        document["assets"].append({
            "file": f"hello-{VERSION}-aarch64-linux", "bytes": 1064,
            "sha256": "b" * 64})
        document["builds"] = {
            "asm": {"version_check": {"stdout": f"asm {VERSION}\n",
                                      "exit_code": 0, "status": "pass"}},
            "hello": {"aarch64-linux": {"runner": "qemu-aarch64", "args": []}},
        }
        document["tool_versions"] = {"as": "GNU assembler 2.42", "python": "3.12.3"}
        self.parse(document)

    def test_required_fields_types_and_identity_are_exact(self):
        for field in release():
            document = release()
            del document[field]
            with self.subTest(missing=field):
                self.parse(document, ok=False)
        changes = {
            "schema": (True, "1", 1.0, 2),
            "project": (None, {}, "ASM"),
            "repository": ("https://github.com/other/asm",
                           "https://github.com/stubbi/asm/", []),
            "version": ("0.2.0", "00.2.1", 1),
            "tag": ("0.2.1", "v0.2.0", None),
            "source_commit": ("0" * 40, "a" * 39, "a" * 41,
                              "A" * 40, "g" * 40, None),
            "assets": ({}, [], None),
        }
        for key, values in changes.items():
            for value in values:
                with self.subTest(field=key, value=value):
                    document = release()
                    document[key] = value
                    self.parse(document, ok=False)

    def test_trusted_strings_reject_escape_aliases(self):
        original = encode(release())
        for before, after in (
            (b'"asm"', b'"\\u0061sm"'),
            (b'"version"', b'"\\u0076ersion"'),
            (COMMIT.encode(), b"\\u0031" + COMMIT[1:].encode()),
            (DIGEST.encode(), b"\\u0030" + DIGEST[1:].encode()),
            (b'"asm-' + VERSION.encode(), b'"\\u0061sm-' + VERSION.encode()),
        ):
            with self.subTest(alias=after):
                self.parse(original.replace(before, after, 1), ok=False)

    def test_candidate_filename_digest_and_size_are_bound(self):
        for field, values in (
            ("file", (f"asm-{VERSION}-aarch64-linux", "other",
                      f"asm-0.2.0-x86_64-linux", f"asm-{VERSION}-x86_64-linux/")),
            ("sha256", ("f" * 64, "a" * 63, "A" * 64, "g" * 64)),
            ("bytes", (SIZE + 1, SIZE - 1, 0, -1, 67108865, True, str(SIZE),
                       float(SIZE))),
        ):
            for value in values:
                with self.subTest(field=field, value=value):
                    document = release()
                    document["assets"][0][field] = value
                    self.parse(document, ok=False)
        for field in ("file", "bytes", "sha256"):
            document = release()
            del document["assets"][0][field]
            self.parse(document, ok=False)
        document = release()
        document["assets"][0]["extra"] = 1
        self.parse(document, ok=False)

    def test_every_asset_is_validated_and_names_are_unique(self):
        document = release()
        document["assets"].append(copy.deepcopy(document["assets"][0]))
        self.parse(document, ok=False)
        unrelated = {"file": "other.bin", "bytes": 4, "sha256": "b" * 64}
        document = release()
        document["assets"].extend([unrelated, unrelated])
        self.parse(document, ok=False)
        for invalid in (None, 1, [], "other", {}, {
                "file": "../other", "bytes": 4, "sha256": "b" * 64}, {
                "file": "other", "bytes": 4, "sha256": "B" * 64}):
            document = release()
            document["assets"].append(invalid)
            self.parse(document, ok=False)

    def test_duplicate_keys_are_rejected_at_every_depth(self):
        document = encode(release())
        self.parse(b'{"schema":1,' + document[1:], ok=False)
        self.parse(document[:-1] + b',"x":1,"x":2}', ok=False)
        self.parse(document[:-1] + b',"x":{"z":1,"z":2}}', ok=False)
        self.parse(document.replace(b'"bytes": 71664',
                                    b'"bytes": 71664, "bytes": 71664'), ok=False)
        self.parse(document[:-1] + b',"x":[{"z":1,"z":2}]}', ok=False)
        self.parse(document[:-1] + b',"x":{"z":1,"\\u007a":2}}', ok=False)

    def test_nested_lookalike_fields_cannot_replace_root_identity(self):
        document = release()
        document["ignored"] = {
            "source_commit": "b" * 40, "version": "99.0.0",
            "repository": "https://github.com/other/asm",
            "assets": [{"file": "other", "bytes": 4, "sha256": "b" * 64}]}
        self.parse(document)
        for key in ("source_commit", "version", "repository", "assets"):
            altered = copy.deepcopy(document)
            del altered[key]
            self.parse(altered, ok=False)

    def test_unknown_values_have_strict_json_grammar(self):
        base = encode(release())[:-1] + b',"ignored":'
        for value in (b"true", b"false", b"null", b"0", b"-0", b"1.25",
                      b"-12e-2", b"123E+45", b'{"x":[{},[],true,null]}'):
            self.parse(base + value + b"}")
        for value in (b"True", b"NaN", b"Infinity", b"+1", b"01", b"-",
                      b"1.", b"1e", b"1e+", b"0x1", b"[1,]", b'{"x":1,}',
                      b'{"x" 1}', b'{"x":}', b"tru", b"[1 2]",
                      b'{"x":1 "y":2}', b"nullx"):
            self.parse(base + value + b"}", ok=False)

    def test_unknown_strings_validate_unicode_and_escapes(self):
        base = encode(release())[:-1] + b',"ignored":'
        for value in (b'"\\\"\\\\\\/\\b\\f\\n\\r\\t"', b'"\\u0000"',
                      b'"\\u00e9"', b'"\\ud83d\\ude00"', '"é水😀"'.encode()):
            self.parse(base + value + b"}")
        for value in (b'"\\x20"', b'"\\u123"', b'"\\uz000"', b'"\\ud800"',
                      b'"\\udc00"', b'"\\ud800\\u0041"', b'"\x00"',
                      b'"\x1f"', b'"\x80"', b'"\xc0\xaf"', b'"\xc2"',
                      b'"\xed\xa0\x80"', b'"\xf4\x90\x80\x80"',
                      b'"\xf5\x80\x80\x80"'):
            self.parse(base + value + b"}", ok=False)

    def test_trailing_data_and_non_object_roots_are_rejected(self):
        for data in (b"", b" ", b"{}", b"[]", b"null", b'"asm"', b"1",
                     b"\xef\xbb\xbf" + encode(release()),
                     encode(release()) + b"{}", encode(release()) + b"\0",
                     encode(release()) + b"\v"):
            self.parse(data, ok=False)

    def test_every_truncation_ends_at_a_guard_page(self):
        document = json.dumps(release(), separators=(",", ":")).encode()
        for length in range(len(document)):
            with self.subTest(length=length):
                self.parse(document[:length], ok=False)

    def test_nesting_object_array_and_token_limits(self):
        prefix = encode(release())[:-1] + b',"ignored":'
        self.parse(prefix + b"[" * 30 + b"0" + b"]" * 30 + b"}")
        self.parse(prefix + b"[" * 31 + b"0" + b"]" * 31 + b"}", ok=False)
        document = release()
        document["ignored"] = {f"k{i}": 0 for i in range(256)}
        self.parse(document)
        document["ignored"]["one_more"] = 0
        self.parse(document, ok=False)
        document = release()
        document["ignored"] = [0] * 4096
        self.parse(document)
        document["ignored"].append(0)
        self.parse(document, ok=False)
        document["ignored"] = [[0] * 4000 for _ in range(3)]
        self.parse(document)
        document["ignored"] = [[0] * 4096 for _ in range(4)]
        self.parse(document, ok=False)

    def test_input_string_key_and_asset_limits(self):
        document = encode(release())
        self.parse(document + b" " * (LIMIT - len(document)))
        self.parse(document + b" " * (LIMIT + 1 - len(document)), ok=False)
        value = release()
        value["ignored"] = "x" * 16384
        self.parse(value)
        value["ignored"] += "x"
        self.parse(value, ok=False)
        value = release()
        value["k" * 256] = 0
        self.parse(value)
        value["k" * 257] = 0
        self.parse(value, ok=False)
        value = release()
        for i in range(255):
            value["assets"].append({"file": f"other-{i}", "bytes": 1,
                                    "sha256": "0" * 64})
        self.parse(value)
        value["assets"].append({"file": "one-more", "bytes": 1, "sha256": "0" * 64})
        self.parse(value, ok=False)

    def test_fixed_seed_malformed_corpus_has_bounded_failure(self):
        random_source = random.Random(0x41534D)
        document = encode(release())
        for _ in range(96):
            position = random_source.randrange(len(document) + 1)
            self.parse(document[:position] + b"\0" + document[position:], ok=False)
        for _ in range(64):
            data = random_source.randbytes(random_source.randrange(512))
            self.parse(data, ok=False)


if __name__ == "__main__":
    unittest.main()
