#include "GuestSoftwareVM.h"
#include "GuestExclusive.h"
#include <assert.h>
#include <limits.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

extern uint64_t gm_sparse_probe_program(void *, uint64_t, void *);
extern void gm_sparse_address_probe(void *, uint64_t, void *);
extern void gm_sparse_casp_probe(void *, const void *, const void *, void *);
extern void gm_sparse_casp32_probe(void *, const void *, const void *, void *);
extern void gm_sparse_ldapr_probe(void *, void *);
extern void gm_sparse_exclusive_probe(void *, uint64_t, void *);
extern void gm_sparse_exclusive_increment(void *);
extern void gm_sparse_exclusive_ordered(void *);
extern void gm_sparse_probe_program_end(void);
extern void gm_sparse_structure_probe(void *,void *);
static volatile sig_atomic_t delivered;
static void original_handler(int number) { assert(number == SIGSEGV); ++delivered; }
static void *thread_fixture(void *pointer) {
    for (unsigned i = 0; i < 100; ++i) {
        uint64_t seed = 0x98765432 + i, output[4];
        uint64_t byte = (seed & 255) < 128 ? seed & 255 : (seed & 255) - 256;
        uint64_t expected = (seed & 255) + (seed & 65535) + (seed & UINT32_MAX) + seed * 3 + byte;
        assert(gm_sparse_probe_program(pointer, seed, output) == expected);
        for (unsigned j = 0; j < 4; ++j) assert(output[j] == seed);
    }
    return NULL;
}
static void *exclusive_worker(void *pointer) {
    for(unsigned i=0;i<1000;i++)gm_sparse_exclusive_increment(pointer);
    return NULL;
}
typedef struct { void *software; unsigned char *source, *output; FILE *file; } SmallStackCopy;
static void *small_stack_copy(void *raw) {
    SmallStackCopy *copy=raw;
    const size_t size=200000;
    // ASan increases pthread stacks; the suite also runs this fixture without
    // sanitizers to verify the actual 64 KiB worker limit.
#if __has_feature(address_sanitizer)
    assert(pthread_get_stacksize_np(pthread_self())>=64*1024);
#else
    assert(pthread_get_stacksize_np(pthread_self())==64*1024);
#endif
    assert(gsv_copy(copy->software,copy->source,size)==GM_OK);
    assert(gsv_copy(copy->output,copy->software,size)==GM_OK);
    assert(!memcmp(copy->source,copy->output,size));
    // Both overlap directions must cross many scratch-buffer boundaries.
    assert(gsv_copy((char *)copy->software+23,copy->software,size-23)==GM_OK);
    memmove(copy->source+23,copy->source,size-23);
    assert(gsv_copy(copy->software,(char *)copy->software+17,size-17)==GM_OK);
    memmove(copy->source,copy->source+17,size-17);
    assert(gsv_copy(copy->output,copy->software,size)==GM_OK);
    assert(!memcmp(copy->source,copy->output,size));
    assert(gsv_fill(copy->software,0x6a,size)==GM_OK);
    assert(gsv_copy(copy->output,copy->software,size)==GM_OK);
    for(size_t i=0;i<size;i++)assert(copy->output[i]==0x6a);
    rewind(copy->file);
    assert(gsv_fwrite(copy->software,1,size,copy->file)==size);
    assert(!fflush(copy->file));
    assert(gsv_pwrite(fileno(copy->file),copy->software,size,0)==(ssize_t)size);
    assert(gsv_pread(fileno(copy->file),copy->software,size,0)==(ssize_t)size);
    rewind(copy->file);
    assert(gsv_fread(copy->software,1,size,copy->file)==size);
    assert(!lseek(fileno(copy->file),0,SEEK_SET));
    assert(gsv_read(fileno(copy->file),copy->software,size)==(ssize_t)size);
    assert(!lseek(fileno(copy->file),0,SEEK_SET));
    assert(gsv_write(fileno(copy->file),copy->software,size)==(ssize_t)size);
    return NULL;
}
static void check_small_stack(void *software,unsigned char *source,unsigned char *output,FILE *file) {
    SmallStackCopy copy={software,source,output,file};
    pthread_attr_t attr;pthread_t thread;
    assert(!pthread_attr_init(&attr));
#if __has_feature(address_sanitizer)
    assert(!pthread_attr_setstacksize(&attr,256*1024));
#else
    size_t page=(size_t)getpagesize(),stack_size=64*1024;
    unsigned char *mapping=mmap(NULL,stack_size+2*page,PROT_NONE,MAP_PRIVATE|MAP_ANON,-1,0);
    assert(mapping!=MAP_FAILED);
    assert(!mprotect(mapping+page,stack_size,PROT_READ|PROT_WRITE));
    assert(!pthread_attr_setstack(&attr,mapping+page,stack_size));
#endif
    assert(!pthread_create(&thread,&attr,small_stack_copy,&copy));
    assert(!pthread_attr_destroy(&attr));assert(!pthread_join(thread,NULL));
#if !__has_feature(address_sanitizer)
    assert(!munmap(mapping,stack_size+2*page));
#endif
}
typedef struct { const uint32_t *words; size_t count; } Sequence;
static bool fetch_fixture(uint64_t pc,uint32_t *word,void *raw) {
    Sequence *sequence=raw;
    if(pc<0x4000 || (pc&3) || (pc-0x4000)/4>=sequence->count)return false;
    *word=sequence->words[(pc-0x4000)/4];return true;
}
static void sequence_failures(void) {
    GMSparseMemory memory={0};const uint64_t base=UINT64_C(0x10000000000);
    assert(gm_sparse_init(&memory,base,GM_PAGE_SIZE,GM_PAGE_SIZE)==GM_OK);
    assert(gm_sparse_map(&memory,base,GM_PAGE_SIZE,3,3,false)==GM_OK);
    uint64_t original=71,value=0;
    assert(gm_sparse_write(&memory,base,&original,8)==GM_OK);
    GCRegisters r={0};r.pc=0x4000;r.x[0]=base;
    GCRegisters before=r;GMResult fault;
    uint32_t words[32]={0xc85ffc01,0xffffffff}; // LDAXR X1,[X0], unsupported
    Sequence sequence={words,2};
    assert(gm_exclusive_sequence(&memory,words[0],&r,fetch_fixture,&sequence,&fault,NULL)==GM_STEP_UNSUPPORTED);
    assert(!memcmp(&r,&before,sizeof r));
    sequence.count=1;
    assert(gm_exclusive_sequence(&memory,words[0],&r,fetch_fixture,&sequence,&fault,NULL)==GM_STEP_FAULT);
    assert(!memcmp(&r,&before,sizeof r));
    sequence.count=32;
    words[1]=0x14000000; // B . stays inside the window until the step budget expires.
    assert(gm_exclusive_sequence(&memory,words[0],&r,fetch_fixture,&sequence,&fault,NULL)==GM_STEP_UNSUPPORTED);
    assert(!memcmp(&r,&before,sizeof r));
    words[1]=0xd5033f5f;sequence.count=2; // CLREX
    assert(gm_exclusive_sequence(&memory,words[0],&r,fetch_fixture,&sequence,&fault,NULL)==GM_STEP_OK);
    assert(r.pc==0x4008 && r.x[1]==original);
    r.x[1]=99;
    assert(gm_exclusive_sequence(&memory,0xc802fc01,&r,fetch_fixture,&sequence,&fault,NULL)==GM_STEP_OK); // STLXR W2,X1,[X0]
    assert(r.x[2]==1 && r.pc==0x400c);
    assert(gm_sparse_read(&memory,base,&value,8)==GM_OK && value==original);
    r=before;words[1]=0x14000040; // Branch outside the interpreted window.
    assert(gm_exclusive_sequence(&memory,words[0],&r,fetch_fixture,&sequence,&fault,NULL)==GM_STEP_OK);
    assert(r.pc==0x4104 && r.x[1]==original);
    r=before;words[1]=0xc802fc01;
    assert(gm_sparse_protect(&memory,base,GM_PAGE_SIZE,GM_READ)==GM_OK);
    assert(gm_exclusive_sequence(&memory,words[0],&r,fetch_fixture,&sequence,&fault,NULL)==GM_STEP_FAULT && fault==GM_PROTECTION);
    assert(!memcmp(&r,&before,sizeof r));
    assert(gm_sparse_read(&memory,base,&value,8)==GM_OK && value==original);
    gm_sparse_destroy(&memory);
}
int main(int argc, char **argv) {
    assert(argc==1 || (argc==2 && !strcmp(argv[1],"--small-blocks")));
    bool (*start)(size_t,size_t,int)=argc==2?gsv_start_blocks:gsv_start;
    sequence_failures();
    // The registered view supplies current words, never a stale instruction
    // cache. Bounds and invalidation fall back to a checked kernel read.
    assert(start(32*GM_PAGE_SIZE,1,-1));
    uint32_t code_words[2]={0xd503201f,0xd65f03c0},fetched=0;
    const uintptr_t synthetic_pc=0x1000;
    assert(!gsv_code_alias((void *)synthetic_pc,code_words,3));
    assert(gsv_code_alias((void *)synthetic_pc,code_words,sizeof code_words));
    assert(gsv_fetch_instruction(synthetic_pc,&fetched) && fetched==code_words[0]);
    code_words[0]=0x91000400;
    assert(gsv_fetch_instruction(synthetic_pc,&fetched) && fetched==code_words[0]);
    assert(gsv_fetch_instruction(synthetic_pc+4,&fetched) && fetched==code_words[1]);
    assert(!gsv_fetch_instruction(synthetic_pc+1,&fetched));
    assert(!gsv_fetch_instruction(synthetic_pc+8,&fetched));
    uint32_t second_words[2]={0xd503201f,0x91000800};
    const uintptr_t second_pc=0x2000;
    assert(gsv_code_alias((void *)second_pc,second_words,sizeof second_words));
    assert(!gsv_code_alias((void *)(synthetic_pc+4),second_words,sizeof second_words));
    assert(!gsv_code_alias((void *)(UINTPTR_MAX-3),second_words,sizeof second_words));
    assert(gsv_fetch_instruction(second_pc+4,&fetched) && fetched==second_words[1]);
    assert(!gsv_fetch_instruction(second_pc+8,&fetched));
    gsv_forget_code_alias((void *)(synthetic_pc+8),4);
    assert(gsv_fetch_instruction(synthetic_pc,&fetched));
    gsv_forget_code_alias((void *)(synthetic_pc-4),8);
    assert(!gsv_fetch_instruction(synthetic_pc,&fetched));
    assert(gsv_fetch_instruction(second_pc,&fetched) && fetched==second_words[0]);
    assert(!gsv_code_alias((void *)synthetic_pc,code_words,sizeof code_words));
    gsv_forget_code_alias((void *)(second_pc+4),4);
    assert(!gsv_fetch_instruction(second_pc,&fetched));
    // Retired entries count toward the bound and cannot be recycled unsafely.
    for(uintptr_t i=2;i<16;i++)
        assert(gsv_code_alias((void *)(0x3000+i*16),code_words,sizeof code_words));
    assert(!gsv_code_alias((void *)0x5000,code_words,sizeof code_words));
    gsv_stop();
    assert(start(32*GM_PAGE_SIZE,0,-1));
    gsv_prefer_native_pool(64u<<20);
    // Replacing a pending reservation releases it. Read-only protection is
    // applied before handing the exact request to the caller.
    gsv_prefer_native_pool(128u<<20);
    gsv_prefer_native_pool(64u<<20);
    void *preferred=gsv_map(NULL,64u<<20,PROT_READ,MAP_ANON|MAP_PRIVATE,-1,0);
    assert(preferred!=MAP_FAILED && *(const unsigned char *)preferred==0);
    assert(!gsv_protect(preferred,64u<<20,PROT_READ|PROT_WRITE));
    ((unsigned char *)preferred)[(64u<<20)-1]=0x71;
    assert(((unsigned char *)preferred)[(64u<<20)-1]==0x71);
    void *other=gsv_map(NULL,128u<<20,3,MAP_ANON|MAP_PRIVATE,-1,0);
    assert(preferred!=MAP_FAILED && !gsv_address(preferred));
    assert(other!=MAP_FAILED && gsv_address(other));
    assert(!gsv_unmap(preferred,64u<<20) && !gsv_unmap(other,128u<<20));
    gsv_stop();
    // Preserve host address space without shortening any guest reservation.
    assert(start(32*GM_PAGE_SIZE,0,-1));
    gsv_force_pool(64u<<20);
    void *forced=gsv_map(NULL,64u<<20,3,MAP_ANON|MAP_PRIVATE,-1,0);
    void *native_mapping=gsv_map(NULL,128u<<20,3,MAP_ANON|MAP_PRIVATE,-1,0);
    assert(forced!=MAP_FAILED && gsv_address(forced));
    assert(native_mapping!=MAP_FAILED && !gsv_address(native_mapping));
    assert(gsv_map(native_mapping,64u<<20,3,MAP_ANON|MAP_PRIVATE|MAP_FIXED,-1,0)==native_mapping);
    assert(!gsv_unmap(forced,64u<<20) && !gsv_unmap(native_mapping,128u<<20));
    gsv_force_pool(0);
    native_mapping=gsv_map(NULL,64u<<20,3,MAP_ANON|MAP_PRIVATE,-1,0);
    assert(native_mapping!=MAP_FAILED && !gsv_address(native_mapping));
    assert(!gsv_unmap(native_mapping,64u<<20));
    gsv_stop();
    struct sigaction prior, action = {0};
    sigemptyset(&action.sa_mask); action.sa_handler = original_handler;
    assert(!sigaction(SIGSEGV, &action, &prior));
    assert(start(32 * GM_PAGE_SIZE, 1, STDERR_FILENO));
    assert(gsv_enabled());
    const size_t alignment = (size_t)16 << 30, guard_size = 0x10000;
    void *guarded = gsv_reserve_aligned(alignment + guard_size, alignment,
                                      alignment - guard_size, PROT_NONE);
    assert(guarded != MAP_FAILED && gsv_address(guarded));
    assert(((uintptr_t)guarded & (alignment - 1)) == alignment - guard_size);
    void *committed = (char *)guarded + guard_size;
    assert(!gsv_protect(committed, GM_PAGE_SIZE, PROT_READ | PROT_WRITE));
    uint64_t aligned_output[4];
    assert(gm_sparse_probe_program(committed, 7, aligned_output) == 49);
    gsv_x86_ordered(true);
    unsigned expected_ordered = 0x12345678, actual_ordered;
    void *unaligned = (char *)committed + 33;
    uint64_t before_ordered = gsv_fault_count();
    __asm__ volatile("stlr %w0, [%1]" :: "r"(expected_ordered), "r"(unaligned) : "memory");
    __asm__ volatile("ldar %w0, [%1]" : "=r"(actual_ordered) : "r"(unaligned) : "memory");
    assert(actual_ordered == expected_ordered && gsv_fault_count() == before_ordered + 2);
    gsv_x86_ordered(false);
    assert(gsv_protect(committed, GM_PAGE_SIZE, PROT_EXEC) == -1 && errno == EINVAL);
    assert(!gsv_unmap(guarded, alignment + guard_size));
    // Subsequent legacy counters start from a clean runtime instance.
    gsv_stop();
    assert(start(32 * GM_PAGE_SIZE, 1, STDERR_FILENO));
    const size_t gib = (size_t)1 << 30;
    void *ranges[3]; size_t lengths[] = {16 * gib, 64 * gib, 32 * gib};
    for (unsigned i = 0; i < 3; ++i) {
        ranges[i] = gsv_map(NULL, lengths[i], 3, MAP_ANON | MAP_PRIVATE, -1, 0);
        assert(ranges[i] != MAP_FAILED && gsv_address(ranges[i]));
    }
    assert(gsv_stats().reserved_bytes == 112 * gib);
    pthread_t threads[6];
    for (unsigned i = 0; i < 6; ++i) {
        void *at = (char *)ranges[i / 2] + (i % 2 ? lengths[i / 2] - 128 : 0);
        assert(!pthread_create(&threads[i], NULL, thread_fixture, at));
    }
    for (unsigned i = 0; i < 6; ++i) assert(!pthread_join(threads[i], NULL));
    assert(gsv_fault_count() == 6000 && gsv_stats().resident_pages == 6);
    assert(gsv_fetch_stats().alias_fetches==0 && gsv_fetch_stats().checked_fetches>=6000);
    assert(gsv_code_alias((void *)gm_sparse_probe_program,(void *)gm_sparse_probe_program,
                         (uintptr_t)gm_sparse_probe_program_end-(uintptr_t)gm_sparse_probe_program));
    uint64_t native[16] = {0}, expected[16] = {0}, actual[16] = {0};
    gm_sparse_address_probe(native, 98765, expected);
    assert(gsv_fill(ranges[0], 0, sizeof native) == GM_OK);
    gm_sparse_address_probe(ranges[0], 98765, actual);
    assert(gsv_fetch_stats().alias_fetches>0);
    assert(!memcmp(actual, expected, sizeof actual));
    assert(gsv_copy(actual, ranges[0], sizeof actual) == GM_OK && !memcmp(actual, native, sizeof actual));
    const uint64_t candidates[] = {0, 1, UINT64_MAX, UINT64_C(0x8000000000000000)};
    for(unsigned a=0;a<4;a++)for(unsigned b=0;b<4;b++) {
        _Alignas(16) uint64_t host[2]={candidates[a],candidates[b]},initial[2];
        uint64_t host_output[16]={0},soft_output[16]={0},soft_memory[2];
        memcpy(initial,host,sizeof host);
        gm_sparse_exclusive_probe(host,candidates[b],host_output);
        assert(gsv_copy(ranges[0],initial,sizeof initial)==GM_OK);
        gm_sparse_exclusive_probe(ranges[0],candidates[b],soft_output);
        assert(!memcmp(host_output,soft_output,sizeof host_output));
        assert(gsv_copy(soft_memory,ranges[0],sizeof soft_memory)==GM_OK && !memcmp(soft_memory,host,sizeof host));
    }
    assert(gsv_fill(ranges[0],0,16)==GM_OK);
    for(unsigned i=0;i<6;i++)assert(!pthread_create(&threads[i],NULL,exclusive_worker,ranges[0]));
    for(unsigned i=0;i<6;i++)assert(!pthread_join(threads[i],NULL));
    uint64_t total_increments=0;
    assert(gsv_copy(&total_increments,ranges[0],8)==GM_OK && total_increments==6000);
    uint64_t ordered_native[2]={17,89},ordered_soft[2];
    assert(gsv_copy(ranges[0],ordered_native,sizeof ordered_native)==GM_OK);
    gm_sparse_exclusive_ordered(ordered_native);
    gm_sparse_exclusive_ordered(ranges[0]);
    assert(gsv_copy(ordered_soft,ranges[0],sizeof ordered_soft)==GM_OK);
    assert(!memcmp(ordered_native,ordered_soft,sizeof ordered_soft));
    uint64_t before_scans=gsv_fault_count();
    char text[600];memset(text,'x',sizeof text);text[599]=0;text[257]='y';
    char *soft_text=(char *)ranges[0]+GM_PAGE_SIZE-100;
    assert(gsv_copy(soft_text,text,sizeof text)==GM_OK);
    assert(gsv_strlen(soft_text)==strlen(text));
    assert(gsv_strnlen(soft_text,256)==256);
    assert(gsv_strcmp(soft_text,text)==0 && gsv_strcmp(text,soft_text)==0);
    assert(gsv_strcmp(soft_text,"")>0 && gsv_strcmp("",soft_text)<0);
    assert(gsv_strncmp(soft_text,"xxxz",3)==0 && gsv_strncmp(soft_text,"xxxz",4)<0);
    assert(gsv_strcmp(soft_text,soft_text)==0);
    assert(gsv_memcmp(soft_text,text,sizeof text)==0);
    text[500]='z';
    assert(gsv_memcmp(soft_text,text,sizeof text)<0 && gsv_memcmp(text,soft_text,sizeof text)>0);
    assert(gsv_memchr(soft_text,'y',599)==soft_text+257);
    assert(gsv_memchr(soft_text,'z',599)==NULL);
    assert(gsv_strchr(soft_text,'y')==soft_text+257);
    assert(gsv_strchr(soft_text,0)==soft_text+599 && !gsv_strchr(soft_text,'z'));
    assert(gsv_strnlen(NULL,0)==0 && gsv_strncmp(NULL,NULL,0)==0 && gsv_memcmp(NULL,NULL,0)==0);
    char *edge=gsv_map(NULL,GM_PAGE_SIZE,3,MAP_ANON|MAP_PRIVATE,-1,0);
    assert(edge!=MAP_FAILED && gsv_address(edge));
    char *last=edge+GM_PAGE_SIZE-1;
    assert(gsv_copy(last,"",1)==GM_OK);
    assert(gsv_strlen(last)==0 && gsv_strcmp(last,"")==0 && gsv_strchr(last,0)==last);
    assert(!gsv_unmap(edge,GM_PAGE_SIZE));
    assert(gsv_fault_count()==before_scans);
    unsigned char structure_host[64],structure_soft[64],structure_native_out[128],structure_soft_out[128];
    for(unsigned i=0;i<64;i++)structure_host[i]=(unsigned char)(i*17+3);
    assert(gsv_copy(ranges[0],structure_host,sizeof structure_host)==GM_OK);
    gm_sparse_structure_probe(structure_host,structure_native_out);
    gm_sparse_structure_probe(ranges[0],structure_soft_out);
    assert(!memcmp(structure_native_out,structure_soft_out,sizeof structure_native_out));
    assert(gsv_copy(structure_soft,ranges[0],sizeof structure_soft)==GM_OK);
    assert(!memcmp(structure_host,structure_soft,sizeof structure_host));
    for (unsigned i=0; i<4; ++i) {
        uint64_t native_value=candidates[i], host_result[4], software_result[4];
        gm_sparse_ldapr_probe(&native_value,host_result);
        assert(gsv_copy(ranges[0],&native_value,sizeof native_value)==GM_OK);
        gm_sparse_ldapr_probe(ranges[0],software_result);
        assert(!memcmp(host_result,software_result,sizeof host_result));
    }
    for (unsigned width = 0; width < 2; ++width) for (unsigned a = 0; a < 4; ++a) for (unsigned b = 0; b < 4; ++b) {
        void (*reference)(void *,const void *,const void *,void *)=width?gm_sparse_casp_probe:gm_sparse_casp32_probe;
        uint64_t original[2] = {candidates[a],candidates[b]}, desired[2] = {candidates[b],candidates[a]};
        uint64_t compared[2] = {candidates[a],candidates[b] ^ (a & 1)};
        uint64_t host[2], expected_old[2]={0}, soft_old[2]={0}, soft_value[2];
        memcpy(host,original,sizeof host);
        reference(host,compared,desired,expected_old);
        assert(gsv_copy(ranges[0],original,sizeof original)==GM_OK);
        reference(ranges[0],compared,desired,soft_old);
        assert(!memcmp(soft_old,expected_old,sizeof soft_old));
        assert(gsv_copy(soft_value,ranges[0],sizeof soft_value)==GM_OK && !memcmp(soft_value,host,sizeof host));
    }
    // Software faults do not consume the application's one-shot handler.
    action.sa_flags = SA_RESETHAND;
    assert(!gsv_sigaction(SIGSEGV, &action, NULL));
    gm_sparse_address_probe(ranges[0], 98, actual);
    struct sigaction reported;
    assert(!gsv_sigaction(SIGSEGV, NULL, &reported) && reported.sa_handler == original_handler);
    assert(!raise(SIGSEGV) && delivered == 1);
    assert(!gsv_sigaction(SIGSEGV, NULL, &reported) && reported.sa_handler == SIG_DFL);
    gm_sparse_address_probe(ranges[0], 97, actual);
    unsigned char *source = malloc(200000), *out = malloc(200000);
    assert(source && out);
    for (unsigned i = 0; i < 200000; ++i) source[i] = (unsigned char)(i * 13 + i / 257);
    assert(gsv_copy(ranges[0], source, 200000) == GM_OK);
    memmove(source + 23, source, 190000);
    assert(gsv_copy((char *)ranges[0] + 23, ranges[0], 190000) == GM_OK);
    assert(gsv_copy(out, ranges[0], 200000) == GM_OK && !memcmp(out, source, 200000));
    char path[16];
    assert(gsv_copy(ranges[1], "archive/test", 13) == GM_OK);
    assert(gsv_string(ranges[1], path, sizeof path) == path && !strcmp(path,"archive/test"));
    errno=0; assert(!gsv_string(ranges[1],path,4) && errno==ENAMETOOLONG);
    assert(gsv_fill((char *)ranges[1]+GM_PAGE_SIZE-1,'x',1)==GM_OK);
    assert(gsv_unmap((char *)ranges[1]+GM_PAGE_SIZE,GM_PAGE_SIZE)==0);
    errno=0; assert(!gsv_string((char *)ranges[1]+GM_PAGE_SIZE-1,path,sizeof path) && errno==EFAULT);
    // Tracing preserves native and bridged error results and errno.
    errno=0;assert(gsv_read(-1,path,1)==-1 && errno==EBADF);
    errno=0;assert(gsv_read(-1,ranges[0],1)==-1 && errno==EBADF);
    errno=0;assert(gsv_write(-1,ranges[0],1)==-1 && errno==EBADF);
    errno=0;assert(gsv_read(-1,ranges[0],(size_t)INT_MAX+1)==-1 && errno==EINVAL);
    int pipefd[2]; assert(!pipe(pipefd));
    assert(write(pipefd[1],"abc",3)==3);
    assert(gsv_read(pipefd[0],ranges[1],64)==3);
    assert(gsv_copy(path,ranges[1],3)==GM_OK && !memcmp(path,"abc",3));
    close(pipefd[0]); close(pipefd[1]);
    memmove(source, source + 17, 180000);
    assert(gsv_copy(ranges[0], (char *)ranges[0] + 17, 180000) == GM_OK);
    assert(gsv_copy(out, ranges[0], 200000) == GM_OK && !memcmp(out, source, 200000));
    FILE *file = tmpfile(); assert(file);
    assert(fwrite(source, 1, 200000, file) == 200000); fflush(file);
    assert(gsv_pread(fileno(file), ranges[0], 200000, 0) == 200000);
    assert(gsv_copy(out, ranges[0], 200000) == GM_OK && !memcmp(out, source, 200000));
    assert(lseek(fileno(file), 0, SEEK_CUR) == 200000);
    assert(gsv_pwrite(fileno(file), ranges[0], 200000, 0) == 200000);
    assert(lseek(fileno(file), 0, SEEK_CUR) == 200000);
    rewind(file);
    assert(gsv_fread(ranges[0], 3, 70000, file) == 66666 && feof(file));
    rewind(file);
    assert(gsv_fwrite(ranges[0], 2, 100000, file) == 100000);
    assert(gsv_protect(ranges[0], GM_PAGE_SIZE, PROT_READ) == 0);
    assert(lseek(fileno(file), 0, SEEK_SET) == 0);
    errno = 0;
    assert(gsv_read(fileno(file), ranges[0], 16) == -1 && errno == EFAULT);
    assert(lseek(fileno(file), 0, SEEK_CUR) == 0);
    assert(gsv_copy(ranges[0], source, 16) == GM_PROTECTION);
    assert(gsv_protect(ranges[0], GM_PAGE_SIZE, 3) == 0);
    check_small_stack(ranges[0],source,out,file);
    for (unsigned i = 0; i < 3; ++i) assert(!gsv_unmap(ranges[i], lengths[i]));
    assert(gsv_stats().resident_pages == 0);
    fclose(file); free(source); free(out);
    gsv_stop(); assert(!gsv_enabled());
    assert(!sigaction(SIGSEGV, NULL, &reported) && reported.sa_handler == original_handler);
    assert(!sigaction(SIGSEGV, &prior, NULL));
    puts("PASS: software VM concurrent fault delivery, signal chaining, mappings, overlapping copies and file bridges");
}
