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
