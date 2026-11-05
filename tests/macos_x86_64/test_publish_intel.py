"""Publish the native-library dialect through the real Intel package boundary."""
import gzip
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
os.environ['ASM_TEST_TARGET'] = 'x86_64-macos'
ROOT = Path(__file__).resolve().parents[2]
ASM = ROOT / 'build/asm-x86_64-macos'


class IntelPublicationTests(unittest.TestCase):
    def test_native_library_source_requires_its_compile_only_checker(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as directory:
            work = Path(directory)
            manifest = ('[package]\nname = "hello"\nversion = "0.1.0"\n'
                        '[build]\nsource = "main.s"\ntarget = "x86_64-macos"\n'
                        'link = "c"\nlibraries = "m"\ncheck = "abi.c"\n')
            for include_checker in [False, True]:
                files = {'asm.toml': manifest.encode(), 'main.s': b'.global _main\n.text\n_main: ret\n',
                         'README.md': b'Intel Darwin native library source fixture.\n',
                         'LICENSE': (ROOT / 'LICENSES/MIT.txt').read_bytes()}
                if include_checker:
                    files['abi.c'] = b'_Static_assert(sizeof(void *) == 8, "LP64");\n'
                data = io.BytesIO()
                with tarfile.open(fileobj=data, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                    for name, content in sorted(files.items()):
                        entry = tarfile.TarInfo(name)
                        entry.mode = 0o644
                        entry.size = len(content)
                        archive.addfile(entry, io.BytesIO(content))
                payload = work / 'source.tar.gz'
                payload.write_bytes(gzip.compress(data.getvalue(), mtime=0))
                output = work / 'record.json'
                result = subprocess.run([str(ASM), 'publish', '--name', 'owner/hello', '--version', '0.1.0',
                    '--summary', 'Intel native library fixture.', '--license', 'MIT',
                    '--repository', 'https://github.com/owner/hello', '--commit', 'a' * 40,
                    '--source-path', '.', '--output', str(output), '--artifact', 'x86_64-macos', 'source',
                    str(payload), 'https://github.com/owner/hello/releases/download/v0.1.0/source.tar.gz'],
                    cwd=work, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0 if include_checker else 1, (result.stdout, result.stderr))
                self.assertEqual(output.exists(), include_checker)
                if include_checker:
                    record = json.loads(output.read_text())
                    self.assertEqual(record['artifacts'][0]['target'], 'x86_64-macos')
