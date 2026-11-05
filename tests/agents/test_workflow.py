"""Observable requirements and measurement gates for the agent adapter."""

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import agent_workflow as workflow


def requirements():
    return workflow.ProjectRequirements.model_validate({
        "goal": "Return the smaller unsigned 64-bit value.",
        "interface": "System V AMD64 function min_u64(rdi, rsi), result rax.",
        "inputs": "Two unsigned 64-bit integers.",
        "outputs": "The smaller integer; equal inputs return the same value.",
        "errors": "All bit patterns are valid; no allocation or I/O.",
        "acceptance": [{"id": "values", "scenario": "zero, equal, high bit, maximum", "expected": "unsigned minimum"}],
        "targets": [{"target": "x86_64-linux", "isa": "x86_64", "os": "linux",
                     "abi": "System V AMD64", "minimum_os": "deployment baseline not specified",
                     "cpu_features": []}],
        "primary_metric": "latency", "memory_limit_bytes": 4096,
        "budget": {"max_iterations": 8, "max_seconds": 300, "plateau_iterations": 3},
    })


def benchmark(spec):
    return workflow.BenchmarkContext.model_validate({
        "requirements_sha256": workflow.digest(spec), "target": spec.targets[0].model_dump(),
        "workload": "min_u64 over one fixed input vector",
        "input_sha256": "1" * 64, "expected_output_sha256": "2" * 64,
        "hardware": "test fixture, no physical measurement claim",
        "toolchain": "fixture assembler 1, linker 1; no optimization flags",
        "environment": "fixture kernel 1; one pinned core; performance governor",
        "execution": "native", "cache_state": "warm", "warmups": 2,
        "sample_count": 5, "run_order": ["baseline", "candidate"] * 5,
        "baseline_id": "baseline",
    })


def candidate(context, name, time, memory=1024, size=64):
    return workflow.Candidate.model_validate({
        "id": name, "source_commit": "a" * 40, "artifact_sha256": ("b" if name == "baseline" else "c") * 64,
        "context_sha256": workflow.digest(context), "output_sha256": "2" * 64,
        "test_report_sha256": "d" * 64, "checks": {"values": "pass"},
        "time_ns": [time + n for n in range(5)], "peak_memory_bytes": [memory] * 5,
        "executable_bytes": size,
    })


class WorkflowTests(unittest.TestCase):
    def test_incomplete_task_reports_questions_without_ready_claim(self):
        result = workflow.plan_project(workflow.ProjectRequirements())
        self.assertFalse(result["ready"])
        self.assertIn("targets", result["missing"])
        self.assertIn("acceptance", result["missing"])

    def test_complete_target_has_distinct_dimensions(self):
        spec = requirements()
        result = workflow.plan_project(spec)
        self.assertTrue(result["ready"], result)
        self.assertEqual(result["requirements_sha256"], workflow.digest(spec))

    def test_requirement_digest_survives_json_transport(self):
        spec = requirements()
        decoded = workflow.ProjectRequirements.model_validate_json(spec.model_dump_json())
        self.assertEqual(workflow.digest(spec), workflow.digest(decoded))

    def test_wrong_abi_and_unsupported_target_block_the_plan(self):
        for field, value in [("abi", "Windows x64"), ("target", "x86_64-freebsd"), ("os", "macos"), ("isa", "made-up")]:
            with self.subTest(field=field):
                spec = requirements()
                setattr(spec.targets[0], field, value)
                result = workflow.plan_project(spec)
                self.assertFalse(result["ready"])
                self.assertTrue(result["conflicts"])

    def test_windows_planning_profiles_do_not_declare_published_cli_support(self):
        profiles = {item["id"]: item for item in workflow.list_targets()["targets"]}
        for target, isa, abi in (("x86_64-windows", "x86_64", "Microsoft x64"),
                                 ("aarch64-windows", "aarch64", "Microsoft ARM64")):
            with self.subTest(target=target):
                spec = requirements()
                spec.targets[0] = workflow.Target(target=target, isa=isa, os="windows", abi=abi,
                    minimum_os="Not established; qualify the deployment host", cpu_features=[])
                self.assertTrue(workflow.plan_project(spec)["ready"])
                self.assertFalse(profiles[target]["native_cli"])
                spec.targets[0].abi = "System V AMD64"
                self.assertFalse(workflow.plan_project(spec)["ready"])

    def test_optional_cpu_features_require_an_explicit_qualification(self):
        spec = requirements()
        spec.targets[0].cpu_features = ["avx2"]
        result = workflow.plan_project(spec)
        self.assertFalse(result["ready"])
        spec.targets[0].feature_qualification = "CPUID gate, scalar fallback, native AVX2 acceptance job"
        self.assertTrue(workflow.plan_project(spec)["ready"])

    def test_unknown_or_wrong_architecture_features_block_readiness(self):
        for feature, qualification in [("unknown", "unknown"), ("neon", "CPUID check"), ("avx2", "unresolved")]:
            with self.subTest(feature=feature, qualification=qualification):
                spec = requirements()
                spec.targets[0].cpu_features = [feature]
                spec.targets[0].feature_qualification = qualification
                self.assertFalse(workflow.plan_project(spec)["ready"])

    def test_higher_macos_deployment_minimum_is_preserved(self):
        spec = requirements()
        spec.targets[0] = workflow.Target(target="aarch64-macos", isa="aarch64", os="macos", abi="Apple arm64",
            minimum_os="16.0", cpu_features=[])
        self.assertTrue(workflow.plan_project(spec)["ready"])
        spec.targets[0].minimum_os = "14.9"
        self.assertFalse(workflow.plan_project(spec)["ready"])

    def test_faster_equal_work_can_be_selected_from_supplied_measurements(self):
        spec = requirements()
        context = benchmark(spec)
        result = workflow.compare_candidates(spec, context, [candidate(context, "baseline", 100), candidate(context, "candidate", 80)])
        self.assertEqual(result["selected"], "candidate")
        self.assertEqual(result["evidence_origin"], "supplied-not-reproduced")
        self.assertIn("not a proof of a global optimum", result["limits"])
        self.assertIn("spread", result["candidates"][0])

    def test_failed_check_or_changed_output_cannot_win(self):
        for field, value in [("checks", {"values": "fail"}), ("checks", {}), ("output_sha256", "9" * 64)]:
            with self.subTest(field=field):
                spec = requirements()
                context = benchmark(spec)
                fast = candidate(context, "candidate", 1)
                setattr(fast, field, value)
                result = workflow.compare_candidates(spec, context, [candidate(context, "baseline", 100), fast])
                self.assertEqual(result["selected"], "baseline")
                self.assertTrue(result["rejected"])

    def test_context_or_requirements_change_blocks_comparison(self):
        spec = requirements()
        context = benchmark(spec)
        runs = [candidate(context, "baseline", 100), candidate(context, "candidate", 80)]
        context.hardware = "another CPU"
        result = workflow.compare_candidates(spec, context, runs)
        self.assertIsNone(result["selected"])
        self.assertTrue(result["rejected"])
        spec.errors = "changed behavior"
        result = workflow.compare_candidates(spec, context, runs)
        self.assertEqual(result["decision"], "blocked")

    def test_memory_regression_retains_both_pareto_candidates(self):
        spec = requirements()
        context = benchmark(spec)
        result = workflow.compare_candidates(spec, context, [candidate(context, "baseline", 100), candidate(context, "candidate", 80, memory=2048)])
        self.assertEqual(result["selected"], "baseline")
        self.assertEqual(set(result["pareto_frontier"]), {"baseline", "candidate"})
        self.assertEqual(result["decision"], "tradeoff")

    def test_memory_limit_and_incomplete_samples_reject_candidates(self):
        spec = requirements()
        context = benchmark(spec)
        fast = candidate(context, "candidate", 80, memory=8192)
        result = workflow.compare_candidates(spec, context, [candidate(context, "baseline", 100), fast])
        self.assertTrue(result["rejected"])
        fast = candidate(context, "candidate", 80)
        fast.time_ns = [1]
        result = workflow.compare_candidates(spec, context, [candidate(context, "baseline", 100), fast])
        self.assertEqual(result["selected"], "baseline")

    def test_run_order_must_cover_every_sample(self):
        spec = requirements()
        context = benchmark(spec)
        context.run_order = ["baseline"] * 10
        result = workflow.compare_candidates(spec, context, [candidate(context, "baseline", 100), candidate(context, "candidate", 80)])
        self.assertEqual(result["decision"], "blocked")

    def test_throughput_improvement_uses_reciprocal_elapsed_time(self):
        spec = requirements()
        spec.primary_metric = "throughput"
        spec.min_improvement_pct = 22
        context = benchmark(spec)
        result = workflow.compare_candidates(spec, context, [candidate(context, "baseline", 100), candidate(context, "candidate", 80)])
        self.assertEqual(result["selected"], "candidate")
        self.assertAlmostEqual(result["improvement_pct"], (102 / 82 - 1) * 100)

    def test_primary_metric_tie_never_selects_a_dominated_candidate(self):
        spec = requirements()
        context = benchmark(spec)
        context.run_order = ["baseline", "alpha", "zulu"] * 5
        result = workflow.compare_candidates(spec, context, [candidate(context, "baseline", 100, 2048, 128),
            candidate(context, "alpha", 80, 1024, 64), candidate(context, "zulu", 80, 512, 32)])
        self.assertEqual(result["selected"], "zulu")
        self.assertEqual(result["pareto_frontier"], ["zulu"])

    def test_nonfinite_and_unknown_fields_are_rejected(self):
        from pydantic import ValidationError
        with self.assertRaises(ValidationError):
            workflow.ProjectRequirements.model_validate({"silent_override": True})
        spec = requirements()
        context = benchmark(spec)
        raw = candidate(context, "candidate", 10).model_dump()
        raw["time_ns"] = [float("nan")] * 5
        with self.assertRaises(ValidationError):
            workflow.Candidate.model_validate(raw)
        raw["time_ns"] = [5e-324] * 5
        with self.assertRaises(ValidationError):
            workflow.Candidate.model_validate(raw)


if __name__ == "__main__":
    unittest.main()
