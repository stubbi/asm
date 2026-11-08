"""Storage contract tests; no external bucket or credentials are used.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from importlib import util
from io import BytesIO
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import registry


class S3Failure(Exception):
    def __init__(self, code, status):
        self.response = {"Error": {"Code": code}, "ResponseMetadata": {"HTTPStatusCode": status}}
        super().__init__("secret-provider-detail")


class FakeS3:
    """Only the S3 object operation boundary is replaced in these tests."""

    def __init__(self):
        self.objects = {}
        self.generation = 0
        self.failure = None
        self.corrupt_write = False

    def get_object(self, *, Bucket, Key):
        if self.failure:
            raise self.failure
        if Key not in self.objects:
            raise S3Failure("NoSuchKey", 404)
        data, token = self.objects[Key]
        return {"Body": BytesIO(data), "ContentLength": len(data), "ETag": token}

    def put_object(self, *, Bucket, Key, Body, ContentLength, ChecksumSHA256,
                   ContentType, CacheControl, IfNoneMatch=None, IfMatch=None):
        if self.failure:
            raise self.failure
        if IfNoneMatch == "*" and Key in self.objects:
            raise S3Failure("PreconditionFailed", 412)
        if IfMatch is not None and (Key not in self.objects or self.objects[Key][1] != IfMatch):
            raise S3Failure("PreconditionFailed", 412)
        if IfNoneMatch != "*" and IfMatch is None:
            raise AssertionError("unconditional writes are forbidden")
        data = Body.read() if hasattr(Body, "read") else Body
        if len(data) != ContentLength:
            raise AssertionError("incorrect transfer length")
        self.generation += 1
        token = '"opaque-%s"' % self.generation
        self.objects[Key] = (b"!" * len(data) if self.corrupt_write else data, token)
        return {"ETag": token, "ResponseMetadata": {"HTTPStatusCode": 200}}


class RegistryStorageTests(unittest.TestCase):
    def setUp(self):
        import registry_storage
        self.storage = registry_storage
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "source"
        self.source.write_bytes(b"abc")
        # SHA-256's standard abc test vector, independent of the implementation.
        self.digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    def local(self):
        return self.storage.LocalBlobStore(self.directory / "objects")

    def remote(self, client=None, **options):
        client = client or FakeS3()
        return self.storage.S3BlobStore("asm-test", client=client, **options), client

    def test_local_creation_is_conditional_and_repeat_verifies_existing_bytes(self):
        store = self.local()
        self.assertTrue(store.put_blob(self.source, self.digest, 3))
        self.assertFalse(store.put_blob(self.source, self.digest, 3))
        self.assertEqual(store.get_blob(self.digest, 3), b"abc")
        path = self.directory / "objects/blobs/sha256" / self.digest
        self.assertEqual(path.read_bytes(), b"abc")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual([p.name for p in path.parent.iterdir()], [self.digest])

    def test_only_absent_blobs_raise_missing_blob(self):
        self.assertTrue(hasattr(self.storage,"MissingBlob"),"storage must distinguish absent blobs from failed reads")
        for store in (self.local(),self.remote()[0]):
            with self.subTest(store=type(store).__name__), self.assertRaises(self.storage.MissingBlob):
                store.get_blob(self.digest,3)
        store,client = self.remote()
        for failure in (S3Failure("AccessDenied",403),S3Failure("InternalError",500),OSError("network failure")):
            client.failure = failure
            with self.subTest(failure=type(failure).__name__), self.assertRaises(registry.RegistryError) as raised:
                store.get_blob(self.digest,3)
            self.assertNotIsInstance(raised.exception,self.storage.MissingBlob)
        store = self.local()
        store.put_blob(self.source,self.digest,3)
        (self.directory/"objects/blobs/sha256"/self.digest).write_bytes(b"bad")
        with self.assertRaises(registry.RegistryError) as raised:
            store.get_blob(self.digest,3)
        self.assertNotIsInstance(raised.exception,self.storage.MissingBlob)

    def test_changed_source_and_wrong_size_never_create_remote_objects(self):
        store, client = self.remote()
        for digest, size in (("0" * 64, 3), (self.digest, 2), (self.digest, 4)):
            with self.subTest(digest=digest, size=size), self.assertRaises(registry.RegistryError):
                store.put_blob(self.source, digest, size)
        self.assertEqual(client.objects, {})

    def test_local_corruption_is_preserved_and_refused(self):
        store = self.local()
        store.put_blob(self.source, self.digest, 3)
        path = self.directory / "objects/blobs/sha256" / self.digest
        path.write_bytes(b"bad")
        with self.assertRaises(registry.RegistryError):
            store.put_blob(self.source, self.digest, 3)
        with self.assertRaises(registry.RegistryError):
            store.get_blob(self.digest, 3)
        self.assertEqual(path.read_bytes(), b"bad")

    def test_remote_existing_bytes_are_checked_without_trusting_etag(self):
        store, client = self.remote(prefix="asm")
        self.assertTrue(store.put_blob(self.source, self.digest, 3))
        self.assertFalse(store.put_blob(self.source, self.digest, 3))
        self.assertEqual(store.get_blob(self.digest, 3), b"abc")
        key = "asm/blobs/sha256/" + self.digest
        client.objects[key] = (b"bad", '"' + self.digest + '"')
        with self.assertRaises(registry.RegistryError):
            store.put_blob(self.source, self.digest, 3)
        self.assertEqual(client.objects[key][0], b"bad")

    def test_remote_success_requires_readback_of_actual_new_bytes(self):
        store, client = self.remote()
        client.corrupt_write = True
        with self.assertRaises(registry.RegistryError):
            store.put_blob(self.source, self.digest, 3)

    def test_remote_network_failure_and_unsupported_conditions_fail_closed(self):
        for failure in (OSError("secret-provider-detail"), S3Failure("NotImplemented", 501),
                        S3Failure("ConditionalRequestConflict", 409)):
            store, client = self.remote()
            client.failure = failure
            with self.subTest(failure=type(failure).__name__), self.assertRaises(registry.RegistryError) as raised:
                store.put_blob(self.source, self.digest, 3)
            self.assertNotIn("secret-provider-detail", str(raised.exception))
            self.assertEqual(client.objects, {})

    def test_blob_bounds_and_malformed_digests_fail_before_storage(self):
        store, client = self.remote()
        for digest, size in (("../escape", 3), (self.digest.upper(), 3), (self.digest, 0),
                             (self.digest, True), (self.digest, 64 * 1024 * 1024 + 1)):
            with self.subTest(digest=digest, size=size), self.assertRaises(registry.RegistryError):
                store.put_blob(self.source, digest, size)
        self.assertEqual(client.objects, {})

    def test_local_path_attacks_do_not_follow_links_or_overwrite_targets(self):
        outside = self.directory / "outside"
        outside.mkdir()
        (outside / "sentinel").write_bytes(b"keep")
        linked_root = self.directory / "linked"
        linked_root.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(registry.RegistryError):
            self.storage.LocalBlobStore(linked_root / "objects")
        source_link = self.directory / "source-link"
        source_link.symlink_to(self.source)
        store = self.local()
        with self.assertRaises(registry.RegistryError):
            store.put_blob(source_link, self.digest, 3)
        (self.directory / "objects/blobs").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(registry.RegistryError):
            store.put_blob(self.source, self.digest, 3)
        self.assertEqual((outside / "sentinel").read_bytes(), b"keep")
        self.assertEqual(sorted(p.name for p in outside.iterdir()), ["sentinel"])

    def test_source_fifo_and_linked_ancestor_are_rejected_without_blocking(self):
        store = self.local()
        fifo = self.directory / "fifo"
        os.mkfifo(fifo)
        with self.assertRaises(registry.RegistryError):
            store.put_blob(fifo, self.digest, 3)
        alias = self.directory / "alias"
        alias.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaises(registry.RegistryError):
            store.put_blob(alias / "source", self.digest, 3)

    def test_existing_public_storage_root_is_refused_without_chmod(self):
        root = self.directory / "public"
        root.mkdir(mode=0o755)
        with self.assertRaises(registry.RegistryError):
            self.storage.LocalBlobStore(root)
        self.assertEqual(root.stat().st_mode & 0o777, 0o755)

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended ACL fixture")
    def test_private_root_with_inheritable_acl_grants_is_refused_before_writing(self):
        root = self.directory / "acl-root"
        root.mkdir(mode=0o700)
        subprocess.run(["chmod", "+a", "everyone allow read,write,execute,file_inherit,directory_inherit", str(root)],
                       check=True, capture_output=True, timeout=5)
        with self.assertRaises(registry.RegistryError):
            self.storage.LocalBlobStore(root).create_object("head.json", b"private metadata")
        self.assertEqual(list(root.iterdir()), [])
        self.assertEqual(root.stat().st_mode & 0o777, 0o700)

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended ACL fixture")
    def test_acl_grants_on_nested_directory_or_object_preserve_and_refuse_existing_bytes(self):
        for directory_acl in (False, True):
            store = self.storage.LocalBlobStore(self.directory / str(directory_acl))
            store.create_object("snapshots/record.json", b"accepted")
            path = store.root / "snapshots/record.json"
            target = path.parent if directory_acl else path
            subprocess.run(["chmod", "+a", "everyone allow read,write,execute", str(target)],
                           check=True, capture_output=True, timeout=5)
            with self.subTest(directory=directory_acl), self.assertRaises(registry.RegistryError):
                store.read_object("snapshots/record.json", 1024)
            self.assertEqual(path.read_bytes(), b"accepted")

    def test_rejected_output_acl_cannot_advance_a_head_or_receive_bytes(self):
        store = self.local()
        token = store.compare_and_swap("head.json", b"accepted", None)
        original_open = os.open
        original_acl = getattr(registry, "reject_extended_acl", lambda descriptor: None)
        opened, sizes = {}, []
        def watch_open(path, *args, **kwargs):
            descriptor = original_open(path, *args, **kwargs)
            if str(path).startswith(".pending-"):
                opened["stage"] = descriptor
            return descriptor
        def reject_output(descriptor):
            if descriptor == opened.get("stage"):
                sizes.append(os.fstat(descriptor).st_size)
                raise registry.RegistryError("synthetic output ACL refusal")
            return original_acl(descriptor)
        with patch.object(self.storage.os, "open", side_effect=watch_open), \
                patch.object(registry, "reject_extended_acl", side_effect=reject_output, create=True):
            with self.assertRaises(registry.RegistryError):
                store.compare_and_swap("head.json", b"replacement", token)
        self.assertEqual(sizes, [0])
        self.assertEqual(store.read_object("head.json", 1024)[0], b"accepted")
        self.assertFalse(any(path.name.startswith(".pending-") for path in store.root.rglob("*")))

    def test_generic_immutable_objects_and_head_cas_share_contract(self):
        for store in (self.local(), self.remote()[0]):
            with self.subTest(store=type(store).__name__):
                self.assertIsNone(store.read_object("heads/current.json", 1024))
                self.assertTrue(store.create_object("snapshots/first.json", b"one"))
                self.assertFalse(store.create_object("snapshots/first.json", b"one"))
                with self.assertRaises(registry.RegistryError):
                    store.create_object("snapshots/first.json", b"two")
                first = store.compare_and_swap("heads/current.json", b"one", None)
                self.assertEqual(store.read_object("heads/current.json", 1024), (b"one", first))
                with self.assertRaises(registry.RegistryError):
                    store.compare_and_swap("heads/current.json", b"stale", None)
                second = store.compare_and_swap("heads/current.json", b"two", first)
                self.assertNotEqual(first, second)
                with self.assertRaises(registry.RegistryError):
                    store.compare_and_swap("heads/current.json", b"stale", first)
                self.assertEqual(store.read_object("heads/current.json", 1024), (b"two", second))

    def test_generic_key_and_byte_limits_preserve_store(self):
        for store in (self.local(), self.remote()[0]):
            for key in ("../escape", "/absolute", "a//b", "a/./b", "a/../b", ".asm-storage.lock", "a\\b"):
                with self.subTest(store=type(store).__name__, key=key), self.assertRaises(registry.RegistryError):
                    store.create_object(key, b"x")
            with self.assertRaises(registry.RegistryError):
                store.create_object("oversized", b"x" * (4 * 1024 * 1024 + 1))
            self.assertIsNone(store.read_object("oversized", 4 * 1024 * 1024))
            head = store.compare_and_swap("head.json", b"old", None)
            with self.assertRaises(registry.RegistryError):
                store.compare_and_swap("head.json", b"x" * (4 * 1024 * 1024 + 1), head)
            self.assertEqual(store.read_object("head.json", 3), (b"old", head))
            store.create_object("bounded", b"abc")
            with self.assertRaises(registry.RegistryError):
                store.read_object("bounded", 2)
            self.assertEqual(store.read_object("bounded", 3)[0], b"abc")

    def test_maximum_release_target_path_fits_storage_without_changing_archive_paths(self):
        key = ("targets/registries/" + "1" * 32 + "/releases/" + "a" * 39 + "/" + "b" * 64 + "/" +
               "c" * 64 + ".2147483647.2147483647.2147483647.json")
        for store in (self.local(), self.remote()[0]):
            store.create_object(key, b"retained manifest")
            self.assertEqual(store.read_object(key, 100)[0], b"retained manifest")
        with self.assertRaises(registry.RegistryError):
            registry.portable_path(key)
        long_key = "/".join(["a" * 200] * 6)
        for store in (self.local(), self.remote()[0]):
            with self.assertRaises(registry.RegistryError):
                store.create_object(long_key, b"x")

    def test_s3_prefix_and_object_share_the_same_total_key_limit(self):
        store, client = self.remote(prefix="/".join(["a" * 200] * 5))
        with self.assertRaises(registry.RegistryError):
            store.create_object("b" * 100, b"x")
        self.assertEqual(client.objects, {})

    def test_valid_package_names_use_storage_keys_without_archive_reserved_name_rules(self):
        for name in ("con/hello", "aux/hello", "example/con"):
            registry.package_name(name)
            key = "targets/registries/" + "1" * 32 + "/releases/" + name + "/" + "a" * 64 + ".1.0.0.json"
            for store in (self.local(), self.remote()[0]):
                store.create_object(key, b"valid package metadata")
                self.assertEqual(store.read_object(key, 100)[0], b"valid package metadata")
        with self.assertRaises(registry.RegistryError):
            registry.portable_path("con/file.s")

    def test_metadata_accepts_a_four_mib_export_without_raising_blob_limits(self):
        data = b"x" * (4 * 1024 * 1024)
        for store in (self.local(), self.remote()[0]):
            with self.subTest(store=type(store).__name__):
                self.assertTrue(store.create_object("snapshots/export.json", data))
                self.assertFalse(store.create_object("snapshots/export.json", data))
                self.assertEqual(store.read_object("snapshots/export.json", 4 * 1024 * 1024)[0], data)
                with self.assertRaises(registry.RegistryError):
                    store.read_object("snapshots/export.json", 1024 * 1024)
                self.assertTrue(store.put_blob(self.source, self.digest, 3))
                self.assertEqual(store.get_blob(self.digest, 3), b"abc")

    def test_generic_operations_cannot_replace_an_immutable_blob(self):
        for store in (self.local(), self.remote()[0]):
            store.put_blob(self.source, self.digest, 3)
            key = "blobs/sha256/" + self.digest
            for operation in (lambda: store.create_object(key, b"bad"),
                              lambda: store.compare_and_swap(key, b"bad", self.digest)):
                with self.subTest(store=type(store).__name__), self.assertRaises(registry.RegistryError):
                    operation()
            self.assertEqual(store.get_blob(self.digest, 3), b"abc")

    def test_hardlinked_or_public_local_files_are_refused_without_replacement(self):
        for attack in ("hardlink", "public"):
            store = self.storage.LocalBlobStore(self.directory / attack)
            store.put_blob(self.source, self.digest, 3)
            path = self.directory / attack / "blobs/sha256" / self.digest
            if attack == "hardlink":
                (self.directory / "outside-hardlink").hardlink_to(path)
            else:
                path.chmod(0o644)
            with self.subTest(attack=attack), self.assertRaises(registry.RegistryError):
                store.put_blob(self.source, self.digest, 3)
            self.assertEqual(path.read_bytes(), b"abc")

    def test_incomplete_or_oversized_remote_body_is_rejected_and_closed(self):
        for advertised, data in ((3, b"ab"), (2, b"abc"), (4, b"abc")):
            body = BytesIO(data)
            client = FakeS3()
            client.get_object = lambda **kwargs: {"Body": body, "ContentLength": advertised, "ETag": '"opaque"'}
            store, _ = self.remote(client)
            with self.subTest(advertised=advertised, data=data), self.assertRaises(registry.RegistryError):
                store.get_blob(self.digest, 3)
            self.assertTrue(body.closed)

    def test_atomic_local_failure_keeps_the_old_head_and_removes_staging(self):
        store = self.local()
        first = store.compare_and_swap("heads/current.json", b"one", None)
        with patch.object(self.storage.os, "replace", side_effect=OSError("injected failure")):
            with self.assertRaises(registry.RegistryError):
                store.compare_and_swap("heads/current.json", b"two", first)
        self.assertEqual(store.read_object("heads/current.json", 1024), (b"one", first))
        self.assertEqual([p.name for p in (self.directory / "objects/heads").iterdir()], ["current.json"])

    def test_remote_endpoint_policy_rejects_plaintext_and_embedded_secrets(self):
        for endpoint in ("http://example.com", "https://user:secret@example.com", "https://example.com/?token=secret",
                         "https://example.com/#fragment", "https://example.com/path", "file:///tmp"):
            with self.subTest(endpoint=endpoint), self.assertRaises(registry.RegistryError):
                self.remote(endpoint_url=endpoint)
        self.remote(endpoint_url="https://s3.example.com")
        self.remote(endpoint_url="http://127.0.0.1:9000")

    @unittest.skipUnless(util.find_spec("boto3"), "optional S3 SDK is not installed")
    def test_pinned_sdk_models_accept_condition_checksum_and_verified_readback(self):
        import boto3
        from botocore.stub import ANY, Stubber
        session = boto3.Session(aws_access_key_id="test", aws_secret_access_key="test", region_name="us-east-1")
        # A configured ambient endpoint must not redirect operator credentials.
        with patch.dict(os.environ, {"AWS_ENDPOINT_URL": "http://127.0.0.1:1"}):
            store = self.storage.S3BlobStore("asm-test", session=session)
        self.assertTrue(store.client.meta.endpoint_url.startswith("https://"))
        with Stubber(store.client) as stub:
            stub.add_response("put_object", {"ETag": '"opaque"'}, {
                "Bucket": "asm-test", "Key": "blobs/sha256/" + self.digest,
                "Body": ANY, "ContentLength": 3,
                "ChecksumSHA256": "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=",
                "ContentType": "application/octet-stream",
                "CacheControl": "public,max-age=31536000,immutable", "IfNoneMatch": "*"})
            stub.add_response("get_object", {"Body": BytesIO(b"abc"), "ContentLength": 3, "ETag": '"opaque"'},
                              {"Bucket": "asm-test", "Key": "blobs/sha256/" + self.digest})
            self.assertTrue(store.put_blob(self.source, self.digest, 3))
            stub.add_response("put_object", {"ETag": '"next"'}, {
                "Bucket": "asm-test", "Key": "head.json", "Body": ANY, "ContentLength": 3,
                "ChecksumSHA256": "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=",
                "ContentType": "application/octet-stream", "CacheControl": "no-store", "IfMatch": '"previous"'})
            self.assertEqual(store.compare_and_swap("head.json", b"abc", '"previous"'), '"next"')
            stub.assert_no_pending_responses()


if __name__ == "__main__":
    unittest.main()
