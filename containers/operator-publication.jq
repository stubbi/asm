# SPDX-License-Identifier: AGPL-3.0-or-later
# Consume exactly one report and one inspected image from this workflow run.
# Publication uses this policy from the trusted exact-main checkout, not an artifact.
def integer: if type == "number" then . >= 0 and floor == . else false end;
def nonempty: if type == "string" then length > 0 else false end;
def hash: if type == "string" then test("^[0-9a-f]{64}$") else false end;
def digest: if type == "string" then test("^sha256:[0-9a-f]{64}$") else false end;
def source_files: [
  "LICENSE", "LICENSING.md", "tools/registry.py", "tools/registry_admin.py",
  "tools/operator_entrypoint.py", "tools/prepare_operator.py",
  "server/catalog/schema.sql", "server/catalog/reader-guard.sql", "server/catalog/read-exports.sql"
];
def routes: ["/registry/v1/index.tsv", "/registry/v1/index-macos.tsv",
  "/registry/v1/index-all.tsv", "/registry/v1/index.json"];

length == 1 and ($image | length == 1) and
(.[0] as $report | $image[0] as $runtime |
  ($report | type == "object") and
  ($report.schema == 1) and ($report.status == "pass") and
  ($report.scope == "explicit-registry-operator") and
  ($report.os == "linux") and ($report.architecture == "amd64") and
  ($report.execution == "native") and ($report.source_revision == $revision) and
  ($report.tests_run | integer) and ($report.tests_run >= 52) and
  ($report.applicable_tests_run | integer) and ($report.applicable_tests_run >= 51) and
  ($report.applicable_tests_skipped == 0) and
  ($report.not_applicable | type == "array") and
  ($report.not_applicable | length <= 1) and
  ($report.tests_run - $report.applicable_tests_run == ($report.not_applicable | length)) and
  all($report.not_applicable[];
    .id == "test_database.CatalogDatabaseTests.test_extended_acl_on_private_key_cannot_reach_mutation" and
    (.reason | if type == "string" then contains("macOS") else false end)) and
  ($report.security == {
    uid: 65532, gid: 65532, projected_reader_gid: 65532, read_only_root: true,
    effective_capabilities: 0, no_new_privileges: true, cluster_token: false
  }) and
  ($report.final_compiler_and_postgresql_server_absent == true) and
  ($report.runtime_image_id | digest) and
  ($report.qualification_image_id | digest) and
  ($report.qualification_image_id != $report.runtime_image_id) and
  ($runtime.Id == $report.runtime_image_id) and
  ($runtime.Architecture == "amd64") and ($runtime.Os == "linux") and
  ($runtime.Config.User == "65532:65532") and
  ($runtime.Config.Entrypoint == ["/usr/bin/python3", "-I", "/app/tools/operator_entrypoint.py"]) and
  ($runtime.Config.Cmd == ["--help"]) and
  ($runtime.Config.Labels["org.opencontainers.image.revision"] == $revision) and
  ($runtime.Config.Labels["org.opencontainers.image.source"] == "https://github.com/stubbi/asm") and
  ($runtime.Config.Labels["org.opencontainers.image.licenses"] == "AGPL-3.0-or-later") and
  ($runtime.RootFS.Layers | type == "array") and
  ($runtime.RootFS.Layers | length > 0) and all($runtime.RootFS.Layers[]; digest) and
  ($report.source.schema == 1) and
  ($report.source.repository == "https://github.com/stubbi/asm") and
  ($report.source.source_revision == $revision) and
  ($report.source.bundle_sha256 | hash) and
  ($report.source.bundle_bytes | integer) and
  ($report.source.bundle_bytes > 0 and $report.source.bundle_bytes <= 67108864) and
  ($report.source.files | type == "object") and
  (($report.source.files | keys) == (source_files | sort)) and
  all($report.source.files[]; hash) and
  ($report.runtime_files | type == "object") and all($report.runtime_files[]; hash) and
  all(source_files[]; . as $path |
    $report.runtime_files["/app/" + $path] == $report.source.files[$path]) and
  all(["/app/SOURCE.json", "/opt/asm/postgres/bin/psql", "/usr/bin/python3", "/usr/bin/git"][];
    . as $path | $report.runtime_files[$path] | hash) and
  ($report.plan.schema == 1) and
  ($report.plan.acceptance_repository == "https://github.com/stubbi/asm") and
  ($report.plan.acceptance_commit == $revision) and
  ($report.plan.expected_revision == 0) and
  ($report.plan.record_count | integer) and
  ($report.plan.records_sha256 | hash) and ($report.plan.plan_sha256 | hash) and
  ($report.plan.validator_sha256 == $report.source.files["tools/registry.py"]) and
  ($report.plan.artifact_bytes_checked == false) and
  ($report.plan.exports | type == "object") and
  (($report.plan.exports | keys) == (routes | sort)) and
  all(routes[]; . as $route | $report.plan.exports[$route] |
    (.sha256 | hash) and (.bytes | integer) and (.bytes > 0) and
    (.bytes <= (if $route == "/registry/v1/index.json" then 4194304 else 1048576 end))) and
  ($report.database_fixture_version == "16.15") and
  ($report.loaded_libraries.libpq == "16.15") and
  ($report.loaded_libraries.OpenSSL | nonempty) and
  ($report.postgresql_source == {
    version: "16.15", url: "https://ftp.postgresql.org/pub/source/v16.15/postgresql-16.15.tar.bz2",
    sha256: "c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed"
  }) and
  ($report.resolved_packages | type == "array") and
  ($report.resolved_packages | length > 0) and
  all($report.resolved_packages[];
    (.package | nonempty) and (.version | nonempty) and
    (.source_package | nonempty) and (.source_version | nonempty) and
    (.source_index | if type == "string" then startswith("https://snapshot.debian.org/package/") else false end)) and
  all(["git", "python3", "libssl3t64", "libc6"][]; . as $name |
    [$report.resolved_packages[] | select((.package | split(":")[0]) == $name)] | length == 1)
)
