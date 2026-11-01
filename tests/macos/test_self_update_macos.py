"""Run authenticated-update behavior on APFS with real Darwin file operations.
Transport/signature fixtures test policy and failures, not Sigstore cryptography.
"""
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_self_update as shared
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import macos

class MacSelfUpdateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.suite_temp = tempfile.TemporaryDirectory(prefix='mac-self-', dir=ROOT / 'build')
        cls.fixture = Path(cls.suite_temp.name)
        cls.source = cls.fixture / 'source'
        cls.source.mkdir()
        transport = re.sub(r'with socket.socket.*?(?=if state.get\("hold"\))',
                           'assert "GH_TOKEN" not in os.environ or state.get("allow_ambient_transport")\n', shared.TRANSPORT, flags=re.S)
        for name, body in [('curl-fixture', transport), ('gh-fixture', shared.VERIFIER.replace('assert set(os.environ) <= allowed', 'allowed.add("__CF_USER_TEXT_ENCODING")\nassert set(os.environ) <= allowed'))]:
            path = cls.fixture / name
            path.write_text(f'#!{sys.executable}\n' + body)
            path.chmod(0o755)
        cls.original_source = macos.prepare(ROOT / 'cli/aarch64/asm.s').replace(
            'registry_curl: .asciz "/usr/bin/curl"', f'registry_curl: .asciz "{cls.fixture}/curl-fixture"').replace(
            'self_gh_path: .asciz "/opt/homebrew/bin/gh"', f'self_gh_path: .asciz "{cls.fixture}/gh-fixture"')
        cls.current_bytes = cls.compile_version(shared.CURRENT)
        cls.next_bytes = cls.compile_version(shared.NEXT)
        original = cls.original_source
        cls.original_source = original.replace('.equ SELF_VERIFIER_DEADLINE_SECONDS, 120', '.equ SELF_VERIFIER_DEADLINE_SECONDS, 1')
        cls.short_deadline_bytes = cls.compile_version(shared.CURRENT)
        cls.original_source = original

    @classmethod
    def compile_version(cls, version):
        source = cls.source / 'asm.s'
        source.write_text(cls.original_source.replace(shared.CURRENT, version))
        output = cls.source / 'asm'
        subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-mmacosx-version-min=15.0', '-Wl,-no_uuid',
                        '-o', str(output), str(source)], check=True, capture_output=True)
        return output.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.suite_temp.cleanup()

    setUp = shared.SelfUpdateTests.setUp
    save = shared.SelfUpdateTests.save
    row = shared.SelfUpdateTests.row
    write_index = shared.SelfUpdateTests.write_index
    cli = shared.SelfUpdateTests.cli
    calls = shared.SelfUpdateTests.calls
    unchanged = shared.SelfUpdateTests.unchanged

# Keep the same assertions on native Darwin. Linux seccomp/root-only injection
# remains in the Linux suite; Darwin adds separate running-vnode identity tests.
for name in [
    'test_real_replacement_has_three_verified_bindings_and_no_token_inheritance',
    'test_exact_version_and_preserved_private_executable_mode',
    'test_equal_version_is_a_noop_and_downgrade_is_refused_without_network',
    'test_latest_does_not_claim_freshness_and_refuses_stale_lower_version',
    'test_invalid_syntax_and_runtime_override_options_are_rejected',
    'test_requires_direct_installation_and_refuses_hardlinks_or_unsafe_permissions',
    'test_symlink_installation_is_refused_without_replacing_target',
    'test_every_ancestor_requires_safe_writes_and_sticky_is_not_generic',
    'test_verifier_deadline_resets_ignored_and_unblocks_inherited_alarm',
    'test_missing_or_old_verifier_fails_closed_before_network',
    'test_proxy_values_are_bounded_before_any_child_tool',
    'test_network_and_integrity_failures_keep_old_binary',
    'test_attestation_failure_or_wrong_absent_multiple_id_keeps_old_binary',
    'test_attested_metadata_and_source_binding_must_match',
    'test_malformed_manifest_and_wrong_host_or_origin_keep_old_binary',
    'test_displaced_home_is_refused_before_attestation_verifier',
    'test_displaced_home_is_refused_before_final_commit',
    'test_concurrent_updates_are_serialized_without_interrupting_normal_commands',
    'test_changed_destination_is_not_overwritten_after_download',
]:
    setattr(MacSelfUpdateTests, name, getattr(shared.SelfUpdateTests, name))

MacSelfUpdateTests.hold_update = shared.SelfUpdateTests.hold_update
MacSelfUpdateTests.assert_displaced_installation_is_refused = shared.SelfUpdateTests.assert_displaced_installation_is_refused

# Stop immediately after the OS loads the executable, before updater checks.
# Replacing its pathname must not authorize replacement of the new inode.
def test_displaced_running_vnode_is_refused(self):
    import os
    import signal
    stopped = self.original_source.replace('_main:\n', '_main:\n    ARM_CALL mac_test_stop\n', 1)
    stopped += '''
.text
mac_test_stop:
    MAC_SAVE
    bl _getpid
    mov x1, #17
    bl _kill
    MAC_RETURN
'''
    source = self.work / 'stopped.s'
    source.write_text(stopped)
    subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-mmacosx-version-min=15.0', '-o', str(self.installed), str(source)], check=True, capture_output=True)
    process = subprocess.Popen([str(self.installed), 'self', 'update'], cwd=self.work, env=self.env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    pid, status = os.waitpid(process.pid, os.WUNTRACED)
    self.assertTrue(os.WIFSTOPPED(status))
    unrelated = self.work / 'unrelated'
    unrelated.write_bytes(self.next_bytes)
    unrelated.chmod(0o755)
    unrelated.replace(self.installed)
    os.kill(process.pid, signal.SIGCONT)
    stdout, stderr = process.communicate(timeout=10)
    self.assertEqual(process.returncode, 1, (stdout, stderr))
    self.assertEqual(self.installed.read_bytes(), self.next_bytes)
    self.assertEqual(self.calls(), [])

MacSelfUpdateTests.test_displaced_running_vnode_is_refused = test_displaced_running_vnode_is_refused

def test_private_tmp_accepts_only_a_protected_owned_child(self):
    import os
    with tempfile.TemporaryDirectory(prefix='asm-self-native-', dir='/private/tmp') as directory:
        self.home = Path(directory) / 'home'
        self.bin_dir = self.home / '.local/bin'
        self.bin_dir.mkdir(parents=True)
        self.installed = self.bin_dir / 'asm'
        self.installed.write_bytes(self.current_bytes)
        self.installed.chmod(0o755)
        self.env['HOME'] = str(self.home)
        self.cli('self', 'update')
        self.assertEqual(self.installed.read_bytes(), self.next_bytes)

MacSelfUpdateTests.test_private_tmp_accepts_only_a_protected_owned_child = test_private_tmp_accepts_only_a_protected_owned_child

def test_acl_write_grants_are_refused_and_deny_entries_are_accepted(self):
    for path, grant in [(self.home, 'everyone allow delete_child'), (self.installed, 'everyone allow write')]:
        with self.subTest(path=path):
            subprocess.run(['/bin/chmod', '+a', grant, str(path)], check=True)
            try:
                self.cli('self', 'update', shared.CURRENT, code=1)
                self.unchanged()
                self.assertEqual(self.calls(), [])
            finally:
                subprocess.run(['/bin/chmod', '-N', str(path)], check=True)
    subprocess.run(['/bin/chmod', '+a', 'everyone deny delete', str(self.home)], check=True)
    try:
        self.cli('self', 'update', shared.CURRENT)
        self.unchanged()
    finally:
        subprocess.run(['/bin/chmod', '-N', str(self.home)], check=True)

MacSelfUpdateTests.test_acl_write_grants_are_refused_and_deny_entries_are_accepted = test_acl_write_grants_are_refused_and_deny_entries_are_accepted

for name in ['test_kernel_limit_stops_oversized_writes_independent_of_curl_size_flags',
             'test_registry_fetch_has_the_same_kernel_download_bound',
             'test_download_preserves_stricter_inherited_soft_and_hard_limits']:
    setattr(MacSelfUpdateTests, name, getattr(shared.SelfUpdateTests, name))


def test_native_update_never_executes_the_candidate(self):
    import hashlib
    marker = self.work / 'candidate-ran'
    source = self.work / 'candidate.s'
    source.write_text('''
.global _main
.text
_main:
    adrp x0, marker@PAGE
    add x0, x0, marker@PAGEOFF
    mov x1, #384
    bl _creat
    mov x0, #0
    bl _exit
.data
marker: .asciz "''' + str(marker) + '"\n')
    binary = self.work / 'candidate'
    subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-mmacosx-version-min=15.0', '-o', str(binary), str(source)], check=True)
    payload = binary.read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    (self.fixture / 'artifact').write_bytes(payload)
    self.record['assets'][0].update(bytes=len(payload), sha256=digest)
    self.write_index(self.row(digest=digest, size=len(payload)))
    self.save()
    self.cli('self', 'update')
    self.assertEqual(self.installed.read_bytes(), payload)
    self.assertFalse(marker.exists())

MacSelfUpdateTests.test_native_update_never_executes_the_candidate = test_native_update_never_executes_the_candidate


def test_registry_fetch_kernel_limit_on_native_darwin(self):
    # Ordinary registry curl keeps the existing caller-environment contract.
    # The updater transport and every verifier invocation still enforce clean
    # environment assertions in the fixtures.
    self.state["allow_ambient_transport"] = True
    self.save()
    shared.SelfUpdateTests.test_registry_fetch_has_the_same_kernel_download_bound(self)

MacSelfUpdateTests.test_registry_fetch_has_the_same_kernel_download_bound = test_registry_fetch_kernel_limit_on_native_darwin
