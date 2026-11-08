"""Opt-in checks against an explicitly configured disposable local S3 service.

No account, bucket, policy, or public service is created by these tests.
Set ASM_S3_TEST_CONFIG to a private JSON file; see deploy/mirror/README.md.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from concurrent.futures import ThreadPoolExecutor
import ipaddress
import os
from pathlib import Path
import re
import socket
import sys
import tempfile
import threading
import unittest
from urllib.parse import urlsplit
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry
import registry_storage as storage


def local_fixture(path):
    path = storage._absolute(path)
    with storage._directory(path.parent, private=True) as directory:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    with os.fdopen(descriptor, "rb") as stream:
        info = storage._regular(stream.fileno(), 4096, private=True)
        raw = stream.read(4097)
        registry.require(len(raw) == info.st_size, "local S3 fixture configuration changed")
    fields = {"scope", "endpoint", "bucket", "access_key", "secret_key", "region"}
    value = registry.exact_keys(registry.strict_json(raw), fields, fields, "local S3 fixture")
    registry.require(value["scope"] == "local-disposable-s3-v1", "select a disposable local S3 fixture")
    registry.require(isinstance(value["endpoint"], str), "local S3 endpoint must be text")
    endpoint = urlsplit(value["endpoint"])
    try:
        loopback = ipaddress.ip_address(endpoint.hostname).is_loopback
    except ValueError:
        loopback = False
    registry.require(loopback and endpoint.scheme in ("http", "https") and endpoint.port is not None
                     and endpoint.username is None and endpoint.password is None
                     and endpoint.path in ("", "/") and not endpoint.query and not endpoint.fragment,
                     "S3 qualification accepts only a numeric loopback endpoint with an explicit port")
    registry.require(isinstance(value["bucket"], str) and re.fullmatch(r"asm-test-[a-z0-9-]{1,40}", value["bucket"]),
                     "S3 qualification requires a dedicated asm-test bucket")
    registry.require(isinstance(value["access_key"], str) and value["access_key"].startswith("asm-test-")
                     and 8 <= len(value["access_key"]) <= 128
                     and isinstance(value["secret_key"], str) and 16 <= len(value["secret_key"]) <= 256,
                     "S3 qualification requires explicit synthetic test credentials")
    registry.require(isinstance(value["region"], str) and re.fullmatch(r"[a-z0-9-]{1,63}", value["region"]),
                     "S3 qualification requires an explicit region")
    return value


class LocalFixtureConfigurationTests(unittest.TestCase):
    def test_public_endpoint_and_existing_account_bucket_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "config.json"
            value = {"scope": "local-disposable-s3-v1", "endpoint": "http://127.0.0.1:9000", "bucket": "asm-test-fixture",
                     "access_key": "asm-test-fixture", "secret_key": "synthetic-test-secret", "region": "us-east-1"}
            for change in ({"endpoint": "https://s3.amazonaws.com"}, {"endpoint": "http://localhost:9000"},
                           {"endpoint": {}}, {"bucket": "existing-production-bucket"}, {"scope": "production"}):
                path.write_bytes(registry.json_bytes({**value, **change}))
                path.chmod(0o600)
                with self.subTest(change=change), self.assertRaises(registry.RegistryError):
                    local_fixture(path)

    def test_configuration_must_be_private_and_rejects_extra_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "config.json"
            value = {"scope": "local-disposable-s3-v1", "endpoint": "http://127.0.0.1:9000", "bucket": "asm-test-fixture",
                     "access_key": "asm-test-fixture", "secret_key": "synthetic-test-secret", "region": "us-east-1"}
            path.write_bytes(registry.json_bytes(value))
            path.chmod(0o644)
            with self.assertRaises(registry.RegistryError):
                local_fixture(path)
            path.chmod(0o600)
            path.write_bytes(registry.json_bytes({**value, "unexpected": "refused"}))
            with self.assertRaises(registry.RegistryError):
                local_fixture(path)


@unittest.skipUnless(os.environ.get("ASM_S3_TEST_CONFIG"), "select an explicit disposable localhost S3 fixture")
class LiveS3StorageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.configuration = local_fixture(Path(os.environ["ASM_S3_TEST_CONFIG"]))

    def client(self, *, invalid=False, endpoint=None):
        import boto3
        from botocore.config import Config
        cfg = self.configuration
        session = boto3.Session(aws_access_key_id="asm-test-invalid" if invalid else cfg["access_key"],
                                aws_secret_access_key="synthetic-invalid-secret" if invalid else cfg["secret_key"],
                                region_name=cfg["region"])
        client = session.client("s3", endpoint_url=endpoint or cfg["endpoint"], verify=True,
            config=Config(signature_version="s3v4", connect_timeout=2, read_timeout=5, proxies={},
                          retries={"total_max_attempts": 1}, ignore_configured_endpoint_urls=True,
                          s3={"addressing_style": "path"}))
        self.addCleanup(client.close)
        return client

    def setUp(self):
        self.sdk = self.client()
        self.bucket = self.configuration["bucket"]
        self.prefix = "asm-qualification/" + uuid.uuid4().hex
        self.store = storage.S3BlobStore(self.bucket, prefix=self.prefix, client=self.sdk)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.source = Path(self.temporary.name) / "blob"
        self.source.write_bytes(b"abc")
        self.digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        self.addCleanup(self.remove_fixture_objects)
        self.sdk.head_bucket(Bucket=self.bucket)

    def remove_fixture_objects(self):
        response = self.sdk.list_objects_v2(Bucket=self.bucket, Prefix=self.prefix + "/", MaxKeys=100)
        self.assertFalse(response.get("IsTruncated"), "fixture cleanup exceeded its object bound")
        for item in response.get("Contents", []):
            self.assertTrue(item["Key"].startswith(self.prefix + "/"))
            self.sdk.delete_object(Bucket=self.bucket, Key=item["Key"])

    def raw(self, suffix, data, **condition):
        return self.sdk.put_object(Bucket=self.bucket, Key=self.prefix + "/" + suffix, Body=data, **condition)

    def test_raw_concurrent_create_has_one_winner_and_one_http_412(self):
        from botocore.exceptions import ClientError
        barrier = threading.Barrier(2, timeout=3)
        def attempt(data):
            barrier.wait()
            try:
                self.raw("raw-create", data, IfNoneMatch="*")
                return 200
            except ClientError as error:
                self.assertEqual(error.response["Error"]["Code"], "PreconditionFailed")
                return error.response["ResponseMetadata"]["HTTPStatusCode"]
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(attempt, value) for value in (b"left", b"right")]
            self.assertEqual(sorted(future.result(timeout=10) for future in futures), [200, 412])
        self.assertIn(self.store.read_object("raw-create", 8)[0], (b"left", b"right"))

    def test_adapter_concurrent_blob_create_and_retry_preserve_exact_bytes(self):
        barrier = threading.Barrier(2, timeout=3)
        def attempt():
            barrier.wait()
            return self.store.put_blob(self.source, self.digest, 3)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(attempt) for i in range(2)]
            self.assertEqual(sorted(future.result(timeout=10) for future in futures), [False, True])
        self.assertFalse(self.store.put_blob(self.source, self.digest, 3))
        self.assertEqual(self.store.get_blob(self.digest, 3), b"abc")

    def test_corrupt_existing_bytes_fail_despite_a_claimed_digest_metadata_field(self):
        self.store.put_blob(self.source, self.digest, 3)
        key = self.prefix + "/blobs/sha256/" + self.digest
        previous = self.sdk.head_object(Bucket=self.bucket, Key=key)["ETag"]
        self.sdk.put_object(Bucket=self.bucket, Key=key, Body=b"bad", IfMatch=previous,
                            Metadata={"sha256": self.digest})
        with self.assertRaises(registry.RegistryError):
            self.store.put_blob(self.source, self.digest, 3)
        with self.assertRaises(registry.RegistryError):
            self.store.get_blob(self.digest, 3)
        result = self.sdk.get_object(Bucket=self.bucket, Key=key)
        with result["Body"] as stream:
            self.assertEqual(stream.read(4), b"bad")

    def test_metadata_cas_uses_the_observed_etag_and_refuses_stale_writes(self):
        from botocore.exceptions import ClientError
        first = self.store.compare_and_swap("head.json", b"first", None)
        second = self.store.compare_and_swap("head.json", b"second", first)
        self.assertNotEqual(first, second)
        self.assertEqual(self.store.read_object("head.json", 1024), (b"second", second))
        with self.assertRaises(storage.StorageConflict):
            self.store.compare_and_swap("head.json", b"stale", first)
        with self.assertRaises(ClientError) as raised:
            self.raw("head.json", b"raw-stale", IfMatch=first)
        self.assertEqual(raised.exception.response["ResponseMetadata"]["HTTPStatusCode"], 412)
        self.assertEqual(self.store.read_object("head.json", 1024), (b"second", second))
        self.assertTrue(self.store.create_object("snapshots/fixed.json", b"immutable"))
        self.assertFalse(self.store.create_object("snapshots/fixed.json", b"immutable"))
        with self.assertRaises(registry.RegistryError):
            self.store.create_object("snapshots/fixed.json", b"different")

    def test_http_403_and_connection_failure_cannot_change_the_existing_head(self):
        from botocore.exceptions import ClientError
        token = self.store.compare_and_swap("head.json", b"retained", None)
        denied = self.client(invalid=True)
        with self.assertRaises(ClientError) as raised:
            denied.put_object(Bucket=self.bucket, Key=self.prefix + "/head.json", Body=b"denied", IfMatch=token)
        self.assertEqual(raised.exception.response["ResponseMetadata"]["HTTPStatusCode"], 403)
        with socket.socket() as refusal:
            refusal.bind(("127.0.0.1", 0))
            unavailable = storage.S3BlobStore(self.bucket, prefix=self.prefix,
                client=self.client(endpoint="http://127.0.0.1:" + str(refusal.getsockname()[1])))
            with self.assertRaises(registry.RegistryError):
                unavailable.compare_and_swap("head.json", b"unavailable", token)
        self.assertEqual(self.store.read_object("head.json", 1024), (b"retained", token))


if __name__ == "__main__":
    unittest.main()
