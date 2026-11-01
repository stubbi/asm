#!/usr/bin/env python3
"""Compare native registry clients on deterministic local catalog workloads."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import time


FIELDS = ("package", "version", "target", "kind", "sha256", "url", "bytes", "summary")
MACHINES = {"x86_64": 62, "aarch64": 183, "riscv64": 243}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def bounded_integer(value):
    result = int(value)
    if not 1 <= result <= 1000:
        raise argparse.ArgumentTypeError("Use an integer from 1 through 1000.")
    return result


def native_binary(path):
    path = path.resolve(strict=True)
    data = path.read_bytes()
    expected = MACHINES.get(platform.machine())
    if (expected is None or len(data) < 64 or data[:6] != b"\x7fELF\x02\x01"
            or int.from_bytes(data[18:20], "little") != expected):
        raise ValueError(f"{path} must be a native, little-endian ELF64 executable for this host.")
    if not os.access(path, os.X_OK):
        raise ValueError(f"{path} is not executable.")
    return path, {"path": str(path), "bytes": len(data), "sha256": sha256(data)}


def fixtures(directory):
    cases = []
    for count in (6, 256, 4096):
        rows = [dict(package=f"bench/package-{number:04d}", version="0.1.0",
                     target="x86_64-linux", kind="source", sha256="1" * 64,
                     url="https://github.com/stubbi/asm/releases/download/v0.1.0/package.tar.gz",
                     bytes=128, summary='Small "quoted" assembly \\ example'
                     if number % 17 == 0 else "Small assembly example") for number in range(count)]
        text = "".join("\t".join(str(row[key]) for key in FIELDS) + "\n" for row in rows).encode()
        index = b"# asm-registry-v1\n" + text
        if len(index) > 1048576:
            raise ValueError("A fixture exceeds the registry size limit.")
        path = directory / f"index-{count}.tsv"
        path.write_bytes(index)
        for mode in ("text", "json", "no-match"):
            arguments = ["search"]
            if mode == "json":
                arguments += ["--json"]
                expected = json.dumps({"results": rows}, separators=(",", ":")).encode() + b"\n"
            elif mode == "no-match":
                arguments += ["absent-token"]
                expected = b"No matching packages.\n"
            else:
                expected = text
            arguments += ["--index", str(path)]
            cases.append((f"search-{count}-{mode}", arguments, expected, {
                "rows": count, "mode": mode, "index_bytes": len(index),
                "index_sha256": sha256(index), "output_bytes": len(expected),
                "output_sha256": sha256(expected),
            }))
    return cases


def summary(values):
    ordered = sorted(values)
    return {"median_ms": statistics.median(ordered) / 1e6,
            "minimum_ms": ordered[0] / 1e6, "maximum_ms": ordered[-1] / 1e6,
            "p95_nearest_rank_ms": ordered[(95 * len(ordered) + 99) // 100 - 1] / 1e6}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--baseline-source", required=True, help="Exact source commit or recorded source-manifest digest")
    parser.add_argument("--candidate-source", required=True, help="Exact source commit or recorded source-manifest digest")
    parser.add_argument("--output", type=Path, required=True, help="A new directory; existing evidence is never overwritten")
    parser.add_argument("--samples", type=bounded_integer, default=31)
    parser.add_argument("--warmups", type=bounded_integer, default=3)
    parser.add_argument("--seed", type=int, default=918261)
    parser.add_argument("--strace", action="store_true", help="Collect separate syscall counts after all timing samples")
    options = parser.parse_args()
    binaries = {}
    identities = {}
    for name in ("baseline", "candidate"):
        binaries[name], identities[name] = native_binary(getattr(options, name))
        identities[name]["source"] = getattr(options, f"{name}_source")
    output = options.output.resolve()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    affinity = sorted(os.sched_getaffinity(0))
    report = {
        "schema": "asm-registry-benchmark-v1", "started_at": datetime.now(timezone.utc).isoformat(),
        "benchmark_sha256": sha256(Path(__file__).read_bytes()),
        "binaries": identities, "platform": platform.platform(),
        "kernel": {key: getattr(platform.uname(), key) for key in ("system", "release", "version", "machine")},
        "available_affinity": affinity, "pinned_cpu": affinity[0],
        "samples_per_binary_and_workload": options.samples, "warmups": options.warmups,
        "seed": options.seed, "samples": [], "workloads": {}, "syscall_counts": {},
        "measurement": "perf_counter_ns around subprocess.run with both output streams captured; includes process launch and output capture",
        "order": "Each round shuffles the workloads and randomly chooses baseline/candidate order within each pair.",
        "cache": "Warm filesystem cache after warmups. No eviction, network, transport, digest, or signature work is measured.",
        "limitations": ["One native host; no cross-architecture comparison", "Host scheduling and other work can affect elapsed time", "Local catalog search does not represent network installation or whole-application performance"],
    }
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
    try:
        os.sched_setaffinity(0, {affinity[0]})
        try:
            lines = Path("/proc/cpuinfo").read_text().splitlines()
            report["cpu_model"] = next((line.split(":", 1)[1].strip() for line in lines
                                        if line.startswith(("model name", "Hardware"))), "Not reported")
        except OSError as error:
            report["cpu_model"] = f"Unavailable: {error}"
        report["tools"] = {tool: subprocess.check_output([tool, "--version"], text=True).splitlines()[0]
                           for tool in ("as", "ld", "python3")}
        if shutil.which("dpkg-query"):
            packages = subprocess.run(["dpkg-query", "-W", "-f=${binary:Package}\t${Version}\n",
                                       "binutils", "binutils-x86-64-linux-gnu"],
                                      capture_output=True, text=True, timeout=5)
            report["tool_packages"] = {"exit_code": packages.returncode,
                                       "stdout": packages.stdout, "stderr": packages.stderr}
        cases = fixtures(output)
        for name, arguments, _, metadata in cases:
            report["workloads"][name] = {**metadata, "arguments": arguments}

        def measure(binary, case):
            name, arguments, expected, _ = case
            start = time.perf_counter_ns()
            result = subprocess.run([str(binaries[binary]), *arguments], cwd=output,
                                    capture_output=True, timeout=15, env=environment)
            elapsed = time.perf_counter_ns() - start
            if result.returncode != 0 or result.stderr or result.stdout != expected:
                raise ValueError(f"{binary}/{name}: result differs: exit={result.returncode}, "
                                 f"stdout_sha256={sha256(result.stdout)}, stderr={result.stderr!r}")
            return elapsed

        for case in cases:
            for _ in range(options.warmups):
                for binary in binaries:
                    measure(binary, case)
        generator = random.Random(options.seed)
        for round_number in range(options.samples):
            ordered_cases = cases.copy()
            generator.shuffle(ordered_cases)
            for case in ordered_cases:
                ordered_binaries = list(binaries)
                generator.shuffle(ordered_binaries)
                for binary in ordered_binaries:
                    report["samples"].append({"sequence": len(report["samples"]), "round": round_number,
                                              "workload": case[0], "binary": binary,
                                              "elapsed_ns": measure(binary, case)})
        for name, metadata in report["workloads"].items():
            for binary in binaries:
                values = [sample["elapsed_ns"] for sample in report["samples"]
                          if sample["workload"] == name and sample["binary"] == binary]
                metadata[binary] = summary(values)
            metadata["median_speedup"] = metadata["baseline"]["median_ms"] / metadata["candidate"]["median_ms"]
        print("Timed samples complete; any syscall counts run separately.", flush=True)
        if options.strace:
            tracer = shutil.which("strace")
            if tracer is None:
                raise ValueError("--strace requires strace on PATH.")
            for case in (cases[0], cases[1], cases[6], cases[7], cases[8]):
                name, arguments, expected, _ = case
                for binary in binaries:
                    path = output / f"{binary}-{name}-strace.txt"
                    run = subprocess.run([tracer, "-c", "-qq", "-o", str(path), "--",
                                          str(binaries[binary]), *arguments], cwd=output,
                                         capture_output=True, timeout=60, env=environment)
                    text = path.read_text() if path.exists() else ""
                    report["syscall_counts"][f"{binary}/{name}"] = {
                        "exit_code": run.returncode, "stderr": run.stderr.decode(),
                        "output_matches": run.stdout == expected, "trace": text,
                    }
                    if run.returncode != 0 or run.stderr or run.stdout != expected:
                        raise ValueError(f"The separate strace check failed for {binary}/{name}.")
        report["status"] = "pass"
    except BaseException as error:
        report["status"] = "fail"
        report["error"] = repr(error)
        raise
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        with (output / "results.json").open("x") as destination:
            json.dump(report, destination, indent=2)
            destination.write("\n")
        os.sched_setaffinity(0, affinity)
    for name, metadata in report["workloads"].items():
        print(f"{name}: {metadata['baseline']['median_ms']:.3f} ms -> "
              f"{metadata['candidate']['median_ms']:.3f} ms; "
              f"{metadata['median_speedup']:.2f}x")
    print(f"Raw evidence: {output / 'results.json'}")


if __name__ == "__main__":
    main()
