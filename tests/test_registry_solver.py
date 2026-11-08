"""Execute the native graph solver without registry, transport, or backend mocks.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import ctypes
import platform
from pathlib import Path
import subprocess
import tempfile
import unittest

from registry_graph_oracle import exhaustive_solutions, generated_graphs, requirement_matches


ROOT = Path(__file__).resolve().parents[1]


class Requirement(ctypes.Structure):
    _fields_ = [("name", ctypes.c_char_p), ("requirement", ctypes.c_char_p)]


class Candidate(ctypes.Structure):
    _fields_ = [("name", ctypes.c_char_p), ("version", ctypes.c_char_p),
                ("dependencies", ctypes.c_void_p), ("count", ctypes.c_uint64),
                ("usable", ctypes.c_uint64)]


class NativeSolver:
    """Build test-only C ABI wrappers around the actual assembly routines."""

    def __init__(self, directory):
        arm = platform.machine() in ("aarch64", "arm64")
        source = ROOT / ("cli/aarch64/registry_solver.s" if arm else "cli/registry_solver.s")
        if not source.is_file():
            raise AssertionError(f"native resolver implementation is missing: {source}")
        path = Path(directory) / "solver.s"
        darwin = platform.system() == "Darwin"
        if arm:
            text = (ROOT / "cli/aarch64/platform.inc").read_text() + source.read_text()
            if darwin:
                text = text.replace("adrp \\reg, \\symbol", "adrp \\reg, (\\symbol)@PAGE")
                text = text.replace("add \\reg, \\reg, :lo12:\\symbol", "add \\reg, \\reg, (\\symbol)@PAGEOFF")
                text = text.replace(".section .text", ".text").replace(".section .rodata", ".data")
                text = text.replace(".section .bss", ".data").replace(".section .data", ".data")
            prefix = "_" if darwin else ""
            for routine in ("requirement", "solve"):
                text += f"\n.text\n.global {prefix}test_g3_{routine}\n{prefix}test_g3_{routine}:\n"
                text += f"    ARM_CALL g3_{routine}\n    mov x0, x9\n    ret\n"
            if darwin:
                for name in ("candidates", "candidate_count", "roots", "root_count", "solution", "steps", "limit"):
                    text += f".global _g3_{name}\n.set _g3_{name}, g3_{name}\n"
        else:
            text = source.read_text()
            if darwin:
                text = text.replace(".section .text", ".text").replace(".section .rodata", ".data")
                text = text.replace(".section .bss", ".data").replace(".section .data", ".data")
                for name in ("requirement", "solve", "candidates", "candidate_count", "roots",
                             "root_count", "solution", "steps", "limit"):
                    text += f"\n.global _g3_{name}\n.set _g3_{name}, g3_{name}\n"
        path.write_text(text)
        library = Path(directory) / ("solver.dylib" if darwin else "solver.so")
        if darwin:
            commands = [["clang", "-dynamiclib", "-o", str(library), str(path),
                         "-arch", "arm64" if arm else "x86_64"]]
        else:
            obj = Path(directory) / "solver.o"
            commands = [["as", *([] if arm else ["--64"]), "-o", str(obj), str(path)],
                        ["ld", "-shared", "-Bsymbolic", "-z", "noexecstack", "-o", str(library), str(obj)]]
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise AssertionError(result.stderr)
        self.library = ctypes.CDLL(str(library))
        self.requirement = getattr(self.library, "test_g3_requirement" if arm else "g3_requirement")
        self.requirement.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        self.requirement.restype = ctypes.c_int64
        self.solve_native = getattr(self.library, "test_g3_solve" if arm else "g3_solve")
        self.solve_native.argtypes = []
        self.solve_native.restype = ctypes.c_int64

    def solve(self, candidates, roots, limit=100000):
        owned = []
        native_candidates = (Candidate * 256).in_dll(self.library, "g3_candidates")
        native_roots = (Requirement * 64).in_dll(self.library, "g3_roots")
        for i, candidate in enumerate(candidates):
            deps = (Requirement * len(candidate.get("dependencies", [])))(*[
                Requirement(d["name"].encode(), d["requirement"].encode())
                for d in candidate.get("dependencies", [])])
            owned.append(deps)
            native_candidates[i] = Candidate(candidate["name"].encode(), candidate["version"].encode(),
                                              ctypes.addressof(deps), len(deps), candidate.get("usable", True))
        for i, root in enumerate(roots):
            native_roots[i] = Requirement(root["name"].encode(), root["requirement"].encode())
        ctypes.c_uint64.in_dll(self.library, "g3_candidate_count").value = len(candidates)
        ctypes.c_uint64.in_dll(self.library, "g3_root_count").value = len(roots)
        ctypes.c_uint64.in_dll(self.library, "g3_limit").value = limit
        code = self.solve_native()
        selected = (ctypes.c_ubyte * 256).in_dll(self.library, "g3_solution")
        return code, frozenset((c["name"], c["version"]) for i, c in enumerate(candidates) if selected[i])


class RegistrySolverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="asm-native-solver-")
        try:
            cls.native = NativeSolver(cls.directory.name)
        except BaseException:
            cls.directory.cleanup()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_requirement_boundaries_and_caret_zero_rules(self):
        cases = [("*", "0.0.0", 1), ("1.2.3", "1.2.3", 1), ("1.2.3", "1.2.4", 0),
                 (">=1.2.3,<2.0.0", "1.10.0", 1), (">=1.2.3,<2.0.0", "2.0.0", 0),
                 ("^0.2.3", "0.2.9", 1), ("^0.2.3", "0.3.0", 0),
                 ("^0.0.3", "0.0.4", 0), ("^1.2.3", "1.99.0", 1),
                 ("~1.2.3", "1.3.0", 0), (">1.2.3", "1.2.3", 0),
                 ("<=1.2.3", "1.2.3", 1), ("=1.2.3", "1.2.3", 1),
                 ("^2147483647.0.0", "2147483647.9.0", 1)]
        for requirement, version, expected in cases:
            with self.subTest(requirement=requirement, version=version):
                self.assertEqual(self.native.requirement(requirement.encode(), version.encode()), expected)

    def test_invalid_terms_are_rejected_even_after_an_earlier_mismatch(self):
        bad = ["", ">2.0.0,no", "1.2", "01.2.3", "1.2.3,", ",1.2.3", "*,1.2.3",
               "1.2.3-alpha", "1.2.3+build", " >=1.2.3", ">= 1.2.3", "1.2.2147483648",
               ",".join([">=0.0.0"] * 9), ">" + "1" * 129]
        for requirement in bad:
            with self.subTest(requirement=requirement):
                self.assertEqual(self.native.requirement(requirement.encode(), b"1.2.3"), -1)
        for version in (b"1.2", b"01.2.3", b"1.2.3-alpha", b"1.2.2147483648"):
            self.assertEqual(self.native.requirement(b"*", version), -1)

    def test_newest_selection_backtracks_on_a_shared_dependency(self):
        c = lambda name, version, deps=(): dict(name=name, version=version,
            dependencies=[dict(name=n, requirement=r) for n, r in deps])
        candidates = [c("o/a", "2.0.0", [("o/c", "2.0.0")]), c("o/c", "1.0.0"),
                      c("o/b", "1.0.0", [("o/c", "1.0.0")]), c("o/a", "1.0.0", [("o/c", "1.0.0")]),
                      c("o/c", "2.0.0"), c("o/unreachable", "9.0.0")]
        code, selected = self.native.solve(candidates, [dict(name="o/a", requirement="*"),
                                                       dict(name="o/b", requirement="*")])
        self.assertEqual(code, 0)
        self.assertEqual(selected, {("o/a", "1.0.0"), ("o/b", "1.0.0"), ("o/c", "1.0.0")})

    def test_cycle_terminates_and_does_not_select_unreachable_packages(self):
        candidates = [dict(name="o/a", version="1.0.0", dependencies=[dict(name="o/b", requirement="*")]),
                      dict(name="o/b", version="1.0.0", dependencies=[dict(name="o/a", requirement="*")]),
                      dict(name="o/c", version="1.0.0")]
        self.assertEqual(self.native.solve(candidates, [dict(name="o/a", requirement="*")]),
                         (0, {("o/a", "1.0.0"), ("o/b", "1.0.0")}))

    def test_numeric_newest_and_unusable_candidates(self):
        candidates = [dict(name="o/a", version="1.9.0"), dict(name="o/a", version="1.10.0"),
                      dict(name="o/a", version="2.0.0", usable=False)]
        self.assertEqual(self.native.solve(candidates, [dict(name="o/a", requirement="*")]),
                         (0, {("o/a", "1.10.0")}))

    def test_unsatisfiable_and_resource_limit_are_distinct_and_leave_no_solution(self):
        candidates = [dict(name="o/a", version="1.0.0")]
        self.assertEqual(self.native.solve(candidates, [dict(name="o/a", requirement="2.0.0")]), (1, set()))
        self.assertEqual(self.native.solve(candidates, [dict(name="o/missing", requirement="*")]), (1, set()))
        self.assertEqual(self.native.solve(candidates, [dict(name="o/a", requirement="*")], limit=0), (2, set()))
        candidates = [dict(name="o/a", version="1.0.0", dependencies=[dict(name="o/b", requirement="*")]),
                      dict(name="o/b", version="1.0.0")]
        self.assertEqual(self.native.solve(candidates, [dict(name="o/a", requirement="*")], limit=6), (2, set()))

    def test_invalid_graph_is_distinct_from_unsatisfiable(self):
        self.assertEqual(self.native.solve([dict(name="o/a", version="01.0.0")],
                                          [dict(name="o/a", requirement="*")]), (3, set()))

    def test_generated_graphs_match_independent_exhaustive_oracle(self):
        for index, (candidates, roots) in enumerate(generated_graphs(count=96)):
            with self.subTest(graph=index):
                solutions = exhaustive_solutions(candidates, roots)
                result = self.native.solve(candidates, roots)
                if solutions:
                    self.assertEqual(result[0], 0)
                    self.assertIn(result[1], solutions)
                else:
                    self.assertEqual(result, (1, set()))
                self.assertEqual(self.native.solve(candidates, list(reversed(roots))), result)
                self.assertEqual(self.native.solve(list(reversed(candidates)), roots), result)

    def test_range_matrix_matches_independent_oracle(self):
        versions = [f"{major}.{minor}.{patch}" for major in range(3)
                    for minor in range(3) for patch in range(3)]
        for base in ("0.0.1", "0.2.1", "1.0.0", "1.2.2", "2.2.2"):
            for operator in ("", "=", ">", ">=", "<", "<=", "^", "~"):
                requirement = operator + base
                for version in versions:
                    with self.subTest(requirement=requirement, version=version):
                        self.assertEqual(self.native.requirement(requirement.encode(), version.encode()),
                                         requirement_matches(requirement, version))

    def test_duplicate_identities_and_malformed_inactive_edges_are_rejected(self):
        candidates = [dict(name="o/a", version="1.0.0"), dict(name="o/a", version="1.0.0")]
        self.assertEqual(self.native.solve(candidates, []), (3, set()))
        candidates = [dict(name="o/a", version="1.0.0", usable=False,
                           dependencies=[dict(name="o/b", requirement=">2.0.0,invalid")])]
        self.assertEqual(self.native.solve(candidates, []), (3, set()))

    def test_maximum_length_chain_does_not_depend_on_metadata_input_order(self):
        candidates = [dict(name=f"o/p{i:03}", version="1.0.0", dependencies=(
            [dict(name=f"o/p{i+1:03}", requirement="*")] if i < 255 else [])) for i in range(256)]
        roots = [dict(name="o/p000", requirement="*")]
        expected = frozenset((c["name"], "1.0.0") for c in candidates)
        self.assertEqual(self.native.solve(candidates, roots), (0, expected))
        self.assertEqual(self.native.solve(list(reversed(candidates)), roots), (0, expected))


if __name__ == "__main__":
    unittest.main()
