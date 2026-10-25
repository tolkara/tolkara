"""Exercise Wine's real anonymous allocation loop with synthetic host mappings."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class AnonymousFallbackTest(unittest.TestCase):
    def test_software_exhaustion_terminates_and_native_retry_still_works(self):
        source = ROOT / 'build/windows-runtime/src/wine/dlls/ntdll/unix/virtual.c'
        if not source.exists():
            self.skipTest('local Wine source not available')
        text = source.read_text()
        marker = text.index('if ((ptr = anon_mmap_alloc( view_size, unix_prot )) == MAP_FAILED)')
        begin = text.rfind('        for (;;)', 0, marker)
        end = text.index('        ptr = unmap_extra_space(', marker)
        loop = text[begin:end]
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            (path / 'loop.c').write_text(PREFIX + loop + SUFFIX)
            subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', str(path / 'loop.c'),
                            '-o', str(path / 'loop')], check=True)
            subprocess.run([str(path / 'loop')], check=True, timeout=5)


PREFIX = r'''
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/mman.h>
#define STATUS_NO_MEMORY 1
#define STATUS_INVALID_PARAMETER 2
#define ERR(...) ((void)0)
#define TRACE(...) ((void)0)
static void *answers[3], *chosen, *released;
static unsigned calls, unmaps, native_retries;
static void *anon_mmap_alloc(size_t size, int prot) {
    assert(size == 0x20000 && prot == 0);
    assert(calls < 3); /* catches a retry loop without hanging the test */
    return answers[calls++];
}
static int is_software_range(void *p, size_t size) {
    return (uintptr_t)p >= 0x10000000000ULL && size == 0x20000;
}
static int is_beyond_limit(void *p, size_t size, void *limit) {
    return (uintptr_t)p + size > (uintptr_t)limit;
}
static size_t unmap_area_above_user_limit(void *p, size_t size) {
    if (is_software_range(p,size)) return size;
    assert((uintptr_t)p == 0x9000000000ULL && size == 0x20000);
    native_retries++;
    return 0; /* native high mapping becomes a reserved area */
}
static int fixture_unmap(void *p, size_t size) {
    assert(size == 0x20000); released=p; unmaps++; return 0;
}
#define munmap fixture_unmap
static int run(void) {
    void *ptr, *user_space_limit=(void *)0x8000000000ULL;
    size_t view_size=0x20000, unmap_size;
    int unix_prot=0, status;
'''
SUFFIX = r'''
    chosen=ptr; return 0;
}
static void reset(void) { calls=unmaps=native_retries=0; chosen=released=0; }
int main(void) {
    reset(); answers[0]=(void *)0x7000000000ULL;
    assert(run()==0 && calls==1 && chosen==answers[0] && !unmaps);
    reset(); answers[0]=answers[1]=answers[2]=(void *)0x11000000000ULL;
    assert(run()==STATUS_NO_MEMORY && calls==1 && unmaps==1 && released==answers[0]);
    reset(); answers[0]=(void *)0x9000000000ULL; answers[1]=(void *)0x7000000000ULL;
    assert(run()==0 && calls==2 && native_retries==1 && chosen==answers[1]);
    reset(); answers[0]=MAP_FAILED; errno=ENOMEM;
    assert(run()==STATUS_NO_MEMORY && calls==1 && !unmaps);
    reset(); answers[0]=MAP_FAILED; errno=EINVAL;
    assert(run()==STATUS_INVALID_PARAMETER && calls==1 && !unmaps);
    return 0;
}
'''

if __name__ == '__main__':
    unittest.main()
