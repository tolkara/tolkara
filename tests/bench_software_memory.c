/* Owned-code diagnostic, not a Steam or iPad performance prediction.
 * Compile with GuestMemory, GuestCPU, GuestSparseMemory, GuestMemoryInstruction,
 * GuestExclusive, GuestSoftwareVM and SparseMemoryProbeProgram, -O2 -Iruntime.
 * Run without sanitizers for timing; assertions verify the same output paths.
 */
#include "GuestSoftwareVM.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <time.h>
extern uint64_t gm_sparse_probe_program(void *,uint64_t,void *);
extern void gm_sparse_probe_program_end(void);
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec*1e-9; }
static double run(void *p,unsigned n) {
    uint64_t output[4],sum=0; double start=now();
    for(unsigned i=0;i<n;i++)sum+=gm_sparse_probe_program(p,7,output);
    double elapsed=now()-start;
    assert(sum==(uint64_t)n*49 && output[0]==7 && output[3]==7);
    return elapsed/n;
}
int main(void) {
    void *native=mmap(NULL,GM_PAGE_SIZE,3,MAP_PRIVATE|MAP_ANON,-1,0);
    assert(native!=MAP_FAILED && gsv_start(16*GM_PAGE_SIZE,1,-1));
    void *software=gsv_map(NULL,GM_PAGE_SIZE,3,MAP_PRIVATE|MAP_ANON,-1,0);
    assert(software!=MAP_FAILED && gsv_address(software));
    double direct=run(native,1000000),checked=run(software,10000);
    uintptr_t code=(uintptr_t)gm_sparse_probe_program;
    assert(gsv_code_alias((void *)code,(void *)code,(uintptr_t)gm_sparse_probe_program_end-code));
    uint64_t before=gsv_fault_count();
    double aliased=run(software,100000);
    printf("Mac owned-code only: native_ns=%.1f checked_us=%.2f alias_us=%.2f alias_slowdown=%.0f faults=%llu faults_per_call=%.1f\n",direct*1e9,checked*1e6,aliased*1e6,aliased/direct,(unsigned long long)(gsv_fault_count()-before),(gsv_fault_count()-before)/100000.0);
    gsv_stop();munmap(native,GM_PAGE_SIZE);
}
