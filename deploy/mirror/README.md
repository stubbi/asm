# Run a static artifact origin

This reference serves synchronized artifact files through nginx.
A byte mirror needs files, HTTPS serving, and the private synchronization command.
It needs no PostgreSQL, publisher credential, or signing key.
The [canonical catalog](../../server/catalog/README.md) retains metadata authority.
The assembly application remains a separate platform component.

This page's generated routes, hourly timer, and observation importer implement V1 compatibility distribution.
For signed V2, follow the [V2 mirror procedure](../../docs/hosting.md#host-a-v2-mirror).
Use `registry_distribution.py sync` every two minutes instead of the V1 synchronization command and timer.
Replace the `downloads.conf` include with [v2-locations.conf](v2-locations.conf) for a V2-only origin.
Keep the default refusal route, GET/HEAD restriction, symlink protection, and private logs from `nginx.conf`.
Mount the public mirror at `/srv/asm` and the selected include at `/etc/nginx/asm/downloads.conf`.
The V2 include disables metadata caching and exposes only metadata, targets, and digest blobs.
The V1 observation importer cannot attribute V2 digest requests to individual packages.
It must not report invented V2 counts.

Use a dedicated artifact hostname behind an HTTPS ingress.
Keep browser session cookies off that hostname.
Mount the mirror's files read-only.
Keep its log volume private and separate from public files.
The nginx user needs read access to the mirror files.
It needs write access only to its log volume and process files.
Use the same numeric owner for the private mirror volume and its serving process.

## Schedule an S3-to-filesystem mirror

The supplied [service](asm-mirror.service) and [timer](asm-mirror.timer) are Linux systemd references.
They call the existing tool directly; they add no application or database.
Use a reviewed, administrator-owned Asm checkout at `/opt/asm`.
Install Python 3.11 or later and the locked SDK into `/opt/asm/.venv`.
Keep the checkout and virtual environment readable but not writable by the service account.

```sh
sudo python3 -m venv /opt/asm/.venv
sudo /opt/asm/.venv/bin/python -m pip install --require-hashes -r /opt/asm/requirements-storage.txt
```

1. Create the non-login `asm-mirror` system user and group through your host's account-management tools.
2. Create its directories:

   ```sh
   sudo install -d -m 0750 -o root -g asm-mirror /etc/asm-mirror
   sudo install -d -m 0700 -o asm-mirror -g asm-mirror /var/lib/asm-mirror
   ```

3. Put these non-secret settings in `/etc/asm-mirror/source.env`:

   ```ini
   ASM_SOURCE_BUCKET=asm-artifacts
   ASM_SOURCE_ENDPOINT=https://STORAGE_ENDPOINT
   ASM_SOURCE_REGION=REGION
   ASM_SOURCE_PREFIX=
   ```

4. Replace the endpoint, region, bucket, and optional prefix with the selected origin's settings.
5. Put the `asm-mirror-source` profile in `/etc/asm-mirror/source.credentials` through your credential-management process.

   ```ini
   [asm-mirror-source]
   aws_access_key_id=REPLACE_WITH_SCOPED_SOURCE_READER
   aws_secret_access_key=REPLACE_WITH_SOURCE_READER_SECRET
   ```

6. Set both files to owner `root`, group `asm-mirror`, and mode `0640`.

The source credential needs object reads only for the selected origin prefix.
It needs no destination, publication, database, or deletion authority.
Add `aws_session_token` when the provider requires temporary credentials.
Refresh expired credentials through the same credential-management process.
The unit reads this named profile and disables instance-metadata credential discovery.
The configuration files are trusted administrator input.
Do not put secrets in `source.env`, command arguments, unit files, or repository files.
The endpoint and prefix select where the job reads; review changes before restarting it.

7. Bootstrap the empty destination manually:

   ```sh
   sudo -u asm-mirror env \
     AWS_SHARED_CREDENTIALS_FILE=/etc/asm-mirror/source.credentials \
     AWS_CONFIG_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
     PYTHONDONTWRITEBYTECODE=1 \
     /opt/asm/.venv/bin/python /opt/asm/tools/registry_mirror.py sync \
     --source-store s3 --source-bucket asm-artifacts \
     --source-endpoint https://STORAGE_ENDPOINT --source-region REGION \
     --source-profile asm-mirror-source \
     --store local --root /var/lib/asm-mirror --initialize
   ```

   Use the same origin settings as `source.env`.
   If the origin uses a prefix, add `--source-prefix VALUE` to this command.
   Success prints one 64-character lowercase snapshot digest and exits with code zero.
   Failure prints an error to standard error and preserves the previous head.
   `--initialize` refuses a destination that already has a head.

8. Install the units from the checkout:

   ```sh
   sudo install -m 0644 deploy/mirror/asm-mirror.service /etc/systemd/system/asm-mirror.service
   sudo install -m 0644 deploy/mirror/asm-mirror.timer /etc/systemd/system/asm-mirror.timer
   sudo systemd-analyze verify /etc/systemd/system/asm-mirror.service /etc/systemd/system/asm-mirror.timer
   sudo systemctl daemon-reload
   sudo systemctl start asm-mirror.service
   sudo journalctl -u asm-mirror.service -n 20 --no-pager
   ```

   A successful service run records the selected snapshot digest in its journal.
   Check that the service succeeded before enabling its timer.

9. Enable recurring synchronization:

   ```sh
   sudo systemctl enable --now asm-mirror.timer
   systemctl list-timers asm-mirror.timer
   ```

The timer runs about one hour after each completion, with up to five minutes of additional randomized delay.
Its first activation can occur immediately when boot was more than five minutes earlier.
systemd keeps one instance of this service active; timer events do not start overlapping copies.
Stop the timer and wait for the service before running another writer against this destination.
The unit requests a read-only system tree with `ProtectSystem=strict`.
`StateDirectory` grants write access to `/var/lib/asm-mirror`.
The process also receives private temporary directories.
Confirm these protections on the deployment host.
The example limits each run to 45 minutes, 512 MiB of memory, half a CPU, and 16 tasks.
These are operator bounds, not measured capacity requirements.
Adjust them after checking the selected workload and available disk space.
Interrupted work can leave unreferenced immutable objects without exposing an incomplete head.

Routine retries use the metadata-only unchanged-head path.
Schedule [explicit verification](#verification-and-limits) separately according to storage risk and read budget.
The timer does not regenerate routes, reload nginx, import statistics, or grant native-client mirror support.
Use the returned snapshot for the separate route publication procedure below.

No `systemd-analyze` executable was available on the authoring host or its existing Linux test fixture.
The units remain unverified references; validate and exercise them on the selected Linux host before enabling the timer.
No system service was installed or enabled during this check.
See the official [service](https://www.freedesktop.org/software/systemd/man/252/systemd.service.html),
[execution](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html), and
[timer](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html) contracts.

## Prepare the routes

Use Python 3.11 or later for the private operator commands.
Run these commands from the Asm repository.
Select the exact retained snapshot that supplied the synchronized files.
Replace `SNAPSHOT_SHA256` with the digest returned by the synchronization command.
The manifest path below uses the private operator's view of the mirror.
The blob path uses the serving process's mounted view.

1. Generate exact package selection routes:

   ```sh
   python3 tools/registry_log_import.py \
     --snapshot-file /srv/asm-mirror/snapshots/SNAPSHOT_SHA256/manifest.json nginx \
     --blob-root /srv/asm/blobs/sha256 > downloads.conf
   ```

2. Mount `downloads.conf` at `/etc/nginx/asm/downloads.conf`.
3. Mount this directory's `nginx.conf` as the nginx configuration.
4. Mount the materialized mirror at `/srv/asm`.
5. Create a private writable log directory at `/var/log/asm`.
6. Set the serving environment's time zone to UTC.
7. Check the configuration with `nginx -t` before starting or reloading nginx.

The generated routes bind package, version, target, format, and digest.
They preserve every target accepted by the current registry validator.
They do not infer host compatibility or execute artifacts.
They exclude new selections of yanked versions.
Regenerate and reload the routes after an accepted publication or yank.
The example caches selected routes for five minutes.
A cached response can outlive a yank; the origin cannot remove copies already delivered.
An exact digest never changes its bytes.

nginx permits GET and HEAD requests.
It serves files as downloads and disables content sniffing.
It supports one byte range per request.
Its default route returns HTTP 404.
It exposes neither raw storage paths nor a directory listing.
Keep the supplied log format: default access logs can retain personal information.
Request error logs are disabled because their context can contain private URLs.

The manifest input has a one MiB limit and must use canonical snapshot bytes.
A `manifest.json` inside a SHA-256 directory must match that directory's digest.
Keep the manifest's parent directory private and owned by the operator.
`--registry DIRECTORY` is an alternative for deliberately selected accepted records.
It cannot be combined with `--snapshot-file`.
The repository's `registry/` directory contains compatibility records, not a public publication queue.
These checks establish byte consistency, not publisher identity or registry freshness.

## Import delivery observations

The private log contains UTC time, server request ID, method, accepted selection, status, body bytes, completion, and advisory traffic class.
It contains no IP address, cookie, user-agent string, referrer, or query string.
The importer rejects additional fields.
Bot and internal classifications are advisory exclusions; they do not authenticate a person or process.

Rotate logs before importing them.
Use an immutable private file for each batch.
Choose a stable batch ID and an explicit source name.
Use a different source name for independently reported origins.
The example timestamps below illustrate a completed UTC reporting interval.

```sh
python3 tools/registry_log_import.py \
  --snapshot-file /srv/asm-mirror/snapshots/SNAPSHOT_SHA256/manifest.json import \
  --state /srv/asm-stats/events.sqlite3 --source origin-main \
  --batch 2026-11-07-00 --start 2026-11-07T00:00:00Z \
  --end 2026-11-07T01:00:00Z --log /srv/asm-logs/2026-11-07-00.jsonl

python3 tools/registry_log_import.py \
  --snapshot-file /srv/asm-mirror/snapshots/SNAPSHOT_SHA256/manifest.json snapshot \
  --state /srv/asm-stats/events.sqlite3 --source origin-main > observation.json
```

A successful import is quiet.
An identical batch retry changes no counts.
A conflicting batch or request ID fails the complete transaction.
Late batches and process restarts preserve request deduplication.
Keep accepted historical records when collecting statistics after a yank.

Only complete public GET responses with HTTP 200 and the expected body length contribute.
HEAD, ranges, redirects, conditional responses, bot requests, failures, and interrupted responses do not contribute.
A sender's completion observation does not establish client receipt, installation, or verification.
The event source is the configured origin, regardless of the object storage provider.

All imported counts remain observed lower bounds.
Log intervals do not certify continuous coverage.
CDN hits and unreported mirrors remain outside these origin counts.
An empty imported batch supplies an observed zero; absent batches remain unknown.
Daily gaps remain unknown.
Snapshots become stale after 24 hours without a newer reporting cutoff.
The output uses the existing discovery observation shape and identifies `origin-log-lower-bounds-v1`.

One batch permits at most 8 MiB, 100,000 events, and 4 KiB per line.
The ledger permits 64 MiB, 250,000 events, and 10,000 batches.
It refuses further imports at those bounds instead of deleting evidence.
Keep a private backup and archive the ledger before reaching those limits.
Do not combine independently generated snapshots by adding their totals.
Import their distinct source logs into one ledger to preserve event identity.

## Verification and limits

Routine synchronization with an unchanged head checks metadata only.
Use `registry_mirror.py verify` to audit current exports and retained artifacts.
Use `sync --check-existing` to check an unchanged mirror and restore missing objects.
Neither command replaces corrupt retained bytes; restore those from a trusted backup.

Run the private tool checks:

```sh
PYTHONPATH=tests python3 -m unittest test_registry_storage test_registry_mirror test_registry_log_import -v
```

S3 operations require the hash-pinned dependencies in `requirements-storage.txt`.
Local mirrors and statistics imports use the Python standard library.
The generic metadata adapter permits four MiB for canonical catalog JSON exports.
The mirror's snapshot and head callers retain their separate one MiB limits.

Check a real download, HEAD request, byte range, unknown route, and forbidden method before exposing an origin.
Check a deliberate network interruption before enabling its statistics job.
Qualify the selected nginx build, ingress, cache, storage permissions, log rotation, and restore procedure in that environment.
The repository's generated-route and import tests do not replace these deployment checks.

To exercise the real origin locally, set `ASM_TEST_NGINX` to an installed nginx executable:

```sh
ASM_TEST_NGINX=/absolute/path/to/nginx PYTHONPATH=tests \
  python3 -m unittest test_registry_log_import.RegistryLogImportTests.test_actual_nginx_transfers_emit_only_attributable_private_log_fields -v
```

On 7 November 2026, this check passed with nginx 1.30.6 on Apple Silicon macOS.
It exercised real HTTP responses, a deliberately interrupted transfer, privacy fields, and import of the resulting logs.
The source archive SHA-256 was `3cf46f5ed7504d460125866b7bea99fb357f31d887e2e63b35503310e9b8b6c8`.
The tested executable SHA-256 was `24e800750f32ed101f8af74fd08e55688777b8c232767aa6a4291d4db61089f5`.
The local build used existing PCRE2 libraries and omitted the gzip module.
The configuration enables no response compression.
This check did not qualify ingress TLS, CDN behavior, Linux containers, or production capacity.

The first source extraction failed because the host had insufficient disk space.
A later 8 MiB interruption fixture hit the same limit.
The retained test uses a throttled 256 KiB fixture.
An initial configuration check rejected a redundant gzip directive because that module was absent.
Removing that directive retained nginx's default disabled compression.

References reviewed on 7 November 2026:

- [nginx log format and JSON escaping](https://nginx.org/en/docs/http/ngx_http_log_module.html).
- [nginx aliases, byte ranges, request completion, and time variables](https://nginx.org/en/docs/http/ngx_http_core_module.html).
- [nginx compression defaults](https://nginx.org/en/docs/http/ngx_http_gzip_module.html).
- [nginx 1.30.6 source archive](https://nginx.org/download/nginx-1.30.6.tar.gz).

## Local S3 compatibility check

`tests/test_registry_storage_s3.py` adds an explicit, optional provider check.
It accepts only a numeric loopback endpoint with an explicit port.
It requires a dedicated bucket whose name starts with `asm-test-`.
It requires explicit synthetic credentials and the `local-disposable-s3-v1` scope.
It does not create buckets, change permissions, or use ambient account credentials.
Each test writes and deletes only its random fixture prefix in that bucket.

Prepare an isolated local S3 service and its test bucket first.
Keep its console disabled and its listening port bound to loopback.
Use unique synthetic credentials for that fixture.
Create a private configuration file with these fields:

```json
{
  "scope": "local-disposable-s3-v1",
  "endpoint": "http://127.0.0.1:9000",
  "bucket": "asm-test-qualification",
  "access_key": "asm-test-CHANGE-ME",
  "secret_key": "CHANGE_ME_WITH_A_SYNTHETIC_TEST_SECRET",
  "region": "us-east-1"
}
```

Replace the endpoint, bucket, and credential placeholders with the fixture's values.
Set its configuration file to mode `0600` inside an owned, private directory.
Install the pinned `requirements-storage.txt` dependencies before running the checks.

```sh
ASM_S3_TEST_CONFIG=/private/asm-test/config.json PYTHONPATH=tests \
  python3 -m unittest test_registry_storage_s3 -v
```

Without that configuration, the five live checks are skipped.
The two configuration checks can run without a service.
The live suite checks raw HTTP 412 and 403 responses, concurrent conditional creation, immutable retries, corrupt bytes, and stale metadata updates.
It also checks that an unavailable connection preserves the previous metadata head.
An ETag remains a comparison token; artifact validation uses expected bytes and SHA-256.

All seven checks passed on 7 November 2026 against official RustFS 1.0.4 in Linux AMD64 mode.
The image digest was `sha256:ed9210d6411d77ffceb70d94b964a3cb7d225983368bc25bebe01e995293dcc2`.
The executable reported source commit `46337942d55f3a8e6a97b147ca98d9ea8115555d`.
The client used Python 3.14.6, boto3 1.43.123, and botocore 1.43.126.
The fixture used a read-only root, temporary in-memory storage, loopback delivery, 384 MiB memory, and half a CPU.
It was removed after the checks.
An earlier Docker inventory exceeded its 15-second deadline while the local Linux guest was unresponsive.
The inventory succeeded after the guest recovered; no provider test result came from that failed attempt.
This result does not qualify multiple nodes, recovery, production access controls, TLS, or public delivery.
See the [official RustFS release](https://github.com/rustfs/rustfs/releases/tag/1.0.4) and [container instructions](https://docs.rustfs.com/en/installation/container/docker).
