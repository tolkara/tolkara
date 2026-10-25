"""Exercise Wine decommit with real 16 KiB host pages and 4 KiB guest pages."""
from pathlib import Path
import subprocess
import tempfile
import unittest
prefix=r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
typedef int NTSTATUS;
#define STATUS_SUCCESS 0
#define VPROT_COMMITTED 1
#define ROUND_ADDR(a,m) ((void *)((uintptr_t)(a)&~(uintptr_t)(m)))
#define ROUND_SIZE(a,s,m) (((uintptr_t)(a)+(uintptr_t)(s)+(m))&~(uintptr_t)(m))
static size_t host_page_size,host_page_mask;
static char *arena;
static unsigned char committed[64];
struct file_view {size_t size;};
static int is_view_valloc(struct file_view *v) {(void)v;return 1;}
static void set_page_vprot_bits(char *base,size_t size,int set,int clear) {
 (void)set;(void)clear;
 for(size_t i=(base-arena)/4096;i<(base-arena+size)/4096;i++) committed[i]=0;
}
static int mprotect_range(char *base,size_t size,int set,int clear) {
 (void)set;(void)clear;
 for(size_t p=0;p<size;p+=host_page_size) {
  int any=0;
  for(size_t i=0;i<host_page_size/4096;i++) any|=committed[(base+p-arena)/4096+i];
  assert(mprotect(base+p,host_page_size,any?PROT_READ|PROT_WRITE:PROT_NONE)==0);
 }
 return 0;
}
static void anon_mmap_fixed(char *p,size_t n,int prot,int unused) {
 (void)unused;assert(mmap(p,n,prot,MAP_ANON|MAP_PRIVATE|MAP_FIXED,-1,0)==p);
}
static void kernel_writewatch_register_range(struct file_view *v,char *p,size_t n) {(void)v;(void)p;(void)n;}
'''
suffix=r'''
int main(void) {
 host_page_size=(size_t)sysconf(_SC_PAGESIZE);host_page_mask=host_page_size-1;
 assert(host_page_size==16384);
 const size_t length=65536;
 arena=mmap(0,length,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);assert(arena!=MAP_FAILED);
 struct file_view view={length};
 for(size_t start=0;start<length;start+=4096) for(size_t end=start+4096;end<=length;end+=4096) {
  assert(mprotect(arena,length,PROT_READ|PROT_WRITE)==0);
  memset(arena,0xa5,length);memset(committed,1,sizeof(committed));
  assert(decommit_pages(&view,arena+start,end-start)==0);
  /* Read retained headers/neighbors before restoring protection. */
  for(size_t i=0;i<length;i++) if(i<start||i>=end) assert((unsigned char)arena[i]==0xa5);
  assert(mprotect(arena,length,PROT_READ|PROT_WRITE)==0);
  for(size_t i=start;i<end;i++) assert(arena[i]==0);
 }
 assert(munmap(arena,length)==0);return 0;
}
'''
class PartialDecommitTest(unittest.TestCase):
    def test_retains_neighbors_and_zeros_recommitted_bytes(self):
        source = Path(__file__).resolve().parents[1] / 'build/windows-runtime/src/wine/dlls/ntdll/unix/virtual.c'
        if not source.exists():
            self.skipTest('local Wine source unavailable')
        import os
        if os.sysconf('SC_PAGE_SIZE') != 16384:
            self.skipTest('requires a 16 KiB host page')
        text = source.read_text()
        begin = text.index('static void zero_decommitted_part(')
        end = text.index('/***********************************************************************', text.index('static NTSTATUS decommit_pages(', begin))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'probe.c').write_text(prefix + text[begin:end] + suffix)
            subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', str(path / 'probe.c'),
                            '-o', str(path / 'probe')], check=True)
            subprocess.run([str(path / 'probe')], check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
