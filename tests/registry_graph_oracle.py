"""Exhaustive small-graph oracle for native resolver tests only.

SPDX-License-Identifier: AGPL-3.0-or-later
Copyright (c) 2026 ASM contributors

The oracle enumerates complete assignments. It does not share the production
solver's search, propagation, conflict, or ordering implementation.
"""
from collections import defaultdict
from itertools import product
import random
import re


_VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")


def version_tuple(value):
    match = _VERSION.fullmatch(value)
    if match is None:
        raise ValueError("expected a canonical three-component version")
    result = tuple(map(int, match.groups()))
    if any(part > 2147483647 for part in result):
        raise ValueError("version component exceeds the test contract")
    return result


def requirement_matches(requirement, version):
    """Evaluate the specified bounded range grammar with Python tuple ordering."""
    actual = version_tuple(version)
    if requirement == "*":
        return True
    terms = requirement.split(",")
    if not 1 <= len(terms) <= 8:
        raise ValueError("expected one through eight range terms")
    result = True
    for term in terms:
        match = re.fullmatch(r"(>=|<=|>|<|=|\^|~)?(.+)", term)
        if match is None:
            raise ValueError("invalid range term")
        operator, raw = match.groups()
        required = version_tuple(raw)
        if operator in (None, "="):
            accepts = actual == required
        elif operator == ">=":
            accepts = actual >= required
        elif operator == "<=":
            accepts = actual <= required
        elif operator == ">":
            accepts = actual > required
        elif operator == "<":
            accepts = actual < required
        elif operator == "~":
            accepts = required <= actual < (required[0], required[1] + 1, 0)
        else:
            # Caret permits changes below the first nonzero component.
            first = next((index for index, part in enumerate(required) if part), 2)
            upper = required[:first] + (required[first] + 1,) + (0,) * (2 - first)
            accepts = required <= actual < upper
        result = result and accepts
    return result


def exhaustive_solutions(candidates, roots):
    """Return all valid reachable single-version assignments for a small graph.

    Input records contain name, version, dependencies, and optional usable.
    Root and dependency records contain name and requirement. A cycle is valid
    when its version constraints hold; packages appear only once in a solution.
    """
    choices = defaultdict(list)
    for candidate in candidates:
        version_tuple(candidate["version"])
        if candidate.get("usable", True):
            choices[candidate["name"]].append(candidate)
    names = sorted(choices)
    solutions = set()
    for selection in product(*[[None] + choices[name] for name in names]):
        selected = {name: candidate for name, candidate in zip(names, selection) if candidate is not None}
        constraints = list(roots)
        constraints.extend(edge for candidate in selected.values() for edge in candidate.get("dependencies", []))
        if not all(edge["name"] in selected and requirement_matches(
                edge["requirement"], selected[edge["name"]]["version"]) for edge in constraints):
            continue
        reachable = {edge["name"] for edge in roots}
        while True:
            expanded = reachable | {edge["name"] for name in reachable
                                     for edge in selected[name].get("dependencies", [])}
            if expanded == reachable:
                break
            reachable = expanded
        if reachable == set(selected):
            solutions.add(frozenset((name, candidate["version"]) for name, candidate in selected.items()))
    return sorted(solutions, key=lambda solution: sorted(solution))


def generated_graphs(seed=20261108, count=48):
    """Generate bounded cyclic and acyclic graphs with a repeatable random seed."""
    rng = random.Random(seed)
    requirements = ("*", "1.0.0", "2.0.0", "^1.0.0", ">=1.0.0,<3.0.0", ">1.0.0", "<2.0.0")
    for _ in range(count):
        names = ["fixture/" + chr(ord("a") + index) for index in range(rng.randint(2, 5))]
        candidates = []
        for name in names:
            for major in range(1, rng.randint(1, 3) + 1):
                targets = rng.sample(names, rng.randint(0, min(2, len(names))))
                candidates.append({"name": name, "version": f"{major}.0.0",
                    "dependencies": [{"name": other, "requirement": rng.choice(requirements)} for other in sorted(targets)],
                    "usable": rng.random() > 0.1})
        roots = [{"name": name, "requirement": rng.choice(requirements)}
                 for name in sorted(rng.sample(names, rng.randint(1, min(3, len(names)))))]
        yield candidates, roots


def exhaustive_feature_solutions(candidates, roots, *, features=None, requested=(), defaults=True):
    """Enumerate assignments, then derive a least fixed point with feature names.

    This deliberately uses sets and complete assignments rather than the native
    solver's masks, work state, partial assignments, or chronological search.
    """
    choices = defaultdict(list)
    for candidate in candidates:
        if candidate.get("usable", True):
            choices[candidate["name"]].append(candidate)
    names = sorted(choices)
    solutions = set()
    root = {"dependencies": roots, "features": features or {}}
    for selection in product(*[[None] + choices[name] for name in names]):
        selected = {name: candidate for name, candidate in zip(names, selection) if candidate is not None}
        active = defaultdict(set)
        active["$root"].update(requested)
        if defaults and "default" in root["features"]:
            active["$root"].add("default")
        reached, edges = set(), set()
        valid = True
        while True:
            before = (frozenset(reached), frozenset(edges),
                      frozenset((name, feature) for name, values in active.items() for feature in values))
            for name in ["$root", *sorted(reached)]:
                node = root if name == "$root" else selected[name]
                definitions = node.get("features", {})
                if not active[name].issubset(definitions):
                    valid = False
                    break
                activated = set()
                forwarded = defaultdict(set)
                for feature in tuple(active[name]):
                    for member in definitions[feature]:
                        if member.startswith("dep:"):
                            activated.add(member[4:])
                        elif member.count("/") == 2:
                            dep, child_feature = member.rsplit("/", 1)
                            activated.add(dep)
                            forwarded[dep].add(child_feature)
                        else:
                            active[name].add(member)
                for edge in node.get("dependencies", []):
                    child = edge["name"]
                    if edge.get("optional", False) and child not in activated and (name, child) not in edges:
                        continue
                    if child not in selected or not requirement_matches(edge["requirement"], selected[child]["version"]):
                        valid = False
                        break
                    reached.add(child)
                    edges.add((name, child))
                    active[child].update(edge.get("features", []))
                    active[child].update(forwarded[child])
                    if edge.get("default_features", True) and "default" in selected[child].get("features", {}):
                        active[child].add("default")
                if not valid:
                    break
            after = (frozenset(reached), frozenset(edges),
                     frozenset((name, feature) for name, values in active.items() for feature in values))
            if not valid or after == before:
                break
        if valid and reached == set(selected):
            solutions.add((frozenset((name, node["version"]) for name, node in selected.items()),
                           frozenset((name, feature) for name, values in active.items() for feature in values),
                           frozenset(edges)))
    return solutions


def generated_feature_graphs(seed=20261109, count=96):
    """Supply feature activation, optional cycles, and unavailable child features."""
    rng = random.Random(seed)
    for candidates, roots in generated_graphs(seed=seed, count=count):
        for node in candidates:
            for edge in node.get("dependencies", []):
                edge.update(optional=rng.random() < 0.5, default_features=rng.random() < 0.5,
                            features=["f0"] if rng.random() < 0.2 else [])
            members = []
            for edge in node.get("dependencies", []):
                if rng.random() < 0.5:
                    members.append(edge["name"] + "/f0")
                elif edge["optional"]:
                    members.append("dep:" + edge["name"])
            node["features"] = {"f0": members}
            if rng.random() < 0.6:
                node["features"]["default"] = ["f0"]
            if rng.random() < 0.2:
                node["features"].pop("f0")
                node["features"].pop("default", None)
        for edge in roots:
            edge.update(optional=rng.random() < 0.25, default_features=rng.random() < 0.5,
                        features=["f0"] if rng.random() < 0.4 else [])
        root_features = {"bundle": ["dep:" + edge["name"] for edge in roots if edge["optional"]]}
        yield candidates, roots, root_features, (["bundle"] if rng.random() < 0.5 else [])
