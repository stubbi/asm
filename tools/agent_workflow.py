"""Requirement and supplied-measurement checks for Asm developer tools.

These checks do not execute code or authenticate caller-supplied evidence.
"""

from __future__ import annotations

from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import statistics
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

ROOT = Path(__file__).resolve().parents[1]
Text = Annotated[str, StringConstraints(max_length=2048)]
Identifier = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_-]{0,63}$")]
SHA256 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
Commit = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40}$")]
Sample = Annotated[float, Field(ge=1e-6, le=1e18, allow_inf_nan=False)]
ByteCount = Annotated[int, Field(ge=0, le=2**50)]
Status = Literal["pass", "fail", "not-run", "unsupported", "error"]
# Recognized names are vocabulary, not a claim that a machine or package supports them.
KNOWN_CPU_FEATURES = {
    "x86_64": {"sse2", "sse3", "ssse3", "sse4.1", "sse4.2", "avx", "avx2", "fma", "bmi1", "bmi2", "aes", "sha", "avx512f"},
    "aarch64": {"neon", "asimd", "aes", "sha1", "sha2", "crc32", "lse", "atomics", "fp16", "dotprod", "sve", "sve2"},
    "riscv64": {"m", "a", "f", "d", "c", "v", "zba", "zbb", "zbs"},
}


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, validate_assignment=True,
                              validate_default=True, serialize_by_alias=True)


class Target(Model):
    target: Annotated[str, StringConstraints(max_length=64)]
    isa: Annotated[str, StringConstraints(max_length=64)]
    os: Annotated[str, StringConstraints(max_length=64)]
    abi: Annotated[str, StringConstraints(max_length=128)]
    minimum_os: Annotated[str, StringConstraints(max_length=128)]
    cpu_features: list[Annotated[str, StringConstraints(max_length=64)]] = Field(max_length=64)
    feature_qualification: Text = ""


class Acceptance(Model):
    id: Identifier
    scenario: Text
    expected: Text


class Budget(Model):
    max_iterations: int = Field(default=10, ge=1, le=100)
    max_seconds: int = Field(default=1800, ge=1, le=86400)
    plateau_iterations: int = Field(default=3, ge=1, le=20)


class ProjectRequirements(Model):
    schema_version: Literal[1] = Field(default=1, alias="schema")
    goal: Text = ""
    interface: Text = ""
    inputs: Text = ""
    outputs: Text = ""
    errors: Text = ""
    acceptance: list[Acceptance] = Field(default_factory=list, max_length=128)
    targets: list[Target] = Field(default_factory=list, max_length=4)
    primary_metric: Literal["", "latency", "throughput", "memory", "size"] = ""
    memory_limit_bytes: Annotated[int, Field(gt=0, le=2**50)] | None = None
    max_other_metric_regression_pct: float = Field(default=0, ge=0, le=100, allow_inf_nan=False)
    min_improvement_pct: float = Field(default=1, ge=0, le=100, allow_inf_nan=False)
    budget: Budget = Field(default_factory=Budget)


class BenchmarkContext(Model):
    requirements_sha256: SHA256
    target: Target
    workload: Annotated[str, StringConstraints(min_length=1, max_length=2048)]
    input_sha256: SHA256
    expected_output_sha256: SHA256
    hardware: Annotated[str, StringConstraints(min_length=1, max_length=2048)]
    toolchain: Annotated[str, StringConstraints(min_length=1, max_length=2048)]
    environment: Annotated[str, StringConstraints(min_length=1, max_length=2048)]
    execution: Literal["native", "emulated"]
    cache_state: Literal["cold", "warm"]
    warmups: int = Field(ge=0, le=10000)
    sample_count: int = Field(ge=5, le=1024)
    run_order: list[Identifier] = Field(min_length=10, max_length=20480)
    baseline_id: Identifier


class Candidate(Model):
    id: Identifier
    source_commit: Commit
    artifact_sha256: SHA256
    context_sha256: SHA256
    output_sha256: SHA256
    test_report_sha256: SHA256
    checks: dict[Identifier, Status] = Field(max_length=128)
    time_ns: list[Sample] = Field(min_length=1, max_length=1024)
    peak_memory_bytes: list[ByteCount] = Field(min_length=1, max_length=1024)
    executable_bytes: int = Field(gt=0, le=2**50)


def digest(value: BaseModel | dict) -> str:
    """Identify a schema-normalized input, including default policy values."""
    data = value.model_dump() if isinstance(value, BaseModel) else value
    return hashlib.sha256(json.dumps(data, sort_keys=True, separators=(",", ":"),
                                    ensure_ascii=True, allow_nan=False).encode()).hexdigest()


def list_targets() -> dict:
    result = json.loads((ROOT / "skills/asm-build/references/targets.json").read_text(encoding="utf-8"))
    for target in result["targets"]:
        target["recognized_optional_feature_names"] = sorted(KNOWN_CPU_FEATURES[target["isa"]])
    return result


def plan_project(requirements: ProjectRequirements) -> dict:
    questions = {
        "goal": "What user task must the software complete?",
        "interface": "What command or function interface must it expose?",
        "inputs": "Which inputs and bounds must it accept?",
        "outputs": "Which outputs and side effects must it produce?",
        "errors": "How must invalid inputs and system failures behave?",
        "acceptance": "Which observable cases define correct behavior?",
        "targets": "Which deployment ISA, OS, ABI, minimum OS, and CPU features are required?",
        "primary_metric": "Which metric has priority: latency, throughput, memory, or executable size?",
    }
    missing = [key for key in questions if not getattr(requirements, key)]
    conflicts = []
    catalog = {item["id"]: item for item in list_targets()["targets"]}
    seen = set()
    for target in requirements.targets:
        entry = catalog.get(target.target)
        if entry is None:
            conflicts.append(f"Unsupported target {target.target}. Use asm_list_targets for the current boundary.")
            continue
        if target.target in seen:
            conflicts.append(f"Duplicate target {target.target}. Give each target one explicit contract.")
        seen.add(target.target)
        for field in ("isa", "os", "abi"):
            if getattr(target, field) != entry[field]:
                conflicts.append(f"{target.target}: {field} must be {entry[field]} for this integration profile.")
        if not target.minimum_os.strip():
            conflicts.append(f"{target.target}: state the minimum OS or explicitly record it as unspecified.")
        if target.target == "aarch64-macos" and (not re.fullmatch(
                r"(?:0|[1-9][0-9]{0,3})(?:\.(?:0|[1-9][0-9]{0,3})){0,2}\+?", target.minimum_os)
                or int(target.minimum_os.rstrip("+").split(".")[0]) < 15):
            conflicts.append("aarch64-macos: declare a numeric minimum OS of 15.0 or later.")
        if any(not item.strip() for item in target.cpu_features) or len(set(target.cpu_features)) != len(target.cpu_features):
            conflicts.append(f"{target.target}: CPU features must be nonempty and unique.")
        if set(target.cpu_features) - KNOWN_CPU_FEATURES[entry["isa"]]:
            conflicts.append(f"{target.target}: an unknown or incompatible feature needs a reviewed target profile before planning.")
        if target.cpu_features and target.feature_qualification.strip().lower() in ("", "unknown", "unresolved", "tbd", "none"):
            conflicts.append(f"{target.target}: record CPU feature detection, fallback, and target tests before proceeding.")
    ids = [item.id for item in requirements.acceptance]
    if len(ids) != len(set(ids)):
        conflicts.append("Acceptance IDs must be unique. Preserve the independent behavioral contract.")
    if any(not item.scenario.strip() or not item.expected.strip() for item in requirements.acceptance):
        conflicts.append("Each acceptance case needs a scenario and an expected observable result.")
    for key in ("goal", "interface", "inputs", "outputs", "errors"):
        if getattr(requirements, key) and not getattr(requirements, key).strip() and key not in missing:
            missing.append(key)
    return {
        "schema": 1, "ready": not missing and not conflicts,
        "requirements_sha256": digest(requirements), "missing": missing,
        "questions": [questions[key] for key in missing], "conflicts": conflicts,
        "budget": requirements.budget.model_dump(),
        "next_steps": ["Inspect compatible exact-version packages and their licenses and evidence.",
                       "Build the simplest correct implementation and a credible comparison baseline.",
                       "Run every acceptance case through the intended interface.",
                       "Measure equal work on the declared target; retain failures and raw samples.",
                       "Iterate within the budget; stop at the budget or measured plateau."],
        "limits": ["Ready means the supplied planning fields are complete; it does not establish correctness.",
                   "The registry does not encode ABI revisions or optional CPU features.",
                   "No code was built, executed, or proved by this tool."],
    }


def compare_candidates(requirements: ProjectRequirements, context: BenchmarkContext,
                       candidates: list[Candidate]) -> dict:
    """Compare one declared workload; retain regressions and rejected reports."""
    result = {"schema": 1, "decision": "blocked", "selected": None,
              "evidence_origin": "supplied-not-reproduced", "context_sha256": digest(context),
              "candidates": [], "rejected": [], "pareto_frontier": [],
              "limits": ["not a proof of a global optimum", "Measurements and test reports were supplied, not executed or authenticated.",
                         "Medians and ranges are descriptive; no statistical significance claim is made.",
                         "This comparison covers only the declared workload, target, and environment."]}
    if context.execution == "emulated":
        result["limits"].append("Emulated measurements do not establish native hardware performance.")
    if not plan_project(requirements)["ready"]:
        result["rejected"].append({"id": "context", "reasons": ["Complete the requirements before comparison."]})
        return result
    ids = [item.id for item in candidates]
    context_reasons = []
    if not 2 <= len(candidates) <= 20 or len(set(ids)) != len(ids):
        context_reasons.append("Supply two through twenty candidates with unique IDs.")
    if context.requirements_sha256 != digest(requirements):
        context_reasons.append("The requirement digest changed. Re-run the acceptance and measurement jobs.")
    if context.target not in requirements.targets:
        context_reasons.append("The measured target does not match a declared target contract.")
    if Counter(context.run_order) != Counter({name: context.sample_count for name in ids}):
        context_reasons.append("The run order must cover every candidate's samples exactly.")
    if context.baseline_id not in ids:
        context_reasons.append("The declared baseline is missing.")
    if context_reasons:
        result["rejected"].append({"id": "context", "reasons": context_reasons})
        return result
    required_checks = {item.id for item in requirements.acceptance}
    for item in candidates:
        reasons = []
        if item.context_sha256 != digest(context):
            reasons.append("The measurement context differs. Re-run equal work under the same context.")
        if item.output_sha256 != context.expected_output_sha256:
            reasons.append("The output digest differs from the expected result.")
        if not required_checks <= set(item.checks) or any(value != "pass" for value in item.checks.values()):
            reasons.append("Every required acceptance case and additional reported check must pass.")
        if len(item.time_ns) != context.sample_count or len(item.peak_memory_bytes) != context.sample_count:
            reasons.append("The raw sample count does not match the measurement plan.")
        if any(value == "0" * len(value) for value in (item.source_commit, item.artifact_sha256, item.test_report_sha256)):
            reasons.append("Source, artifact, and report identities must not be all zeroes.")
        if requirements.memory_limit_bytes is not None and max(item.peak_memory_bytes) > requirements.memory_limit_bytes:
            reasons.append("Peak memory exceeds the required limit.")
        if reasons:
            result["rejected"].append({"id": item.id, "artifact_sha256": item.artifact_sha256, "reasons": reasons})
            continue
        result["candidates"].append({
            "id": item.id, "artifact_sha256": item.artifact_sha256, "source_commit": item.source_commit,
            "test_report_sha256": item.test_report_sha256,
            "median_time_ns": statistics.median(item.time_ns),
            "peak_memory_bytes": max(item.peak_memory_bytes), "executable_bytes": item.executable_bytes,
            "spread": {"time_ns": [min(item.time_ns), max(item.time_ns)],
                       "peak_memory_bytes": [min(item.peak_memory_bytes), max(item.peak_memory_bytes)]},
        })
    valid = result["candidates"]
    dimensions = ("median_time_ns", "peak_memory_bytes", "executable_bytes")
    result["pareto_frontier"] = [item["id"] for item in valid if not any(
        other is not item and all(other[key] <= item[key] for key in dimensions)
        and any(other[key] < item[key] for key in dimensions) for other in valid)]
    baseline = next((item for item in valid if item["id"] == context.baseline_id), None)
    if baseline is None:
        return result
    primary = {"latency": "median_time_ns", "throughput": "median_time_ns",
               "memory": "peak_memory_bytes", "size": "executable_bytes"}[requirements.primary_metric]
    # Time per identical fixed work is the inverse of throughput for that work.
    allowed = [item for item in valid if all(item[key] <= baseline[key] *
               (1 + requirements.max_other_metric_regression_pct / 100)
               for key in dimensions if key != primary)]
    best = min(allowed, key=lambda item: (item[primary],
               *(item[key] for key in dimensions if key != primary), item["id"]))
    denominator = baseline[primary]
    if requirements.primary_metric == "throughput":
        improvement = (denominator / best[primary] - 1) * 100
    else:
        improvement = (denominator - best[primary]) / denominator * 100 if denominator else 0
    selected = best if improvement > 0 and improvement >= requirements.min_improvement_pct else baseline
    result["selected"] = selected["id"]
    result["improvement_pct"] = improvement if selected is best else 0
    result["decision"] = "candidate" if selected is not baseline else (
        "tradeoff" if any(item[primary] < baseline[primary] for item in valid) else "retain-baseline")
    result["stop_policy"] = requirements.budget.model_dump()
    return result
