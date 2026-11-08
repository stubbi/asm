"""Bounded private checker Jobs. Cluster isolation requires separate qualification.

This operations module runs no package code. Trusted deployment arguments select
one image, namespace, RuntimeClass, node, and dedicated input PVC. A task selects
only its validated identity and its private input subdirectory.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import os
import hashlib
from pathlib import Path
import re
import secrets
import time
from urllib.parse import quote

import publication_check
import registry
import registry_admin
from registry_storage import _absolute, _directory

ROLE = "asm.build/role"
CHECKER_ROLE = "publication-checker"
MAX_RECEIPT = 32768
MAX_API = 128 * 1024
TOTAL_SECONDS = 45


def _api_object(value):
    registry.require(isinstance(value, dict), "invalid checker API response")
    registry.require(all(key not in value or isinstance(value[key], dict)
        or (key == "status" and value.get("kind") == "Status" and isinstance(value[key], str))
        for key in ("metadata", "spec", "status", "details")), "invalid checker API object fields")
    return value


def _name(value, description):
    registry.require(isinstance(value, str) and len(value) <= 63
        and re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", value), "invalid checker " + description)
    return value


def _network_policies(value):
    """Reject additive permissions, including selectors this executor cannot prove safe."""
    registry.require(isinstance(value, dict) and isinstance(value.get("items"), list), "invalid checker network policies")
    denied = False
    for policy in value["items"]:
        _api_object(policy)
        registry.require(isinstance(policy, dict) and isinstance(policy.get("spec"), dict), "invalid checker network policy")
        spec = policy["spec"]
        if policy.get("metadata", {}).get("name") == "asm-checker-deny-all":
            registry.require(spec.get("podSelector") == {} and sorted(spec.get("policyTypes", [])) == ["Egress", "Ingress"]
                and spec.get("ingress", []) == [] and spec.get("egress", []) == [], "checker default network denial differs")
            denied = True
        else:
            selector = spec.get("podSelector", {})
            registry.require(isinstance(selector, dict), "invalid checker network policy selector")
            labels = selector.get("matchLabels", {})
            registry.require(not selector.get("matchExpressions") and isinstance(labels, dict)
                and isinstance(labels.get(ROLE), str) and labels[ROLE] != CHECKER_ROLE,
                "another network policy can grant checker access")
    registry.require(denied, "checker default network denial is absent")


def _runtime_selector(runtime_class, node):
    """Merge bounded trusted runtime constraints without changing the worker node."""
    scheduling = runtime_class.get("scheduling", {})
    registry.require(isinstance(scheduling, dict), "invalid checker RuntimeClass scheduling")
    selected = scheduling.get("nodeSelector", {})
    registry.require(isinstance(selected, dict) and len(selected) <= 16
        and all(isinstance(key, str) and 0 < len(key) <= 317 and re.fullmatch(r"[A-Za-z0-9_./-]+", key)
            and isinstance(value, str) and len(value) <= 63 and re.fullmatch(r"[A-Za-z0-9_.-]*", value)
            for key, value in selected.items()), "invalid or unbounded checker RuntimeClass node selector")
    selector = {"kubernetes.io/hostname": node}
    for key, value in selected.items():
        registry.require(key not in selector or selector[key] == value,
                         "checker RuntimeClass selector conflicts with the worker node")
        selector[key] = value
    return selector


def _pod_spec(actual, expected, *, scheduled=False):
    """Refuse injected containers, credentials, mounts, or changed execution settings.

    The API adds a small set of harmless defaults. Unknown additions fail closed.
    RuntimeClass overhead and scheduler fields do not grant container authority.
    """
    registry.require(isinstance(actual, dict), "invalid checker Pod specification")
    extras = {"dnsPolicy", "schedulerName", "serviceAccount", "priority", "preemptionPolicy", "overhead", "tolerations"}
    if scheduled:
        extras.add("nodeName")
    registry.require(set(actual) <= set(expected) | extras, "checker Pod received an unexpected field")
    for key, value in expected.items():
        if key != "containers":
            registry.require(actual.get(key, False if value is False else None) == value, "checker Pod execution policy changed")
    containers = actual.get("containers")
    registry.require(isinstance(containers, list) and len(containers) == 1, "checker Pod received another container")
    container, wanted = containers[0], expected["containers"][0]
    registry.require(isinstance(container, dict), "invalid checker container specification")
    registry.require(set(container) <= set(wanted) | {"terminationMessagePath", "terminationMessagePolicy"},
                     "checker container received an unexpected field")
    registry.require(all(container.get(key, False if value is False else None) == value for key, value in wanted.items()),
                     "checker container execution policy changed")
    registry.require(actual.get("serviceAccount", "asm-checker") == "asm-checker", "checker service account changed")


def _receipt(raw, task, manifest, revision):
    registry.require(0 < len(raw) <= MAX_RECEIPT, "checker result exceeds its byte limit")
    receipt = registry.strict_json(raw)
    fields = {"schema", "task_id", "manifest_sha256", "checker_revision", "policy_sha256", "outcome", "objects"}
    registry.exact_keys(receipt, fields, fields, "checker receipt")
    registry.require(registry.json_bytes(receipt) == raw, "checker result is not canonical")
    data = publication_check._read(manifest, publication_check.MAX_MANIFEST)
    _, objects = publication_check.manifest(data)
    registry.require(type(receipt["schema"]) is int and receipt["schema"] == 1 and receipt["task_id"] == task
        and receipt["manifest_sha256"] == hashlib.sha256(data).hexdigest() and receipt["checker_revision"] == revision
        and receipt["policy_sha256"] == publication_check.policy_digest(), "checker result binding differs")
    registry.require(isinstance(receipt["objects"], list) and len(receipt["objects"]) == len(objects), "checker object result count differs")
    outcomes = []
    for (digest, size), result in zip(sorted(objects.items()), receipt["objects"], strict=True):
        registry.exact_keys(result, {"sha256", "bytes", "outcome"}, {"sha256", "bytes", "outcome"}, "checker object result")
        registry.require(result["sha256"] == digest and type(result["bytes"]) is int and result["bytes"] == size
            and result["outcome"] in ("pass", "fail", "error"), "checker object result binding differs")
        outcomes.append(result["outcome"])
    outcome = "fail" if "fail" in outcomes else "error" if "error" in outcomes else "pass"
    registry.require(receipt["outcome"] == outcome, "checker result outcome differs")
    return receipt


def kubernetes_checker(kubectl, kubeconfig, image, revision, *, namespace, claim, node, runtime, work_root):
    """Return the existing checker(task, manifest, objects) operator interface.

    Work root must be the dedicated PVC root, mounted by the worker. Worker and
    checker use the same non-root UID/GID; private files remain mode0600/0700.
    No shell, SDK, ambient kubeconfig, host socket, or package-selected URL is used.
    """
    namespace, claim, runtime = (_name(value, label) for value, label in
        ((namespace, "namespace"), (claim, "input claim"), (runtime, "RuntimeClass")))
    registry.require(isinstance(node, str) and len(node) <= 253
        and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", part) for part in node.split(".")), "invalid checker node")
    registry.require(isinstance(image, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/:-]*@sha256:[0-9a-f]{64}", image),
                     "select the checker image by registry digest")
    registry.require(isinstance(revision, str) and registry.HEX40.fullmatch(revision) and revision != "0" * 40,
                     "select the exact checker source revision")
    registry.require(os.getuid() > 0 and os.getgid() > 0, "run the Kubernetes worker with a non-root UID and GID")
    registry.require(all(Path(path).is_absolute() for path in (kubectl, kubeconfig, work_root)), "select absolute checker paths")
    kubectl, kubeconfig, work_root = (_absolute(path) for path in (kubectl, kubeconfig, work_root))
    publication_check._read(kubeconfig, 65536)
    with _directory(work_root, private=True):
        pass
    prefix = [str(kubectl), "--kubeconfig", str(kubeconfig), "--request-timeout=3s", "--namespace=" + namespace]
    jobs = "/apis/batch/v1/namespaces/" + namespace + "/jobs"
    core = "/api/v1/namespaces/" + namespace

    def run(task, manifest, objects):
        registry.require(isinstance(task, str) and re.fullmatch("[0-9a-f]{32}", task), "invalid checker task identity")
        manifest, objects = _absolute(manifest), _absolute(objects)
        view = manifest.parent
        registry.require(manifest.name == "manifest.json" and objects == view / "objects" and view.parent == work_root
            and re.fullmatch(r"asm-check-input-[a-zA-Z0-9_-]{8,64}", view.name), "checker inputs must use an owned task view on the input PVC")
        for directory in (work_root, view, objects):
            with _directory(directory, private=True):
                pass
        publication_check.manifest(publication_check._read(manifest, publication_check.MAX_MANIFEST))
        deadline = time.monotonic() + TOTAL_SECONDS

        def call(arguments, *, data=b"", maximum=MAX_API, cleanup=False):
            remaining = 5 if cleanup else min(4, deadline - time.monotonic())
            registry.require(remaining > 0, "checker deadline expired; inspect the owned Job before retrying")
            return registry_admin.run_bounded(prefix + arguments, data=data, environment=registry_admin.clean_environment(),
                output_limit=maximum, timeout=remaining)

        def get(path):
            value = _api_object(registry.strict_json(call(["get", "--raw", path])))
            registry.require("status" not in value or isinstance(value["status"], dict), "unexpected checker API status")
            return value

        labels = get(core).get("metadata", {}).get("labels", {})
        registry.require(isinstance(labels, dict), "invalid checker namespace labels")
        registry.require(labels.get("pod-security.kubernetes.io/enforce") == "restricted", "checker namespace must enforce Restricted Pod security")
        pvc = get(core + "/persistentvolumeclaims/" + claim)
        registry.require(pvc.get("status", {}).get("phase") == "Bound"
            and pvc.get("spec", {}).get("accessModes") == ["ReadWriteOnce"]
            and pvc.get("spec", {}).get("volumeMode", "Filesystem") == "Filesystem", "checker requires a bound ReadWriteOnce filesystem input PVC")
        runtime_class = get("/apis/node.k8s.io/v1/runtimeclasses/" + runtime)
        registry.require(runtime_class.get("handler") == "runsc", "checker RuntimeClass must select the qualified runsc handler")
        node_selector = _runtime_selector(runtime_class, node)
        if len(node_selector) > 1:
            selected_node = get("/api/v1/nodes/" + node)
            metadata = selected_node.get("metadata", {})
            node_labels = metadata.get("labels", {})
            registry.require(metadata.get("name") == node and isinstance(node_labels, dict)
                and all(node_labels.get(key) == value for key, value in node_selector.items()),
                "selected worker node does not satisfy the checker RuntimeClass selector; inspect its placement")
        _network_policies(get("/apis/networking.k8s.io/v1/namespaces/" + namespace + "/networkpolicies"))
        name = "asm-check-" + secrets.token_hex(16)
        labels = {ROLE: CHECKER_ROLE, "asm.build/check-id": name}
        pod = {"restartPolicy": "Never", "runtimeClassName": runtime,
            "serviceAccountName": "asm-checker", "automountServiceAccountToken": False,
            "enableServiceLinks": False, "hostNetwork": False, "hostPID": False, "hostIPC": False,
            "terminationGracePeriodSeconds": 1, "nodeSelector": node_selector,
            "securityContext": {"runAsNonRoot": True, "runAsUser": os.getuid(), "runAsGroup": os.getgid(),
                                "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [{"name": "checker", "image": image, "imagePullPolicy": "IfNotPresent",
                "args": ["--task", task], "stdin": False, "tty": False,
                "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                                    "capabilities": {"drop": ["ALL"]}},
                "resources": {"requests": {"cpu": "1", "memory": "512Mi", "ephemeral-storage": "16Mi"},
                              "limits": {"cpu": "1", "memory": "512Mi", "ephemeral-storage": "16Mi"}},
                "volumeMounts": [{"name": "input", "mountPath": "/input", "subPath": view.name, "readOnly": True}]}],
            "volumes": [{"name": "input", "persistentVolumeClaim": {"claimName": claim, "readOnly": True}}]}
        document = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": name, "namespace": namespace, "labels": labels},
            "spec": {"activeDeadlineSeconds": 30, "backoffLimit": 0, "completions": 1, "parallelism": 1,
                "template": {"metadata": {"labels": labels}, "spec": pod}}}
        uid = None
        try:
            created = _api_object(registry.strict_json(call(["create", "--raw", jobs, "-f", "-"], data=registry.json_bytes(document))))
            metadata = created.get("metadata", {})
            registry.require(metadata.get("name") == name and metadata.get("namespace") == namespace
                and isinstance(metadata.get("uid"), str) and re.fullmatch(r"[a-zA-Z0-9-]{1,64}", metadata["uid"]),
                "checker creation result identity differs; inspect the task view before retrying")
            uid = metadata["uid"]
            def check_job(value):
                spec = value.get("spec", {})
                registry.require(all(spec.get(key) == document["spec"][key] for key in
                    ("activeDeadlineSeconds", "backoffLimit", "completions", "parallelism")), "checker Job limits changed")
                template = _api_object(spec.get("template", {}))
                actual_labels = template.get("metadata", {}).get("labels", {})
                registry.require(isinstance(actual_labels, dict), "invalid checker Pod labels")
                registry.require(all(actual_labels.get(key) == value for key, value in labels.items()), "checker Pod labels changed")
                _pod_spec(template.get("spec"), pod)
            check_job(created)
            while True:
                job = get(jobs + "/" + name)
                registry.require(job.get("metadata", {}).get("uid") == uid, "checker Job identity changed")
                check_job(job)
                conditions = job.get("status", {}).get("conditions", [])
                registry.require(isinstance(conditions, list) and all(isinstance(item, dict) for item in conditions), "invalid checker Job conditions")
                registry.require(not any(item.get("type") in ("Failed", "FailureTarget") and item.get("status") == "True"
                    for item in conditions), "checker Job failed; inspect its retained task before retrying")
                if any(item.get("type") == "Complete" and item.get("status") == "True" for item in conditions):
                    break
                registry.require(time.monotonic() < deadline, "checker deadline expired; inspect the owned Job before retrying")
                time.sleep(min(1, max(0, deadline - time.monotonic())))
            listing = get(core + "/pods?labelSelector=" + quote("asm.build/check-id=" + name, safe=""))
            instances = listing.get("items")
            registry.require(isinstance(instances, list) and len(instances) == 1, "checker Job must have exactly one observable Pod")
            instance = _api_object(instances[0])
            actual_labels = instance.get("metadata", {}).get("labels", {})
            registry.require(isinstance(actual_labels, dict), "invalid checker Pod labels")
            registry.require(all(actual_labels.get(key) == value for key, value in labels.items()), "checker Pod labels changed")
            owners = instance.get("metadata", {}).get("ownerReferences", [])
            registry.require(isinstance(owners, list) and all(isinstance(owner, dict) for owner in owners), "invalid checker Pod owners")
            registry.require(any(owner.get("kind") == "Job" and owner.get("uid") == uid and owner.get("controller") is True
                for owner in owners), "checker Pod owner differs")
            _pod_spec(instance.get("spec"), pod, scheduled=True)
            status = instance.get("status", {})
            states = status.get("containerStatuses", [])
            registry.require(isinstance(states, list) and len(states) == 1 and isinstance(states[0], dict), "invalid checker container status")
            state = states[0].get("state", {})
            registry.require(isinstance(state, dict) and isinstance(state.get("terminated", {}), dict), "invalid checker container termination")
            registry.require(instance["spec"].get("nodeName") == node and status.get("phase") == "Succeeded" and len(states) == 1
                and states[0].get("name") == "checker" and states[0].get("restartCount") == 0
                and state.get("terminated", {}).get("exitCode") == 0, "checker Pod did not finish successfully on the selected node")
            pod_name = instance.get("metadata", {}).get("name")
            registry.require(isinstance(pod_name, str) and re.fullmatch(r"asm-check-[0-9a-f]{32}-[a-z0-9-]{1,64}", pod_name), "invalid checker Pod identity")
            raw = call(["get", "--raw", core + "/pods/" + pod_name + "/log?container=checker&limitBytes=32769"], maximum=MAX_RECEIPT)
            return _receipt(raw, task, manifest, revision)
        finally:
            if uid is not None:
                # UID preconditions prevent deletion of a replacement with the same name.
                # An uncertain delete is an error, even after an otherwise valid receipt.
                options = {"apiVersion": "v1", "kind": "DeleteOptions", "preconditions": {"uid": uid},
                           "propagationPolicy": "Foreground"}
                acknowledgment = _api_object(registry.strict_json(call(["delete", "--raw", jobs + "/" + name, "-f", "-"],
                    data=registry.json_bytes(options), maximum=MAX_API, cleanup=True)))
                registry.require((
                    (acknowledgment.get("kind") == "Job" and acknowledgment.get("metadata", {}).get("uid") == uid
                     and acknowledgment.get("metadata", {}).get("name") == name)
                    or (acknowledgment.get("kind") == "Status" and acknowledgment.get("status") == "Success"
                        and acknowledgment.get("details", {}).get("uid") == uid)),
                    "checker deletion acknowledgment differs; inspect the owned Job before retrying")
    return run
