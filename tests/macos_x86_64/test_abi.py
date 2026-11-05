"""Check Intel Darwin SDK layouts and execute security-sensitive adapters."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import macos_x86_64


class IntelDarwinAbiTests(unittest.TestCase):
    def test_sdk_layout_and_apfs_policy(self):
        source = r'''
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/proc_info.h>
#include <sys/dirent.h>
#include <sys/fcntl.h>
#include <signal.h>
_Static_assert(sizeof(void *) == 8 && sizeof(long) == 8, "LP64");
_Static_assert(sizeof(struct stat) == 144, "stat");
_Static_assert(offsetof(struct stat, st_size) == 96, "size");
_Static_assert(offsetof(struct stat, st_uid) == 16, "uid");
_Static_assert(offsetof(struct stat, st_nlink) == 6, "links");
_Static_assert(sizeof(struct statfs) == 2168, "statfs");
_Static_assert(offsetof(struct statfs, f_flags) == 64, "flags");
_Static_assert(offsetof(struct statfs, f_fstypename) == 72, "filesystem");
_Static_assert(sizeof(struct proc_regionwithpathinfo) == 1272, "region");
_Static_assert(offsetof(struct proc_regionwithpathinfo, prp_vip) == 96, "vnode");
_Static_assert(offsetof(struct vinfo_stat, vst_ino) == 8, "inode");
_Static_assert(offsetof(struct dirent, d_name) == 21, "directory");
_Static_assert(O_NOFOLLOW == 256 && O_CLOEXEC == 0x1000000, "open");
_Static_assert(AT_FDCWD == -2 && AT_SYMLINK_NOFOLLOW == 32, "at");
_Static_assert(SIG_UNBLOCK == 2 && MNT_IGNORE_OWNERSHIP == 0x200000, "policy");
static uint32_t flags;
static const char *kind = "apfs";
int fstatfs(int fd, struct statfs *value) {
    (void)fd; memset(value, 0, sizeof(*value));
    value->f_flags = flags; strcpy(value->f_fstypename, kind); return 0;
}
extern long testfs(void *);
int main(void) {
    uint64_t result[16] = {0};
    flags = MNT_LOCAL;
    if (testfs(result) || result[0] != 0x41504653) return 1;
    flags = MNT_LOCAL | MNT_IGNORE_OWNERSHIP;
    if (testfs(result) != -95) return 2;
    flags = 0;
    if (testfs(result) != -95) return 3;
    flags = MNT_LOCAL; kind = "hfs";
    if (testfs(result) != -95) return 4;
    return 0;
}
'''
        assembly = macos_x86_64.complete().replace('_main', '_asm_entry')
        assembly += '''
.text
.global _testfs
_testfs:
    push rbp
    mov rbp, rsp
    mov rsi, rdi
    xor edi, edi
    mov eax, 138
    call mac_syscall
    pop rbp
    ret
'''
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as directory:
            work = Path(directory)
            (work / 'fixture.c').write_text(source)
            (work / 'adapter.s').write_text(assembly)
            subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=15.0',
                            '-o', str(work / 'test'), str(work / 'fixture.c'), str(work / 'adapter.s')], check=True)
            subprocess.run([str(work / 'test')], check=True, timeout=20)

    def test_successful_64_bit_seek_is_not_an_errno(self):
        c = r'''
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
extern long testseek(int, long);
int main(void) {
    FILE *file = tmpfile();
    if (!file) return 1;
    errno = 0;
    long position = testseek(fileno(file), 0xffffffffL);
    long actual = lseek(fileno(file), 0, SEEK_CUR);
    fclose(file);
    return position == 0xffffffffL && actual == position ? 0 : 2;
}
'''
        assembly = macos_x86_64.complete().replace("_main", "_asm_entry")
        assembly += '''
.text
.global _testseek
_testseek:
    push rbp
    mov rbp, rsp
    xor edx, edx
    mov eax, 8
    call mac_syscall
    pop rbp
    ret
'''
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            work = Path(directory)
            (work / "seek.c").write_text(c)
            (work / "seek.s").write_text(assembly)
            subprocess.run(["/usr/bin/clang", "-arch", "x86_64", "-mmacosx-version-min=15.0",
                            "-o", str(work / "seek"), str(work / "seek.c"), str(work / "seek.s")], check=True)
            result = subprocess.run([str(work / "seek")], timeout=15)
            self.assertEqual(result.returncode, 0, "successful off_t was truncated to an int errno")
