# Same-Pod publisher proxy reference

Status: local reference configuration, 8 November 2026.
This reference does not activate a public service.

The user outcome is direct publication through a bounded HTTP boundary.
This follows the foundation's dependable reuse, resource care, and evidence principles.
The application remains the [assembly publisher](../../server/publisher/README.md).
NGINX supplies the proxy transport, without package logic or publication authority.

Run both processes in the same Pod network namespace.
Keep `ASM_BIND=127.0.0.1:8080` for the publisher.
Expose only proxy port `8081` through the private service boundary.
The configuration uses one fixed upstream, `http://127.0.0.1:8080`.
Requests cannot select another upstream.

Public ingress must supply separately qualified TLS and restrict access to this proxy port.
The reference supplies HTTP inside that boundary.
It does not supply TLS certificates, public DNS, ingress rules, or a deployment image.

## Start the proxy

Use an unprivileged account and a private writable runtime directory.
The runtime directory contains the process identifier and NGINX temporary directories.
Keep the configuration read-only to the service account.
The following example assumes an owned `/run/asm-proxy` directory:

```sh
nginx -e /dev/null -p /run/asm-proxy/ -c /etc/asm-publisher/nginx.conf
```

The process stays in the foreground.
It listens on ports `8081` and `8082` without administrator privileges.
It needs no database credential, publisher token, signing key, or upload-directory mount.
Port `8081` refuses health routes.
The separate probe listener on port `8082` forwards health requests to the loopback application.

## Configure private Kubernetes probes

Use standard Pod networking for the publisher and proxy.
Keep port `8082` outside every Service, Ingress, and `hostPort` mapping.
Require an enforced default-deny ingress NetworkPolicy for the publisher Pods.
Permit the selected ingress-controller Pods to reach TCP port `8081` only.
Exclude port `8082` from Pod and namespace allow rules.
The network plugin must implement NetworkPolicy enforcement.
These requirements need actual cluster checks before activation.

Kubernetes permits traffic from a Pod's resident node through standard NetworkPolicy.
That includes the kubelet's HTTP probe.
Node access remains a separate cluster trust boundary.
Verify probe access from the resident node and refusal from unrelated Pods.
The [NetworkPolicy documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/) defines these node and enforcement limits.

Use these fields in the publisher container specification:

```yaml
livenessProbe:
  httpGet:
    path: /health/live
    port: 8082
    scheme: HTTP
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /health/ready
    port: 8082
    scheme: HTTP
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
```

Leave `httpGet.host` unset to select the Pod IP.
The [HTTPGetAction API](https://kubernetes.io/docs/reference/kubernetes-api/core/pod-v1/#HTTPGetAction) defines that default.
The kubelet reaches NGINX on the Pod IP; NGINX reaches the application on `127.0.0.1:8080`.
The reference listener uses IPv4; an IPv6 Pod network needs separate listener qualification.
NGINX forwards the application's status, including HTTP 503 for unavailable readiness.
The proxy adds no application health logic.

Only exact `GET /health/live` and `GET /health/ready` requests reach the backend through port `8082`.
Queries, escaped paths, other methods, publication routes, and request bodies fail before forwarding.
The probe listener strips caller headers and supplies only fixed transport headers.
It disables request logs, retries, caching, response storage, and response buffering.
Responses receive `Cache-Control: no-store`.

| Probe scope | Reference limit |
| --- | --- |
| Complete header read | Two seconds |
| Upstream connection | One second |
| Idle time between upstream writes | Two seconds |
| Idle time between upstream reads or client response writes | Three seconds |
| Active requests after complete headers | Four on port `8082` |

The kubelet's five-second probe timeout bounds its complete attempt.
NGINX's idle timeouts do not establish a total request deadline.
Application and probe traffic share one NGINX worker and its connection budget.
Probe availability under saturation remains unmeasured.
These source settings do not establish deployed kubelet reachability or network isolation.
The Kubernetes API and NetworkPolicy documentation were reviewed on 8 November 2026.

## Boundary and limits

Only these method and path pairs reach the publisher through port `8081`:

| Method | Path |
| --- | --- |
| `GET` | `/api/v2/status` |
| `POST` | `/api/v2/publications` |
| `GET` | `/api/v2/publications/{id}` |
| `PUT` | `/api/v2/publications/{id}/artifacts/{sha256}` |

An identifier contains exactly 32 lowercase hexadecimal characters.
An artifact digest contains exactly 64 lowercase hexadecimal characters.
The original request target must match, including its case and separators.
Queries, escaped paths, dot segments, trailing slashes, and other methods fail before forwarding.
`proxy_pass` has no URI component, so accepted paths retain their original spelling.

NGINX forwards authorization, idempotency, content type, and declared content length.
Repeated authority headers remain visible to the assembly admission check, unless NGINX already rejects them.
Rebuilding these fields from NGINX variables can conceal duplicate fields.
The proxy removes cookies and forwarded client-address fields.
The backend remains responsible for its full header, authentication, manifest, digest, and receipt checks.

| Scope | Reference limit |
| --- | --- |
| Manifest request body | 64 KiB |
| Artifact request body | 64 MiB |
| Request header buffers | One initial 1 KiB buffer; two additional 4 KiB buffers |
| Complete header read | Five seconds |
| Idle time between body reads | Five seconds |
| Upstream connection | Two seconds |
| Idle time between upstream writes | Five seconds |
| Idle time between upstream reads | 65 seconds |
| Idle time between client response writes | Ten seconds |
| Active requests after complete headers | 16 per proxy instance; excess requests receive HTTP 429 |
| Worker connections | 64, including upstream connections and incomplete headers |

POST and PUT require a declared content length.
Transfer-encoded requests fail before forwarding.
Bodies stream to the publisher without complete request buffering or body temporary files.
A client disconnect closes its upstream request.
The proxy performs no upstream retry, response caching, response buffering, or response storage.
Responses receive `Cache-Control: no-store`.

The idle timeouts are not a total request deadline.
Streaming exposes the request to the assembly publisher's existing 60-second post-header deadline.
The [publisher runtime gate](../../server/publisher/README.md#build-the-reviewed-library-profile) checks that application deadline separately.
Blocking filesystem durability remains a separate host qualification requirement.

Access and error logs are disabled because NGINX error messages can contain private URLs and headers.
This trades request-level proxy diagnostics for credential privacy.
Process health and application readiness require separate monitoring.
Any replacement logger needs its own data-minimization review.

## Run the direct HTTP gate

Install NGINX and Python 3.11 or later before running the gate.
Reserve local ports `8080`, `8081`, and `8082` for its bounded synthetic backend and proxy.
Run the gate as an unprivileged account:

```sh
make publisher-proxy-test NGINX=/usr/sbin/nginx
```

The gate fails when the executable is missing.
Portable test discovery skips these methods when `ASM_TEST_NGINX` is absent.
The gate uses the exact reference configuration, with a private temporary runtime prefix.
A bounded synthetic backend records the forwarded bytes.

On 8 November 2026, 14 methods passed as user `65532` against Debian NGINX `1.22.1-9+deb12u10`.
They checked allowed routes, rejected paths, duplicate fields, streaming, disconnects, exact body limits, headers, idle timeouts, concurrency, and logs.
The tests accepted exact 64 KiB and 64 MiB bodies and refused oversized declared bodies before forwarding.
Probe checks covered private health routing, readiness HTTP 503, stalled-backend timeout, refused bodies, and log privacy.
The synthetic backend returned publication statuses without implementing publication state or authorization.
These results do not qualify Kubernetes networking, public TLS, a deployment image, saturation, storage, or a native publication flow.

| Tested artifact | SHA-256 |
| --- | --- |
| `nginx.conf` | `d3109e97c562af7a576f9ddd216c861ffd0beba8f62f6446fa5d99bbcf71aed0` |
| `test_proxy.py` | `8095dc7a781a614de7626fa825f26f9f300c12e631e01a7cc44945521a3a2c3a` |
| NGINX executable | `62b20544dc6f509184ab550d15658bbc9fd18ca720235fda14eb8ef91e09d595` |

The earlier 11-method reference had no Pod-IP probe listener and is superseded.
Its configuration SHA-256 was `d6dabd8af2a7df6213ec1c2b32b07af07df7c3a68529ebb99937f2799c70e9f5`.
The first probe regression failed with connection refusal before port `8082` existed.

The first startup failed because distribution defaults selected unwritable system temporary directories.
Explicit runtime-prefix directories corrected that failure.
A duplicate-field regression then showed that explicit field reconstruction concealed repeated idempotency and content-type headers.
Preserving original fields corrected that failure without changing application admission.
The first Makefile gate exposed NGINX's reserved inherited-socket environment variable.
The test now removes the Makefile executable selector from the proxy process environment.

The official [proxy documentation](https://nginx.org/en/docs/http/ngx_http_proxy_module.html),
[HTTP core documentation](https://nginx.org/en/docs/http/ngx_http_core_module.html), and
[connection-limit documentation](https://nginx.org/en/docs/http/ngx_http_limit_conn_module.html)
were reviewed on 8 November 2026.
The tested package is a local fixture, not a production dependency selection.
Select and qualify a maintained deployment build before activation.
