# Private Kubernetes checker execution

This executor prepares bounded checker Jobs for signed V2 publication.
It does not activate hosted publication or qualify a Kubernetes cluster.
The HTTP application and package logic remain assembly.
Python runs the existing private publication operations.

The user outcome is a structural result tied to exact bytes, without giving package inputs publication authority.
The guiding principles are explicit authority, resource care, and evidence before claims.
Dedicated storage and restrictive policy checks add operator work.
They preserve private inputs and make uncertain outcomes visible.

## Fixed execution contract

`publication_worker.run_one(..., checker, work_root=...)` retains its injected checker interface.
The source command defaults to the existing local Docker executor.
The operator image selects Kubernetes and fixes its executable paths and source revision.

The Kubernetes executor uses a trusted absolute `kubectl` path and one private kubeconfig file.
It clears ambient environment configuration and passes direct arguments.
The kubeconfig is operator configuration, not package input.
It must contain reviewed API and credential settings without executable authentication plugins or proxy overrides.

The operator selects a digest-pinned checker image, namespace, input claim, node, and RuntimeClass.
Package data cannot select a command, image, mount, credential, or network destination.
The checker image accepts only `--task TASK_ID`.
Its entrypoint reads `/input/manifest.json` and `/input/objects`.
Its source receipt supplies the checker revision.

The Job has one container and no retries.
It requests and limits one CPU, 512 MiB of memory, and 16 MiB of ephemeral storage.
Its active deadline is 30 seconds.
The executor has a 45-second total deadline and a separate five-second cleanup limit.
Each API request has a three-second timeout.
Each ordinary child command has a maximum four-second deadline.
API responses have a 128 KiB limit.
Checker output has a 32 KiB limit.

The checker uses the worker's non-root user and group identifiers.
Its root filesystem and input mount are read-only.
It drops all Linux capabilities and prohibits privilege escalation.
It uses `RuntimeDefault` seccomp and a trusted RuntimeClass whose handler is `runsc`.
Host networking, host process namespaces, and host IPC are disabled.
Service account token mounting and service environment injection are disabled.
The Job mounts no host container socket, database material, signing key, or storage credential.

## Required deployment controls

1. Use a dedicated namespace for the publication worker and its checkers.
2. Enforce the Restricted Pod Security Standard in that namespace.
3. Create an `asm-checker` service account without API grants, token mounts, or image-pull secrets.
4. Restrict worker credentials to the operations listed below.
5. Install the reviewed gVisor runtime on the selected node.
6. Configure the selected RuntimeClass with the `runsc` handler.
7. Qualify the actual runtime before accepting untrusted inputs.
8. Set the node's Pod process limit to 16 or fewer processes.
9. Bound container logs and node storage through the existing cluster controls.
10. Enforce namespace storage and compute quotas for pending or uncertain Jobs.

The executor checks the Restricted namespace label, bound input claim, RuntimeClass configuration, and namespace network policies.
These configuration checks do not prove runtime enforcement or network isolation.
Admission must prevent replacement of these controls during execution.

The worker needs `get` access to its namespace, selected PVC, and selected RuntimeClass.
When RuntimeClass scheduling adds node labels, it also needs `get` access to the selected Node by name.
Restrict this Node permission with `resourceNames` for the qualified worker nodes.
It needs no Node list, watch, or mutation permission.
It needs `list` access to namespace NetworkPolicies and checker Pods.
It needs `get`, `create`, and `delete` access to checker Jobs.
It needs `get` access to checker Pod logs.
It needs no Secret read, Pod exec, Pod create, workload patch, or cluster administration permission.

Kubernetes RBAC cannot constrain Job creation by image or Pod specification.
Admission must restrict the worker identity to the fixed checker contract.
It must validate the image digest, service account, runtime, node, security settings, resource bounds, labels, and single read-only input mount.
It must reject additional containers, credential projections, host mounts, and changed commands.
The executor also rejects unexpected API fields and changes in returned Job and Pod specifications.
This response check cannot replace admission because an admitted workload can start before the response arrives.

## Network denial prerequisite

The namespace must contain `asm-checker-deny-all` with this specification:

```yaml
podSelector: {}
policyTypes: [Ingress, Egress]
ingress: []
egress: []
```

NetworkPolicy permissions are additive.
Every additional policy must use `matchLabels` with an explicit `asm.build/role` value other than `publication-checker`.
The executor refuses additional policies with `matchExpressions` or ambiguous selectors.
This permits separately scoped worker API, database, and storage access.
The checker has the fixed role label `publication-checker`.

1. Prevent policy and role-label changes through admission and separate administrator identities.
2. Qualify the selected network plugin's actual enforcement.
3. Test DNS, API, metadata-service, database, storage, Internet, same-node, and cross-node traffic denial from the checker.
4. Retain failed probes and the exact cluster, plugin, runtime, image, and source versions.

NetworkPolicy configuration alone does not establish complete traffic denial.
The executor does not inspect CiliumNetworkPolicy, CiliumClusterwideNetworkPolicy, or other plugin-specific and cluster-wide policy objects.
Their permissions and host-traffic behavior require independent review.
The cluster's node and runtime boundaries require separate review and hostile-input checks.

## Private input storage

The worker mounts the root of one dedicated filesystem PVC at `--work-root`.
The PVC must be bound with the `ReadWriteOnce` access mode.
This mode permits multiple Pods on one node; it does not make a mount read-only.
It must not use `ReadWriteOncePod`, which prevents this sharing arrangement.

The worker creates one owned mode-`0700` task directory under that root.
Its manifest and object copies have mode `0600`.
The checker mounts only that directory through a read-only `subPath` mount.
The checker cannot traverse other task directories or the PVC root through this mount.
No ConfigMap or API upload carries the package bytes.
Task objects can total 128 MiB.

1. Mount only checker input storage at the worker's work root.
2. Keep database files, keys, upload staging, and retained objects on separate mounts.
3. Provision the work root for the worker's non-root UID and GID before starting the worker.
4. Keep its directory mode at `0700` without an extended ACL.
5. Use the same UID and GID for the checker.
6. Avoid an `fsGroup` setting that changes private file permissions.
7. Supply the worker's actual node name through a trusted Downward API value.
8. Confirm that its `kubernetes.io/hostname` label equals that node name.
9. Qualify same-node read-only `subPath` access with the selected CSI driver and gVisor runtime.
10. Test absent inputs, wrong ownership, links, permission changes, full storage, and worker interruption.

The executor merges `RuntimeClass.scheduling.nodeSelector` with the fixed worker hostname before Job creation.
The RuntimeClass selector permits at most 16 string entries.
Each key has a 317-character limit; each value has a 63-character limit.
A conflicting hostname fails before Job creation.
When the class adds constraints, the executor reads the selected Node and compares all merged labels before creation.
An incompatible worker node fails before a checker starts.
A class without additional selectors needs no Node read.
Kubernetes admission can merge the RuntimeClass's tolerations into the Pod.
The returned Pod's node selector must still equal the complete expected selector.
The executor verifies the finished Pod's actual node name.
These local file checks do not prove the selected PVC backs the worker path.
Deployment admission and an actual shared-input test must establish that binding.

## Invocation and recovery

The following source invocation selects Kubernetes explicitly.
Install the reviewed Kubernetes client before running it.
Replace uppercase placeholders with qualified deployment values.

```sh
python3 tools/publication_worker.py \
  --connection-file /private/asm-worker/connection \
  --psql /opt/asm/postgres/bin/psql \
  --staging /private/asm-uploads \
  --work-root /private/asm-check-inputs \
  --worker-id WORKER_ID_32_HEX \
  --executor kubernetes \
  --kubectl /usr/bin/kubectl \
  --kubeconfig /private/asm-worker/kubeconfig \
  --checker-image CHECKER_REGISTRY_IMAGE_AT_SHA256_DIGEST \
  --checker-revision CHECKER_SOURCE_COMMIT_40_HEX \
  --checker-namespace asm-checks \
  --checker-claim asm-check-inputs \
  --checker-node WORKER_NODE_NAME \
  --checker-runtime gvisor \
  --store local --root /private/asm-retained
```

An idle worker prints nothing.
Completed work returns bounded JSON.
A failure returns exit code 1 and requests task inspection.

The executor accepts only a canonical receipt with matching task, manifest, source revision, local checker policy, objects, and outcomes.
A completed Job and one successful, owned Pod must precede receipt acceptance.
Cleanup targets only the created Job's random name and API-assigned UID.
Deletion uses a UID precondition and foreground propagation.
It never deletes by label selector or name alone.
A changed identity, malformed response, timeout, or uncertain deletion prevents completion.

The worker preserves the private task view after checker failure or uncertainty.
It also preserves a view after a local failure during input preparation.
Staged inputs and database fencing remain available.
No object retention or database completion follows an uncertain checker result.
An acknowledged foreground deletion does not itself prove process termination.
Successful receipt acceptance also requires the observed terminal Job and Pod states.

1. Inspect the task state and its retained private manifest before retrying.
2. Identify the matching checker through its input subdirectory and Job specification.
3. Confirm its API UID before performing any cleanup.
4. Confirm Pod termination before removing an uncertain task view.
5. Preserve failed evidence and staged objects until reconciliation finishes.
6. Use the existing fenced task workflow for retry.

Quota monitoring must alert on pending Jobs and preserved task views.
Operators reconcile this storage before the worker accepts further work near its capacity limit.
No automatic collector removes uncertain inputs.

## Evidence and remaining limits

The source tests use synthetic task bytes and a bounded Kubernetes transport substitute.
They cover fixed Job construction, refusal paths, delayed results, malformed replies, identity changes, timeouts, and uncertain cleanup.
They do not qualify a live cluster, an image build, a network plugin, a CSI driver, gVisor, or provider recovery.
Public activation remains held until the [implementation plan](superpowers/plans/2026-11-08-hosted-v2.md) gates pass.

The contract targets Kubernetes v1.35 APIs.
The following primary documentation was checked on 2026-11-08:

- [Job deadlines and terminal conditions](https://v1-35.docs.kubernetes.io/docs/concepts/workloads/controllers/job/).
- [Persistent volume access modes and claim scope](https://kubernetes.io/docs/concepts/storage/persistent-volumes/).
- [Volume subpaths](https://kubernetes.io/docs/concepts/storage/volumes/).
- [Additive NetworkPolicy permissions and enforcement limits](https://kubernetes.io/docs/concepts/services-networking/network-policies/).
- [RuntimeClass selection](https://kubernetes.io/docs/concepts/containers/runtime-class/).
- [Job deletion and DeleteOptions](https://kubernetes.io/docs/reference/kubernetes-api/batch/job-v1/).
- [Raw kubectl deletion](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_delete/).
