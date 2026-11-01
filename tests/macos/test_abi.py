"""Assert assembly adapter offsets against the selected Darwin SDK."""
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

@unittest.skipUnless(platform.system() == 'Darwin', 'Darwin SDK required')
class DarwinAbiTests(unittest.TestCase):
    def test_sdk_layout(self):
        source = r'''
#include <stddef.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/proc_info.h>
#include <sys/dirent.h>
#include <sys/fcntl.h>
#include <signal.h>
_Static_assert(sizeof(struct stat) == 144, "stat");
_Static_assert(offsetof(struct stat, st_size) == 96, "st_size");
_Static_assert(offsetof(struct stat, st_uid) == 16, "st_uid");
_Static_assert(sizeof(struct statfs) == 2168, "statfs");
_Static_assert(offsetof(struct statfs, f_flags) == 64, "f_flags");
_Static_assert(offsetof(struct statfs, f_fstypename) == 72, "f_fstypename");
_Static_assert(sizeof(struct proc_regionwithpathinfo) == 1272, "region");
_Static_assert(offsetof(struct proc_regionwithpathinfo, prp_vip) == 96, "vnode");
_Static_assert(offsetof(struct vinfo_stat, vst_ino) == 8, "inode");
_Static_assert(offsetof(struct dirent, d_name) == 21, "dirent");
_Static_assert(O_NOFOLLOW == 256 && O_CLOEXEC == 0x1000000, "open flags");
_Static_assert(AT_FDCWD == -2 && AT_SYMLINK_NOFOLLOW == 32, "at flags");
_Static_assert(SIG_UNBLOCK == 2, "signal");
int main(void) { return 0; }
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'abi.c'
            path.write_text(source)
            subprocess.run(['/usr/bin/clang', '-Werror', '-c', str(path), '-o', str(path.with_suffix('.o'))], check=True)

    def test_ownership_disabled_and_nonlocal_volumes_fail_closed(self):
        import sys
        root = Path(__file__).resolve().parents[2]
        sys.path.insert(0, str(root / 'tools'))
        import macos
        source = r'''
#include <sys/mount.h>
#include <stdint.h>
#include <string.h>
_Static_assert(MNT_IGNORE_OWNERSHIP == 0x200000, "ownership flag");
static uint32_t flags;
static char *kind = "apfs";
int fstatfs(int fd, struct statfs *value) {
    (void)fd;
    memset(value, 0, sizeof(*value));
    value->f_flags = flags;
    strcpy(value->f_fstypename, kind);
    return 0;
}
extern long testfs(void *);
int main(void) {
    uint64_t result[16];
    flags = MNT_LOCAL;
    if (testfs(result) != 0) return 1;
    flags = MNT_LOCAL | MNT_IGNORE_OWNERSHIP;
    if (testfs(result) >= 0) return 2;
    flags = 0;
    if (testfs(result) >= 0) return 3;
    flags = MNT_LOCAL; kind = "hfs";
    if (testfs(result) >= 0) return 4;
    return 0;
}
'''
        assembly = macos.prepare(root / 'cli/aarch64/platform.inc')
        assembly += (root / 'cli/macos/platform.s').read_text()
        assembly += '''
.text
.global _testfs
_testfs:
    stp x29, x30, [sp, #-16]!
    mov x1, x0
    mov x0, #0
    bl arm_fstatfs
    mov x0, x9
    ldp x29, x30, [sp], #16
    ret
.data
registry_sha256sum: .asciz "/usr/bin/shasum"
'''
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / 'fixture.c').write_text(source)
            (work / 'adapter.s').write_text(assembly)
            subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-o', str(work / 'test'),
                            str(work / 'fixture.c'), str(work / 'adapter.s')], check=True)
            subprocess.run([str(work / 'test')], check=True)
