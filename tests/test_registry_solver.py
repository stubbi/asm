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

from registry_graph_oracle import (exhaustive_solutions, generated_graphs, requirement_matches,
    exhaustive_feature_solutions, generated_feature_graphs)


ROOT = Path(__file__).resolve().parents[1]


class Requirement(ctypes.Structure):
    _fields_ = [("name", ctypes.c_char_p), ("requirement", ctypes.c_char_p)]


class Candidate(ctypes.Structure):
    _fields_ = [("name", ctypes.c_char_p), ("version", ctypes.c_char_p),
                ("dependencies", ctypes.c_void_p), ("count", ctypes.c_uint64),
                ("usable", ctypes.c_uint64)]


class FeatureOption(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_uint64), ("requests", ctypes.c_void_p), ("count", ctypes.c_uint64)]


class FeatureDefinition(ctypes.Structure):
    _fields_ = [("name", ctypes.c_char_p), ("members", ctypes.c_void_p), ("count", ctypes.c_uint64)]


class FeatureProfile(ctypes.Structure):
    _fields_ = [("options", ctypes.c_void_p), ("definitions", ctypes.c_void_p), ("count", ctypes.c_uint64)]


G4_GLOBALS = ("profiles", "root_profile", "requests", "request_count", "defaults", "active_features",
              "active_deps", "root_features", "root_deps", "lazy", "known_names", "known_count", "missing_name")
G4_HELPERS = ("profile_init", "profile_copy", "profile_validate", "profile_equal")
G3_GLOBALS = ("candidates", "candidate_count", "roots", "root_count", "solution", "steps", "limit")


class NativeSolver:
    """Build test-only C ABI wrappers around the actual assembly routines."""

    def __init__(self, directory):
        arm = platform.machine() in ("aarch64", "arm64")
        source = ROOT / ("cli/aarch64/registry_solver.s" if arm else "cli/registry_solver.s")
        if not source.is_file():
            raise AssertionError(f"native resolver implementation is missing: {source}")
        path = Path(directory) / "solver.s"
        darwin = platform.system() == "Darwin"
        parts = ([ROOT / "cli/aarch64/platform.inc"] if arm else []) + [source.with_name("registry_features.s"), source]
        if darwin:
            # Use the shipping adapter so model tests retain its actual BSS
            # layout, symbol aliases, and ARM address relocations.
            import sys
            sys.path.insert(0, str(ROOT / "tools"))
            import macos
            text = "".join(macos.prepare(part) for part in parts)
        else:
            text = "".join(part.read_text() for part in parts)
        if arm:
            prefix = "_" if darwin else ""
            for routine in ("requirement", "solve"):
                text += f"\n.text\n.global {prefix}test_g3_{routine}\n{prefix}test_g3_{routine}:\n"
                text += f"    ARM_CALL g3_{routine}\n    mov x0, x9\n    ret\n"
            for routine in G4_HELPERS:
                text += f"\n.text\n.global {prefix}test_g4_{routine}\n{prefix}test_g4_{routine}:\n"
                text += f"    ARM_CALL g4_{routine}\n    mov x0, x9\n    ret\n"
            if darwin:
                for name in G3_GLOBALS:
                    text += f".global _g3_{name}\n.set _g3_{name}, g3_{name}\n"
                for name in G4_GLOBALS:
                    text += f".global _g4_{name}\n.set _g4_{name}, g4_{name}\n"
        else:
            if darwin:
                for name in ("requirement", "solve", *G3_GLOBALS):
                    text += f"\n.global _g3_{name}\n.set _g3_{name}, g3_{name}\n"
                for name in (*G4_GLOBALS, *G4_HELPERS):
                    text += f".global _g4_{name}\n.set _g4_{name}, g4_{name}\n"
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
        for routine, arguments, result in (
                ("profile_init", [ctypes.c_void_p], ctypes.c_void_p),
                ("profile_copy", [ctypes.c_void_p, ctypes.c_void_p], ctypes.c_void_p),
                ("profile_validate", [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint64], ctypes.c_uint64),
                ("profile_equal", [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint64], ctypes.c_uint64)):
            function = getattr(self.library, ("test_g4_" if arm else "g4_") + routine)
            function.argtypes, function.restype = arguments, result
            setattr(self, routine, function)

    def owned_profile(self, dependencies=(), features=None):
        block = ctypes.create_string_buffer(11296)
        base = ctypes.addressof(block)
        assert self.profile_init(base) == base
        profile = FeatureProfile.from_buffer(block)
        options = (FeatureOption * 64).from_address(base + 24)
        definitions = (FeatureDefinition * 64).from_address(base + 1560)
        used = 0
        def text(values):
            nonlocal used
            raw = b"".join(value.encode() + b"\0" for value in values)
            assert used + len(raw) <= 8192
            pointer = base + 3096 + used
            ctypes.memmove(pointer, raw, len(raw))
            used += len(raw)
            return pointer
        for i, edge in enumerate(dependencies):
            options[i] = FeatureOption(int(edge.get("optional", False)) | (2 if edge.get("default_features", True) else 0),
                                       text(edge.get("features", [])), len(edge.get("features", [])))
        for i, (name, members) in enumerate(sorted((features or {}).items())):
            name_pointer = ctypes.cast(text([name]), ctypes.c_char_p)
            definitions[i] = FeatureDefinition(name_pointer, text(members), len(members))
        profile.count = len(features or {})
        ctypes.c_uint64.from_buffer(block, 11288).value = used
        return block

    def solve(self, candidates, roots, limit=100000, *, features=None, requested=(), defaults=True,
              lazy=False, known=()):
        owned = []
        def nul_list(values):
            data = ctypes.create_string_buffer(b"".join(value.encode() + b"\0" for value in values))
            owned.append(data)
            return ctypes.addressof(data)

        def profile(deps, definitions):
            options = (FeatureOption * len(deps))(*[
                FeatureOption(int(edge.get("optional", False)) | (2 if edge.get("default_features", True) else 0),
                              nul_list(edge.get("features", [])), len(edge.get("features", []))) for edge in deps])
            definitions = (FeatureDefinition * len(definitions))(*[
                FeatureDefinition(name.encode(), nul_list(members), len(members)) for name, members in sorted(definitions.items())])
            result = FeatureProfile(ctypes.addressof(options), ctypes.addressof(definitions), len(definitions))
            owned.extend((options, definitions, result))
            return ctypes.addressof(result)

        native_profiles = (ctypes.c_void_p * 256).in_dll(self.library, "g4_profiles")
        for i in range(256):
            native_profiles[i] = None
        for i, candidate in enumerate(candidates):
            native_profiles[i] = profile(candidate.get("dependencies", []), candidate.get("features", {}))
        ctypes.c_void_p.in_dll(self.library, "g4_root_profile").value = profile(roots, features or {})
        ctypes.c_void_p.in_dll(self.library, "g4_requests").value = nul_list(requested)
        ctypes.c_uint64.in_dll(self.library, "g4_request_count").value = len(requested)
        ctypes.c_uint64.in_dll(self.library, "g4_defaults").value = defaults
        ctypes.c_uint64.in_dll(self.library, "g4_lazy").value = lazy
        native_known = (ctypes.c_char_p * 256).in_dll(self.library, "g4_known_names")
        for i, name in enumerate(known):
            native_known[i] = name.encode()
        ctypes.c_uint64.in_dll(self.library, "g4_known_count").value = len(known)
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
        self.missing_name = ctypes.c_char_p.in_dll(self.library, "g4_missing_name").value
        masks = (ctypes.c_uint64 * 256).in_dll(self.library, "g4_active_features")
        dep_masks = (ctypes.c_uint64 * 256).in_dll(self.library, "g4_active_deps")
        self.activation = frozenset((node["name"], name) for i, node in enumerate(candidates)
                                    for bit, name in enumerate(sorted(node.get("features", {}))) if masks[i] & (1 << bit))
        self.active_edges = frozenset((node["name"], edge["name"]) for i, node in enumerate(candidates)
                                     for bit, edge in enumerate(node.get("dependencies", [])) if dep_masks[i] & (1 << bit))
        root_mask = ctypes.c_uint64.in_dll(self.library, "g4_root_features").value
        self.activation |= frozenset(("$root", name) for bit, name in enumerate(sorted(features or {})) if root_mask & (1 << bit))
        root_deps = ctypes.c_uint64.in_dll(self.library, "g4_root_deps").value
        self.active_edges |= frozenset(("$root", edge["name"]) for bit, edge in enumerate(roots) if root_deps & (1 << bit))
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

    def test_optional_dependency_stays_dormant_until_a_feature_activates_it(self):
        nodes = [dict(name="o/a", version="1.0.0", dependencies=[dict(name="o/b", requirement="*", optional=True)],
                      features={"bundle": ["dep:o/b"]}), dict(name="o/b", version="1.0.0")]
        roots = [dict(name="o/a", requirement="*")]
        self.assertEqual(self.native.solve(nodes, roots), (0, {("o/a", "1.0.0")}))
        roots[0]["features"] = ["bundle"]
        self.assertEqual(self.native.solve(nodes, roots), (0, {("o/a", "1.0.0"), ("o/b", "1.0.0")}))
        self.assertEqual(self.native.activation, {("o/a", "bundle")})

    def test_additive_transitive_features_defaults_and_dependency_cycles(self):
        nodes = [dict(name="o/a", version="1.0.0", features={"a": ["o/b/b"]},
                      dependencies=[dict(name="o/b", requirement="*", optional=True, default_features=False)]),
                 dict(name="o/b", version="1.0.0", features={"b": ["dep:o/c"], "default": []},
                      dependencies=[dict(name="o/c", requirement="*", optional=True)]),
                 dict(name="o/c", version="1.0.0", dependencies=[dict(name="o/a", requirement="*", features=["a"])])]
        roots = [dict(name="o/a", requirement="*"), dict(name="o/b", requirement="*")]
        result = self.native.solve(nodes, roots, features={"default": ["start"], "start": ["o/a/a"]})
        self.assertEqual(result[0], 0)
        self.assertEqual(self.native.activation, {( "$root", "default"), ("$root", "start"),
                                                  ("o/a", "a"), ("o/b", "b"), ("o/b", "default")})
        self.assertIn(result[1], [item[0] for item in exhaustive_feature_solutions(nodes, roots,
            features={"default": ["start"], "start": ["o/a/a"]})])

    def test_dormant_optional_edge_cannot_constrain_or_request_an_already_selected_child(self):
        nodes = [dict(name="o/a", version="1.0.0", dependencies=[dict(name="o/b", requirement="2.0.0", optional=True, features=["missing"])]),
                 dict(name="o/b", version="1.0.0", features={"default": []})]
        roots = [dict(name="o/a", requirement="*"), dict(name="o/b", requirement="*", default_features=False)]
        self.assertEqual(self.native.solve(nodes, roots)[0], 0)
        self.assertEqual(self.native.activation, set())
        self.assertNotIn(("o/a", "o/b"), self.native.active_edges)

    def test_unknown_child_feature_backtracks_to_a_version_that_defines_it(self):
        nodes = [dict(name="o/a", version="2.0.0"), dict(name="o/a", version="1.0.0", features={"ready": []})]
        self.assertEqual(self.native.solve(nodes, [dict(name="o/a", requirement="*", features=["ready"])]),
                         (0, {("o/a", "1.0.0")}))
        self.assertEqual(self.native.activation, {("o/a", "ready")})

    def test_failed_branch_leaves_no_feature_or_optional_edge_facts(self):
        nodes = [dict(name="o/a", version="2.0.0", features={"default": ["dep:o/b"]},
                      dependencies=[dict(name="o/b", requirement="2.0.0", optional=True)]),
                 dict(name="o/a", version="1.0.0", features={"default": []}),
                 dict(name="o/b", version="1.0.0")]
        self.assertEqual(self.native.solve(nodes, [dict(name="o/a", requirement="*")]), (0, {("o/a", "1.0.0")}))
        self.assertEqual(self.native.activation, {("o/a", "default")})
        self.assertEqual(self.native.active_edges, {("$root", "o/a")})

    def test_feature_bits_63_and_64_are_unsigned_and_never_wrap(self):
        features = {f"f{i:02}": [] for i in range(64)}
        nodes = [dict(name="o/a", version="1.0.0", features=features)]
        roots = [dict(name="o/a", requirement="*", features=["f62", "f63"])]
        self.assertEqual(self.native.solve(nodes, roots)[0], 0)
        self.assertEqual(self.native.activation, {("o/a", "f62"), ("o/a", "f63")})
        self.assertEqual(self.native.solve(nodes, roots, limit=1), (2, set()))
        self.assertEqual(self.native.activation, set())
        self.assertEqual(self.native.active_edges, set())

    def test_invalid_inactive_feature_metadata_and_unknown_root_features_are_malformed(self):
        invalid = [{"bad!": []}, {"a": ["missing"]}, {"a": ["a"]},
                   {"a": ["b"], "b": ["a"]}, {"a": ["dep:o/missing"]},
                   {"a": ["dep:o/b"]}, {"a": ["o/missing/f"]}, {"a": ["x", "x"], "x": []},
                   {"a": ["o/b/Bad"]}, {"a": ["o/b/f/"]}]
        for features in invalid:
            with self.subTest(features=features):
                nodes = [dict(name="o/inactive", version="1.0.0", features=features,
                              dependencies=[dict(name="o/b", requirement="*")])]
                self.assertEqual(self.native.solve(nodes, []), (3, set()))
        self.assertEqual(self.native.solve([], [], requested=["missing"], lazy=True), (3, set()))
        self.assertIsNone(self.native.missing_name)
        self.assertEqual(self.native.solve([], [], features={"a": []}, requested=["a", "a"]), (3, set()))

    def test_lazy_missing_name_is_explicit_and_known_absence_is_unsatisfiable(self):
        roots = [dict(name="o/missing", requirement="*")]
        self.assertEqual(self.native.solve([], roots, lazy=True), (4, set()))
        self.assertEqual(self.native.missing_name, b"o/missing")
        self.assertEqual(self.native.solve([], roots, lazy=True, known=["o/missing"]), (1, set()))
        self.assertIsNone(self.native.missing_name)

    def test_generated_feature_graphs_match_independent_fixed_point_oracle(self):
        for index, (nodes, roots, features, requested) in enumerate(generated_feature_graphs()):
            with self.subTest(graph=index):
                solutions = exhaustive_feature_solutions(nodes, roots, features=features, requested=requested)
                result = self.native.solve(nodes, roots, features=features, requested=requested)
                if solutions:
                    self.assertEqual(result[0], 0)
                    self.assertIn((result[1], self.native.activation, self.native.active_edges), solutions)
                else:
                    self.assertEqual(result, (1, set()))
                self.assertEqual(self.native.solve(list(reversed(nodes)), roots, features=features, requested=requested), result)

    def test_owned_profile_initialization_copy_and_semantic_equality(self):
        dependencies = [dict(name="o/b", requirement="*", optional=True, features=["b"], default_features=False)]
        pairs = (Requirement * 1)(Requirement(b"o/b", b"*"))
        source = self.native.owned_profile(dependencies, {"default": ["dep:o/b"], "f": ["o/b/b"]})
        destination = ctypes.create_string_buffer(11296)
        source_address, destination_address = ctypes.addressof(source), ctypes.addressof(destination)
        self.assertEqual(self.native.profile_validate(source_address, ctypes.addressof(pairs), 1), 0)
        self.assertEqual(self.native.profile_copy(destination_address, source_address), destination_address)
        self.assertEqual(self.native.profile_equal(source_address, destination_address, 1), 0)
        copied = FeatureProfile.from_buffer(destination)
        self.assertEqual(copied.options, destination_address + 24)
        self.assertEqual(copied.definitions, destination_address + 1560)
        source[:] = bytes(len(source))
        self.assertEqual(self.native.profile_validate(destination_address, ctypes.addressof(pairs), 1), 0)
        options = (FeatureOption * 64).from_address(copied.options)
        definitions = (FeatureDefinition * 64).from_address(copied.definitions)
        for pointer in (options[0].requests, definitions[0].members):
            self.assertGreaterEqual(pointer, destination_address + 3096)
            self.assertLess(pointer, destination_address + 11288)
        self.assertEqual(ctypes.string_at(options[0].requests), b"b")
        self.assertEqual(definitions[0].name, b"default")
        explicit_legacy = self.native.owned_profile()
        self.assertEqual(self.native.profile_equal(None, ctypes.addressof(explicit_legacy), 64), 0)
        self.assertEqual(self.native.profile_equal(destination_address, None, 1), 1)
        self.assertEqual(self.native.profile_copy(destination_address, None), destination_address)
        self.assertEqual(self.native.profile_equal(destination_address, None, 64), 0)

    def test_generic_profile_rejects_invalid_counts_flags_names_and_duplicate_lists(self):
        pair = (Requirement * 1)(Requirement(b"o/b", b"*"))
        for mutation in ("flags", "requests", "features", "members", "duplicate-definitions", "null-definition"):
            with self.subTest(mutation=mutation):
                block = self.native.owned_profile([dict(name="o/b", requirement="*", optional=True)], {"a": [], "b": []})
                profile = FeatureProfile.from_buffer(block)
                options = (FeatureOption * 64).from_address(profile.options)
                definitions = (FeatureDefinition * 64).from_address(profile.definitions)
                if mutation == "flags": options[0].flags = 4
                elif mutation == "requests": options[0].count = 65
                elif mutation == "features": profile.count = 65
                elif mutation == "members": definitions[0].count = 65
                elif mutation == "duplicate-definitions": definitions[1].name = definitions[0].name
                else: definitions[1].name = None
                self.assertEqual(self.native.profile_validate(ctypes.addressof(block), ctypes.addressof(pair), 1), 1)
        self.assertEqual(self.native.profile_validate(None, None, 65), 1)
        nodes = [dict(name="o/a", version="1.0.0", dependencies=[dict(name="o/b", requirement="*", features=["b", "b"])])]
        self.assertEqual(self.native.solve(nodes, []), (3, set()))

    def test_disabled_defaults_do_not_remove_another_active_edges_default_request(self):
        nodes = [dict(name="o/a", version="1.0.0", dependencies=[dict(name="o/shared", requirement="*", default_features=False)]),
                 dict(name="o/b", version="1.0.0", dependencies=[dict(name="o/shared", requirement="*")]),
                 dict(name="o/shared", version="1.0.0", features={"default": []})]
        roots = [dict(name="o/a", requirement="*"), dict(name="o/b", requirement="*")]
        self.assertEqual(self.native.solve(nodes, roots)[0], 0)
        self.assertEqual(self.native.activation, {("o/shared", "default")})
        self.assertEqual(self.native.solve(nodes, roots, defaults=False)[0], 0)
        self.assertEqual(self.native.activation, {("o/shared", "default")})

    def test_local_feature_chain_and_requested_list_reach_the_sixty_four_entry_bound(self):
        features = {f"f{i:02}": ([f"f{i+1:02}"] if i < 63 else []) for i in range(64)}
        nodes = [dict(name="o/a", version="1.0.0", features=features)]
        roots = [dict(name="o/a", requirement="*", features=["f00"])]
        self.assertEqual(self.native.solve(nodes, roots)[0], 0)
        self.assertEqual(self.native.activation, {("o/a", feature) for feature in features})
        roots[0]["features"] = list(features)
        self.assertEqual(self.native.solve(nodes, roots)[0], 0)
        self.assertEqual(self.native.solve(nodes, roots, limit=32), (2, set()))
        self.assertEqual(self.native.active_edges, set())
        self.assertEqual(self.native.solve([], [], features={f"f{i:02}": [] for i in range(64)},
                                         requested=[f"f{i:02}" for i in range(64)])[0], 0)
        self.assertEqual(self.native.solve([], [], requested=["f"] * 65), (2, set()))

    def test_late_transitive_feature_growth_reprocesses_an_already_reached_package(self):
        nodes = [dict(name="o/a", version="1.0.0", dependencies=[dict(name="o/b", requirement="*")]),
                 dict(name="o/b", version="1.0.0", features={"unlock": ["dep:o/d"]},
                      dependencies=[dict(name="o/d", requirement="*", optional=True)]),
                 dict(name="o/c", version="1.0.0", dependencies=[dict(name="o/b", requirement="*", features=["unlock"])]),
                 dict(name="o/d", version="1.0.0")]
        roots = [dict(name="o/a", requirement="*"), dict(name="o/c", requirement="*")]
        self.assertEqual(self.native.solve(nodes, roots), (0, {(node["name"], "1.0.0") for node in nodes}))
        self.assertEqual(self.native.activation, {("o/b", "unlock")})
        self.assertIn(("o/b", "o/d"), self.native.active_edges)

    def test_sixty_four_optional_dependencies_preserve_high_dependency_bits(self):
        dependencies = [dict(name=f"o/p{i:03}", requirement="*", optional=True) for i in range(64)]
        children = [dict(name=edge["name"], version="1.0.0") for edge in dependencies]
        parent = dict(name="o/a", version="1.0.0", dependencies=dependencies,
                      features={"bundle": ["dep:o/p062", "dep:o/p063"]})
        roots = [dict(name="o/a", requirement="*", features=["bundle"])]
        self.assertEqual(self.native.solve([parent, *children], roots),
                         (0, {("o/a", "1.0.0"), ("o/p062", "1.0.0"), ("o/p063", "1.0.0")}))
        self.assertEqual(self.native.active_edges, {("$root", "o/a"), ("o/a", "o/p062"), ("o/a", "o/p063")})
        self.assertEqual(self.native.solve(children, dependencies, features={"bundle": ["dep:o/p063"]}, requested=["bundle"]),
                         (0, {("o/p063", "1.0.0")}))
        self.assertEqual(self.native.active_edges, {("$root", "o/p063")})

    def test_root_defaults_are_disabled_without_removing_explicit_root_requests(self):
        features = {"default": ["start"], "start": []}
        self.assertEqual(self.native.solve([], [], features=features, defaults=False), (0, set()))
        self.assertEqual(self.native.activation, set())
        self.assertEqual(self.native.solve([], [], features=features, defaults=False, requested=["start"]), (0, set()))
        self.assertEqual(self.native.activation, {("$root", "start")})

    def test_inactive_feature_metadata_consumes_the_explicit_operation_budget(self):
        node = dict(name="o/inactive", version="1.0.0", features={f"f{i:02}": [] for i in range(64)})
        self.assertEqual(self.native.solve([node], [], limit=16), (2, set()))
        self.assertEqual(self.native.activation, set())
        self.assertEqual(self.native.solve([node], [], limit=70), (0, set()))

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
