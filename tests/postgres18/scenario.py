"""Run the real qualification control flow against a local Docker test double.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import test_postgres18_image as harness


def run(mode):
    declaration = harness.fixture.prepare(harness.fixture.PREPARATION, "a" * 40)
    schema = ROOT / "server/catalog/schema.sql"
    Path("server/catalog").mkdir(parents=True)
    Path("server/catalog/schema.sql").write_bytes(schema.read_bytes())
    migration = hashlib.sha384(schema.read_bytes()).hexdigest()
    base = {"Id": harness.fixture.CONFIG, "Architecture": "amd64", "Os": "linux", "Config": {"User": "26"},
            "RootFS": {"Layers": ["base"]}, "RepoDigests": [harness.fixture.DATABASE_IMAGE]}
    sidecar = {"Id": "sha256:" + "4" * 64, "Architecture": "amd64", "Os": "linux", "Config": {"User": "26:26"},
               "RootFS": {"Layers": ["base", "fixture"]}}
    images = {harness.fixture.DATABASE_IMAGE: base, harness.DATABASE: sidecar}
    for suite, names in harness.IMAGES.items():
        image = {"Id": "sha256:" + ("5" if suite == "operator" else "6") * 64, "Architecture": "amd64", "Os": "linux",
                 "RootFS": {"Layers": ["application"]}, "Config": {"User": "65532:65532",
                 "Entrypoint": harness.operator.ENTRYPOINT if suite == "operator" else ["/usr/local/bin/asm-hub"],
                 "Cmd": ["--help"] if suite == "operator" else ["serve"],
                 "Labels": {"org.opencontainers.image.revision": "a" * 40}}}
        for name, layers in zip(names, ([], ["original-tests"], ["original-tests", "pg18-tests"])):
            images[name] = copy.deepcopy(image)
            images[name]["RootFS"]["Layers"] += layers
    containers, removed = {}, []

    def docker(arguments, **options):
        if arguments[0] != "docker":
            raise AssertionError("Unexpected test executable.")
        operation = arguments[1]
        if operation == "info":
            body = b"linux/amd64\n"
        elif operation == "image":
            body = json.dumps([images[arguments[-1]]]).encode()
        elif operation == "create":
            identity = f"{len(containers) + 1:064x}"
            user = arguments[arguments.index("--user") + 1]
            name = arguments[arguments.index("--name") + 1]
            executable = arguments[arguments.index("--entrypoint") + 1] if "--entrypoint" in arguments else None
            value = {"Id": identity, "Name": "/" + name, "Image": next(value for value in arguments if value.startswith("sha256:")),
                     "Config": {"User": user, "Labels": {"asm.qualification.nonce": declaration["nonce"]}},
                     "HostConfig": {"ReadonlyRootfs": True, "NetworkMode": arguments[arguments.index("--network") + 1],
                         "PortBindings": {}, "CapDrop": ["ALL"], "CapAdd": None, "SecurityOpt": ["no-new-privileges"],
                         "Privileged": False, "PidsLimit": 128, "Memory": 2147483648 if user == "26:26" else 536870912,
                         "NanoCpus": 2000000000}, "Mounts": [], "State": {"Running": True},
                     "probe": arguments[-1] if executable == "/bin/cat" else None,
                     "suite": arguments[arguments.index("--suite") + 1] if "--suite" in arguments else None}
            containers[identity] = value
            body = identity.encode()
        elif operation == "container":
            body = json.dumps([containers[arguments[-1]]]).encode()
        elif operation == "start":
            value = containers[arguments[-1]]
            if value["probe"]:
                if mode == "terminate":
                    os.kill(os.getpid(), signal.SIGTERM)
                body = (Path(".postgres18-fixture/server") / Path(value["probe"]).name).read_bytes()
            elif value["suite"]:
                suite = value["suite"]
                database_id = value["HostConfig"]["NetworkMode"].split(":", 1)[1]
                report = {"schema": 1, "status": "pass", "scope": "selected-cnpg18-compatibility", "suite": suite,
                          "source_revision": "a" * 40, "tests_run": 23 if suite == "operator" else 16, "not_applicable": [],
                          "applicable_tests_skipped": 0, "client_libpq_version": 160015, "migration_sha384": migration,
                          "database": {"server_version_num": 180006, "data_directory": harness.fixture.DATA,
                              "nonce": declaration["nonce"], "system_identifier": str(7452238960987612345 + int(database_id, 16)),
                              "session_user": "asm_fixture_admin", "tls_protocol": "TLSv1.3"}}
                body = (harness.PREFIX + json.dumps(report) + "\n").encode()
            else:
                body = b""
        elif operation == "exec":
            body = b"accepting connections\n"
        elif operation == "logs":
            return SimpleNamespace(returncode=1 if mode == "logs-fail" else 0, stdout=b"", stderr=b"controlled database log result\n")
        elif operation == "rm":
            removed.append(arguments[-1])
            body = b""
        else:
            raise AssertionError("Unexpected Docker operation: " + operation)
        return SimpleNamespace(returncode=0, stdout=body, stderr=b"")

    try:
        with patch.object(harness.platform, "system", return_value="Linux"), \
                patch.object(harness.platform, "machine", return_value="x86_64"), \
                patch.object(harness, "command", side_effect=docker), \
                patch.object(harness, "database_files", return_value={"postgres": "a" * 64}), \
                patch.object(harness.operator, "runtime_files", return_value={"psql": "b" * 64}), \
                patch.object(harness.server, "runtime_files", return_value={"asm-hub": "c" * 64}):
            harness.qualify(SimpleNamespace(revision="a" * 40, output="evidence"))
    except ValueError:
        return 1
    finally:
        Path("scenario-resources.json").write_text(json.dumps({"created": list(containers), "removed": removed}))
    return 0


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1]))
