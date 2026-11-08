"""Private operator coordination tests; HTTP application logic stays assembly.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import importlib
import copy
import os
import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry
import publication_check
import test_checker as checker_fixtures


class PublicationWorkerTests(unittest.TestCase):
    def setUp(self):
        self.fixture = checker_fixtures.PublicationCheckerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.module = importlib.import_module("publication_worker")
        self.worker = "3" * 32
        self.lease = {"task_id": self.fixture.task, "fence": 1,
            "manifest": self.fixture.manifest_file.read_text(),
            "manifest_sha256": hashlib.sha256(self.fixture.manifest_file.read_bytes()).hexdigest(),
            "objects": [{"sha256": self.fixture.digest, "bytes": len(self.fixture.data)}]}
        self.commands = []
        self.retained = []

    def connection(self):
        outer = self
        class Connection:
            def execute(self, sql):
                outer.commands.append(sql)
                if "claim_check(" in sql:
                    return registry.json_bytes(outer.lease).decode() + "\n"
                if "complete_check(" in sql:
                    return registry.json_bytes({"schema": 2, "id": outer.fixture.task, "state": "committed"}).decode() + "\n"
                raise AssertionError("unexpected SQL")
        return Connection()

    def store(self):
        outer = self
        class Store:
            def put_blob(self, path, digest, size):
                outer.retained.append((digest, size, Path(path).read_bytes()))
            def create_object(self, key, data):
                outer.retained.append((key, data))
        return Store()

    def checker(self, task, manifest, objects):
        self.assertFalse(any("complete_check(" in sql for sql in self.commands))
        return publication_check.check(task, manifest, objects, self.fixture.revision)

    def run_one(self, checker=None, store=None):
        return self.module.run_one(self.connection(), store or self.store(), self.fixture.objects,
            self.worker, checker or self.checker)

    def test_retained_objects_and_manifest_precede_the_immutable_intent(self):
        result = self.run_one()
        self.assertEqual(result["state"], "committed")
        self.assertEqual(self.retained[0], (self.fixture.digest, len(self.fixture.data), self.fixture.data))
        self.assertEqual(self.retained[1], ("publications/v2/intents/" + self.lease["manifest_sha256"] + ".json",
                                           self.fixture.manifest_file.read_bytes()))
        self.assertIn("complete_check(", self.commands[-1])
        self.assertEqual(self.fixture.object_file.read_bytes(), self.fixture.data)

    def test_no_pending_work_is_quiet_and_touches_no_files(self):
        self.lease = None
        self.assertIsNone(self.run_one())
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(self.retained, [])

    def test_checker_receives_only_private_copies_of_the_leased_task(self):
        unrelated = self.fixture.objects / ("9" * 32 + "-" + "f" * 64)
        unrelated.write_bytes(b"Private bytes from another owner's unfinished task.")
        unrelated.chmod(0o600)
        def checker(task, manifest, objects):
            self.assertNotEqual(objects, self.fixture.objects)
            self.assertEqual([path.name for path in objects.iterdir()], [self.fixture.object_file.name])
            self.assertEqual(objects.stat().st_mode & 0o777, 0o700)
            self.assertEqual((objects / self.fixture.object_file.name).stat().st_nlink, 1)
            return self.checker(task, manifest, objects)
        self.run_one(checker=checker)
        self.assertEqual(unrelated.read_bytes(), b"Private bytes from another owner's unfinished task.")

    def test_store_failure_never_commits_and_preserves_staged_bytes(self):
        store = self.store()
        with patch.object(store, "put_blob", side_effect=registry.RegistryError("storage failure")):
            with self.assertRaises(registry.RegistryError):
                self.run_one(store=store)
        self.assertFalse(any("complete_check(" in sql for sql in self.commands))
        self.assertEqual(self.fixture.object_file.read_bytes(), self.fixture.data)

    def test_uncertain_checker_preserves_private_task_view_and_fencing(self):
        views = []
        def checker(task, manifest, objects):
            views.append(manifest.parent)
            raise registry.RegistryError("remote completion is unknown")
        work = self.fixture.root / "work"
        work.mkdir(mode=0o700)
        with self.assertRaises(registry.RegistryError):
            self.module.run_one(self.connection(), self.store(), self.fixture.objects,
                self.worker, checker, work_root=work)
        self.assertTrue(views[0].is_dir())
        self.assertEqual((views[0] / "objects" / self.fixture.object_file.name).read_bytes(), self.fixture.data)
        self.assertEqual(self.retained, [])
        self.assertEqual(len(self.commands), 1)

    def test_failed_or_unavailable_check_records_no_retained_release(self):
        for outcome in ("fail", "error"):
            self.commands.clear()
            def checker(*args):
                receipt = self.checker(*args)
                receipt["outcome"] = receipt["objects"][0]["outcome"] = outcome
                return receipt
            self.run_one(checker=checker)
            self.assertEqual(self.retained, [])
            self.assertIn("complete_check(", self.commands[-1])

    def test_substituted_lease_or_receipt_never_reaches_storage_or_commit(self):
        self.lease["manifest_sha256"] = "0" * 64
        with self.assertRaises(registry.RegistryError):
            self.run_one()
        self.assertEqual(self.retained, [])
        self.assertEqual(len(self.commands), 1)

    def test_isolated_checker_uses_fixed_readonly_mounts_and_no_network_or_credentials(self):
        image = "asm-checker@sha256:" + "a" * 64
        view = self.fixture.manifest_file.parent / "objects"
        args = self.module.container_arguments("/usr/bin/docker", "/private/docker.sock", image,
            "asm-check-" + "b" * 32, Path("/private/empty-config"),
            self.fixture.task, self.fixture.manifest_file, view, self.fixture.revision)
        self.assertIn("--network=none", args)
        self.assertIn("--read-only", args)
        self.assertIn("--cap-drop=ALL", args)
        self.assertIn("--security-opt=no-new-privileges", args)
        self.assertIn("--pull=never", args)
        mounts = [args[i + 1] for i, value in enumerate(args[:-1]) if value == "--mount"]
        self.assertEqual(len(mounts), 4)
        self.assertTrue(all(value.endswith(",readonly") for value in mounts))
        self.assertFalse(any("credentials" in value or "docker.sock" in value for value in mounts))
        self.assertEqual(args[-2:], ["--checker-revision", self.fixture.revision])
        offline = self.module.container_arguments("/usr/bin/docker", "/private/docker.sock", "sha256:" + "a" * 64,
            "asm-check-" + "b" * 32, Path("/private/empty-config"), self.fixture.task,
            self.fixture.manifest_file, view, self.fixture.revision)
        self.assertIn("sha256:" + "a" * 64, offline)
        with self.assertRaises(registry.RegistryError):
            self.module.container_arguments("/usr/bin/docker", "/private/docker.sock", "asm-checker:latest",
                "asm-check-" + "b" * 32, Path("/private/empty-config"), self.fixture.task,
                self.fixture.manifest_file, view, self.fixture.revision)

    def test_image_declared_writable_volumes_are_refused_before_a_job_runs(self):
        checker = self.module.isolated_checker("/usr/bin/docker", "/private/docker.sock",
            "sha256:" + "a" * 64, self.fixture.revision)
        with patch.object(self.module.registry_admin, "run_bounded", return_value=b'{"/unbounded":{}}\n') as run:
            with self.assertRaises(registry.RegistryError):
                checker(self.fixture.task, self.fixture.manifest_file, self.fixture.root / "objects")
        self.assertFalse(any("run" in call.args[0][5:6] for call in run.call_args_list))

    def test_image_worker_refuses_caller_selected_tools_and_revision(self):
        fixed = {"psql": "/opt/asm/postgres/bin/psql", "kubectl": "/usr/bin/kubectl"}
        for flag in ("--psql", "--docker", "--kubectl", "--checker-revision", "--executor"):
            with self.subTest(flag=flag), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
                self.module.main([flag, "attacker"], fixed_tools=fixed, checker_revision="a" * 40)
            self.assertEqual(result.exception.code, 2)

    def test_trusted_kubernetes_selection_keeps_run_one_injection(self):
        fixed = {"psql": "/opt/asm/postgres/bin/psql", "kubectl": "/usr/bin/kubectl"}
        arguments = ["--connection-file", str(self.fixture.root / "db"), "--staging", str(self.fixture.objects),
            "--work-root", str(self.fixture.root), "--worker-id", self.worker, "--checker-image", "fixture@sha256:" + "c" * 64,
            "--kubeconfig", str(self.fixture.root / "kubeconfig"), "--checker-namespace", "asm-checks",
            "--checker-claim", "asm-check-inputs", "--checker-node", "worker-1", "--checker-runtime", "gvisor",
            "--store", "local", "--root", str(self.fixture.root / "retained")]
        class Connection:
            def __init__(inner, path, executable, role):
                self.assertEqual(executable, fixed["psql"])
            def __enter__(inner):
                return self.connection()
            def __exit__(inner, *args):
                return False
        import kubernetes_checker
        with patch.object(kubernetes_checker, "kubernetes_checker", return_value=self.checker) as factory, \
                patch.object(self.module.registry_admin, "Connection", Connection), \
                patch.object(self.module.registry_mirror, "_store", return_value=self.store()):
            self.lease = None
            self.assertEqual(self.module.main(arguments, fixed_tools=fixed, checker_revision="a" * 40), 0)
        self.assertEqual(factory.call_args.args[:4], (fixed["kubectl"], self.fixture.root / "kubeconfig",
            "fixture@sha256:" + "c" * 64, "a" * 40))
        self.assertEqual(len(self.commands), 1)

    def test_unavailable_kubernetes_configuration_returns_failure_without_claiming(self):
        arguments = ["--connection-file", str(self.fixture.root / "db"), "--staging", str(self.fixture.objects),
            "--work-root", str(self.fixture.root), "--worker-id", self.worker, "--checker-image", "fixture@sha256:" + "c" * 64,
            "--kubeconfig", str(self.fixture.root / "absent"), "--checker-namespace", "asm-checks",
            "--checker-claim", "asm-check-inputs", "--checker-node", "worker-1", "--checker-runtime", "gvisor",
            "--store", "local", "--root", str(self.fixture.root / "retained")]
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            result = self.module.main(arguments, fixed_tools={"psql": "/fixed/psql", "kubectl": "/fixed/kubectl"},
                                      checker_revision="a" * 40)
        self.assertEqual(result, 1)
        self.assertIn("Inspect the task before retrying", errors.getvalue())
        self.assertEqual(self.commands, [])


class KubernetesCheckerTests(unittest.TestCase):
    def setUp(self):
        self.fixture = checker_fixtures.PublicationCheckerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.module = importlib.import_module("kubernetes_checker")
        self.work = self.fixture.root / "work"
        self.work.mkdir(mode=0o700)
        self.view = self.work / ("asm-check-input-" + "7" * 8)
        self.view.mkdir(mode=0o700)
        (self.view / "objects").mkdir(mode=0o700)
        self.manifest = self.view / "manifest.json"
        self.manifest.write_bytes(self.fixture.manifest_file.read_bytes())
        self.manifest.chmod(0o600)
        target = self.view / "objects" / self.fixture.object_file.name
        target.write_bytes(self.fixture.data)
        target.chmod(0o600)
        self.config = self.fixture.root / "kubeconfig"
        self.config.write_text("trusted fixture")
        self.config.chmod(0o600)
        self.image = "registry.example/asm-checker@sha256:" + "c" * 64
        self.calls, self.created, self.deleted = [], None, None
        self.uid = "11111111-2222-4333-8444-555555555555"
        self.policies = {"items": [{"metadata": {"name": "asm-checker-deny-all"},
            "spec": {"podSelector": {}, "policyTypes": ["Ingress", "Egress"], "ingress": [], "egress": []}}]}
        self.phase = "Succeeded"
        self.conditions = [{"type": "Complete", "status": "True"}]
        self.logs = registry.json_bytes(publication_check.check(self.fixture.task,
            self.manifest, self.view / "objects", self.fixture.revision))
        self.change_job_uid = False
        self.cleanup_error = False
        self.unsafe_mutation = None
        self.prerequisite = None
        self.create_reply = None
        self.status_reply = None
        self.delay = False
        self.cleanup_reply = None
        self.runtime_class = {"handler": "runsc"}
        self.node_labels = {"kubernetes.io/hostname": "worker-1", "sciencehub.sh/pool": "kernels"}

    def checker(self, **changes):
        options = {"namespace": "asm-checks", "claim": "asm-check-inputs", "node": "worker-1",
            "runtime": "gvisor", "work_root": self.work}
        options.update(changes)
        return self.module.kubernetes_checker("/usr/bin/kubectl", self.config, self.image,
            self.fixture.revision, **options)

    def transport(self, arguments, *, data=b"", environment=None, output_limit=None, timeout=None):
        self.calls.append((arguments, output_limit, timeout, environment))
        self.assertLessEqual(timeout, 5)
        self.assertNotIn("KUBECONFIG", environment)
        self.assertEqual(arguments[:5], ["/usr/bin/kubectl", "--kubeconfig", str(self.config),
                                        "--request-timeout=3s", "--namespace=asm-checks"])
        command = arguments[5:]
        if command[:2] == ["get", "--raw"]:
            path = command[2]
            if path == "/api/v1/namespaces/asm-checks":
                value = {"metadata": {"labels": {"pod-security.kubernetes.io/enforce": "restricted"}}}
                if self.prerequisite == "unrestricted":
                    value["metadata"]["labels"] = {}
            elif path.endswith("/persistentvolumeclaims/asm-check-inputs"):
                value = {"spec": {"accessModes": ["ReadWriteOnce"], "volumeMode": "Filesystem"},
                         "status": {"phase": "Bound"}}
                if self.prerequisite == "wrong-pvc":
                    value["spec"]["accessModes"] = ["ReadWriteMany"]
            elif path.endswith("/runtimeclasses/gvisor"):
                value = copy.deepcopy(self.runtime_class)
                if self.prerequisite == "wrong-runtime":
                    value["handler"] = "runc"
            elif path == "/api/v1/nodes/worker-1":
                value = {"metadata": {"name": "worker-1", "labels": self.node_labels}}
            elif path.endswith("/networkpolicies"):
                value = self.policies
            elif "/jobs/" in path:
                if self.status_reply is not None:
                    return self.status_reply
                value = copy.deepcopy(self.created)
                if self.change_job_uid:
                    value["metadata"]["uid"] = "replacement-uid"
                value["status"] = {"conditions": [] if self.delay else self.conditions}
                self.delay = False
            elif "/pods?" in path:
                pod_spec = copy.deepcopy(self.created["spec"]["template"]["spec"])
                pod_spec["nodeName"] = "worker-1"
                # RuntimeClass admission merges selectors and tolerations into Pods.
                scheduling = self.runtime_class.get("scheduling", {})
                pod_spec["nodeSelector"].update(scheduling.get("nodeSelector", {}))
                if scheduling.get("tolerations"):
                    pod_spec["tolerations"] = copy.deepcopy(scheduling["tolerations"])
                if self.unsafe_mutation == "pod-selector":
                    pod_spec["nodeSelector"]["unexpected.example/pool"] = "another"
                value = {"items": [{"metadata": {"name": self.created["metadata"]["name"] + "-pod",
                    "labels": self.created["spec"]["template"]["metadata"]["labels"],
                    "uid": "pod-uid", "ownerReferences": [{"kind": "Job", "uid": self.uid, "controller": True}]},
                    "spec": pod_spec,
                    "status": {"phase": self.phase, "containerStatuses": [{"name": "checker", "restartCount": 0,
                        "state": {"terminated": {"exitCode": 0}}}]}}]}
            elif path.endswith("/log?container=checker&limitBytes=32769"):
                return self.logs
            else:
                raise AssertionError(path)
            return registry.json_bytes(value)
        if command == ["create", "--raw", "/apis/batch/v1/namespaces/asm-checks/jobs", "-f", "-"]:
            self.created = registry.strict_json(data)
            self.created["metadata"]["uid"] = self.uid
            # Kubernetes omits non-pointer false fields, and supplies API defaults.
            pod = self.created["spec"]["template"]["spec"]
            for key in ("hostNetwork", "hostPID", "hostIPC"):
                del pod[key]
            for key in ("stdin", "tty"):
                del pod["containers"][0][key]
            pod["dnsPolicy"] = "ClusterFirst"
            pod["schedulerName"] = "default-scheduler"
            pod["containers"][0]["terminationMessagePath"] = "/dev/termination-log"
            if self.unsafe_mutation == "container":
                pod["containers"][0]["env"] = [{"name": "INJECT", "value": "secret"}]
            elif self.unsafe_mutation == "network-label":
                self.created["spec"]["template"]["metadata"]["labels"]["asm.build/role"] = "publication-worker"
            elif self.unsafe_mutation == "deadline":
                self.created["spec"]["activeDeadlineSeconds"] = 300
            if self.create_reply is not None:
                return self.create_reply
            return registry.json_bytes(self.created)
        if command[:2] == ["delete", "--raw"]:
            if self.cleanup_error:
                raise self.module.registry_admin.AdminError("unknown deletion")
            self.deleted = registry.strict_json(data)
            if self.cleanup_reply is not None:
                return self.cleanup_reply
            return registry.json_bytes({"kind": "Status", "status": "Success", "details": {"uid": self.uid}})
        raise AssertionError(command)

    def run_check(self):
        with patch.object(self.module.registry_admin, "run_bounded", side_effect=self.transport):
            return self.checker()(self.fixture.task, self.manifest, self.view / "objects")

    def test_job_uses_fixed_image_secretless_restricted_runtime_and_one_readonly_input(self):
        receipt = self.run_check()
        self.assertEqual(receipt["outcome"], "pass")
        job = self.created
        self.assertEqual(job["spec"]["activeDeadlineSeconds"], 30)
        self.assertEqual(job["spec"]["backoffLimit"], 0)
        pod = job["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertFalse(pod["enableServiceLinks"])
        self.assertFalse(pod.get("hostNetwork", False))
        self.assertEqual(pod["runtimeClassName"], "gvisor")
        self.assertEqual(pod["nodeSelector"], {"kubernetes.io/hostname": "worker-1"})
        container, = pod["containers"]
        self.assertEqual(container["image"], self.image)
        self.assertNotIn("command", container)
        self.assertEqual(container["args"], ["--task", self.fixture.task])
        self.assertNotIn("env", container)
        self.assertEqual(container["volumeMounts"], [{"name": "input", "mountPath": "/input",
            "subPath": self.view.name, "readOnly": True}])
        self.assertEqual(pod["volumes"], [{"name": "input", "persistentVolumeClaim": {
            "claimName": "asm-check-inputs", "readOnly": True}}])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertEqual(container["securityContext"]["capabilities"], {"drop": ["ALL"]})
        self.assertEqual(container["resources"]["limits"], {"cpu": "1", "memory": "512Mi", "ephemeral-storage": "16Mi"})
        self.assertEqual(self.deleted["preconditions"], {"uid": self.uid})
        self.assertEqual(self.deleted["propagationPolicy"], "Foreground")
        self.assertFalse(any("/api/v1/nodes/" in call[0][-1] for call in self.calls))

    def test_runtime_class_selector_is_bound_before_creation_and_admitted_pod_is_accepted(self):
        self.runtime_class["scheduling"] = {"nodeSelector": {"sciencehub.sh/pool": "kernels"},
            "tolerations": [{"key": "sciencehub.sh/pool", "operator": "Equal", "value": "kernels", "effect": "NoSchedule"}]}
        self.assertEqual(self.run_check()["outcome"], "pass")
        self.assertEqual(self.created["spec"]["template"]["spec"]["nodeSelector"], {
            "kubernetes.io/hostname": "worker-1", "sciencehub.sh/pool": "kernels"})
        self.assertEqual(self.deleted["preconditions"], {"uid": self.uid})

    def test_conflicting_runtime_class_hostname_is_refused_before_job_creation(self):
        self.runtime_class["scheduling"] = {"nodeSelector": {"kubernetes.io/hostname": "worker-2"}}
        with self.assertRaisesRegex(registry.RegistryError, "conflicts.*worker node"):
            self.run_check()
        self.assertIsNone(self.created)

    def test_worker_node_incompatible_with_runtime_class_is_refused_before_job_creation(self):
        self.runtime_class["scheduling"] = {"nodeSelector": {"sciencehub.sh/pool": "kernels"}}
        self.node_labels["sciencehub.sh/pool"] = "control"
        with self.assertRaisesRegex(registry.RegistryError, "worker node.*RuntimeClass"):
            self.run_check()
        self.assertIsNone(self.created)

    def test_runtime_class_does_not_permit_unexpected_admitted_pod_selectors(self):
        self.runtime_class["scheduling"] = {"nodeSelector": {"sciencehub.sh/pool": "kernels"}}
        self.unsafe_mutation = "pod-selector"
        with self.assertRaises(registry.RegistryError):
            self.run_check()
        self.assertEqual(self.deleted["preconditions"], {"uid": self.uid})

    def test_malformed_or_unbounded_runtime_class_selector_is_refused_before_creation(self):
        for selector in ([], {"sciencehub.sh/pool": []}, {"sciencehub.sh/pool": "x" * 64},
                         {"x" * 318: "kernels"}, {str(index): "kernels" for index in range(17)}):
            self.runtime_class["scheduling"] = {"nodeSelector": selector}
            with self.subTest(selector=selector), self.assertRaises(registry.RegistryError):
                self.run_check()
            self.assertIsNone(self.created)

    def test_unsafe_configuration_or_input_fails_before_any_remote_mutation(self):
        for changes in ({"namespace": "../other"}, {"claim": "claim/name"}, {"node": "node\nother"},
                        {"runtime": ""}):
            with self.subTest(changes=changes), self.assertRaises(registry.RegistryError):
                self.checker(**changes)
        self.view.chmod(0o755)
        with patch.object(self.module.registry_admin, "run_bounded", side_effect=self.transport):
            with self.assertRaises(registry.RegistryError):
                self.checker()(self.fixture.task, self.manifest, self.view / "objects")
        self.assertIsNone(self.created)

    def test_missing_or_additive_network_permission_fails_closed(self):
        for policies in ({"items": []}, {"items": self.policies["items"] + [{"spec": {
                "podSelector": {}, "policyTypes": ["Egress"], "egress": [{}]}}]}):
            self.policies = policies
            with self.subTest(policies=policies), self.assertRaises(registry.RegistryError):
                self.run_check()
            self.assertIsNone(self.created)

    def test_unqualified_prerequisite_fails_before_job_creation(self):
        for prerequisite in ("unrestricted", "wrong-pvc", "wrong-runtime"):
            self.prerequisite = prerequisite
            with self.subTest(prerequisite=prerequisite), self.assertRaises(registry.RegistryError):
                self.run_check()
            self.assertIsNone(self.created)

    def test_changed_admission_policy_is_refused_and_owned_job_is_deleted(self):
        for mutation in ("container", "network-label", "deadline"):
            self.unsafe_mutation = mutation
            with self.subTest(mutation=mutation), self.assertRaises(registry.RegistryError):
                self.run_check()
            self.assertEqual(self.deleted["preconditions"], {"uid": self.uid})

    def test_noncanonical_malformed_stale_or_mismatched_receipt_is_not_accepted(self):
        valid = self.logs
        stale = registry.strict_json(valid)
        stale["checker_revision"] = "b" * 40
        wrong = registry.strict_json(valid)
        wrong["task_id"] = "9" * 32
        policy = registry.strict_json(valid)
        policy["policy_sha256"] = "0" * 64
        for body in (valid + b"\n", b"{", b"{}\n", registry.json_bytes(stale),
                     registry.json_bytes(wrong), registry.json_bytes(policy), b"x" * 32769):
            self.logs, self.deleted = body, None
            with self.subTest(body=body[:40]), self.assertRaises(registry.RegistryError):
                self.run_check()
            self.assertEqual(self.deleted["preconditions"], {"uid": self.uid})

    def test_failed_replaced_or_uncertain_job_never_returns_a_receipt(self):
        for kind in ("failed", "replaced", "cleanup"):
            self.conditions = [{"type": "Failed", "status": "True"}] if kind == "failed" else [{"type": "Complete", "status": "True"}]
            self.change_job_uid = kind == "replaced"
            self.cleanup_error = kind == "cleanup"
            with self.subTest(kind=kind), self.assertRaises((registry.RegistryError, self.module.registry_admin.AdminError)):
                self.run_check()

    def test_waiting_has_a_total_deadline_and_attempts_owned_cleanup(self):
        self.conditions = []
        with patch.object(self.module.registry_admin, "run_bounded", side_effect=self.transport), \
                patch.object(self.module.time, "monotonic", side_effect=[0] + [1] * 12 + [46] * 20), \
                patch.object(self.module.time, "sleep"):
            with self.assertRaises(registry.RegistryError):
                self.checker()(self.fixture.task, self.manifest, self.view / "objects")
        self.assertEqual(self.deleted["preconditions"], {"uid": self.uid})

    def test_delayed_completion_is_observed_without_rerunning_the_job(self):
        self.delay = True
        with patch.object(self.module.time, "sleep"):
            self.assertEqual(self.run_check()["outcome"], "pass")
        creates = [call for call in self.calls if call[0][5] == "create"]
        self.assertEqual(len(creates), 1)

    def test_malformed_creation_has_unknown_identity_and_is_never_deleted_by_name(self):
        for reply in (b"null\n", b"[]\n", b"{}\n", b"{", b'{"metadata":[]}\n',
                      b'{"metadata":{"name":"other","uid":"replacement"}}\n'):
            self.create_reply, self.deleted = reply, None
            with self.subTest(reply=reply), self.assertRaises(registry.RegistryError):
                self.run_check()
            self.assertIsNone(self.deleted)

    def test_malformed_status_is_refused_and_only_owned_job_is_deleted(self):
        for reply in (b"null\n", b"[]\n", b"{}\n", b"{", b'{"metadata":[]}\n'):
            self.status_reply, self.deleted = reply, None
            with self.subTest(reply=reply), self.assertRaises(registry.RegistryError):
                self.run_check()
            self.assertEqual(self.deleted["preconditions"], {"uid": self.uid})

    def test_unbound_or_malformed_cleanup_acknowledgment_keeps_completion_unknown(self):
        for reply in (b"null\n", b"{", b'{"kind":"Status","status":"Success"}\n',
                      b'{"kind":"Status","status":"Success","details":{"uid":"replacement"}}\n'):
            self.cleanup_reply = reply
            with self.subTest(reply=reply), self.assertRaises(registry.RegistryError):
                self.run_check()


if __name__ == "__main__":
    unittest.main()
