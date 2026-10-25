#include "GuestSoftwareVM.h"
#include "GuestMemoryInstruction.h"
#include "GuestExclusive.h"
#include <errno.h>
#include <limits.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <unistd.h>

// Guest workers may have only a 64 KiB stack. Keep transfer scratch small
// enough to leave room for the caller, libc and signal delivery.
enum { ACTION_LIMIT = 128, BOUNCE_SIZE = 4096 };
static GMSparseMemory memory;
static uint64_t base, span;
static void *guard;
static size_t force_threshold;
static size_t native_pool_size, forced_pool_size;
static _Atomic(void *) pending_native_pool;
static int log_fd = -1;
static atomic_bool enabled, x86_ordered;
static atomic_uint_fast64_t fault_count, alias_fetches, checked_fetches;
static atomic_uint io_reports;
enum { CODE_ALIAS_LIMIT = 16 };
static struct {
    uintptr_t base, readable;
    size_t size;
    atomic_bool enabled;
} code_aliases[CODE_ALIAS_LIMIT];
static atomic_size_t code_alias_count;
static struct sigaction original[2], actions[ACTION_LIMIT];
static _Atomic(struct sigaction *) current[2];
static size_t action_count;
static pthread_mutex_t action_lock = PTHREAD_MUTEX_INITIALIZER;

static int error_code(GMResult result) {
    return result == GM_NOMEM ? ENOMEM : result == GM_PROTECTION ? EACCES : EINVAL;
}
static bool rounded(size_t size, uint64_t *result) {
    if (!size || size > UINT64_MAX - (GM_PAGE_SIZE - 1)) return false;
    *result = (size + GM_PAGE_SIZE - 1) & ~(uint64_t)(GM_PAGE_SIZE - 1);
    return true;
}
bool gsv_enabled(void) { return atomic_load_explicit(&enabled, memory_order_acquire); }

void gsv_x86_ordered(bool allow) { atomic_store(&x86_ordered, allow); }
void gsv_force_pool(size_t size) { forced_pool_size=size; }
uintptr_t gsv_address_end(void) { return gsv_enabled() ? base + span : 0; }
bool gsv_address(const void *address) {
    uint64_t a = (uintptr_t)address;
    return gsv_enabled() && a >= base && a - base < span;
}
static void report(const char *message, uint64_t value) {
    if (log_fd < 0) return;
    char line[160]; size_t n = 0;
    while (message[n] && n < 136) { line[n] = message[n]; ++n; }
    line[n++] = '0'; line[n++] = 'x';
    for (int shift = 60; shift >= 0; shift -= 4) line[n++] = "0123456789abcdef"[(value >> shift) & 15];
    line[n++] = '\n'; (void)write(log_fd, line, n);
}
void gsv_prefer_native_pool(size_t size) {
    // Startup-only: reserve before initializers fragment the native VM range.
    // The application receives this mapping only on an exact eligible request.
    void *previous=atomic_exchange(&pending_native_pool,NULL);
    if(previous)munmap(previous,native_pool_size);
    native_pool_size=size;
    if(!gsv_enabled() || !size)return;
    void *reserved=mmap(NULL,size,PROT_NONE,MAP_PRIVATE|MAP_ANON,-1,0);
    if(reserved==MAP_FAILED)report("[software-vm] early native pool failed errno ",errno);
    else { atomic_store(&pending_native_pool,reserved);report("[software-vm] early native pool bytes ",size); }
}
bool gsv_code_alias(const void *executable, const void *readable, size_t size) {
    uintptr_t start=(uintptr_t)executable, alias=(uintptr_t)readable;
    size_t count=atomic_load_explicit(&code_alias_count,memory_order_acquire);
    if(!gsv_enabled() || count==CODE_ALIAS_LIMIT || !start || !alias || (start&3) || (alias&3) ||
       size<4 || (size&3) || size>UINTPTR_MAX-start || size>UINTPTR_MAX-alias ||
       gsv_address(executable) || gsv_address(readable)) return false;
    // Registration is serialized by the loader before guest entry. Never reuse
    // an invalidated record: signal readers may still have observed its index.
    for(size_t i=0;i<count;i++) {
        uintptr_t other=code_aliases[i].base;
        if(start<other ? size>other-start : start-other<code_aliases[i].size) return false;
    }
    code_aliases[count].base=start;
    code_aliases[count].readable=alias;
    code_aliases[count].size=size;
    atomic_store_explicit(&code_aliases[count].enabled,true,memory_order_relaxed);
    atomic_store_explicit(&code_alias_count,count+1,memory_order_release);
    return true;
}
void gsv_forget_code_alias(const void *address, size_t size) {
    if(!size) return;
    uintptr_t start=(uintptr_t)address;
    size_t count=atomic_load_explicit(&code_alias_count,memory_order_acquire);
    for(size_t i=0;i<count;i++) {
        uintptr_t other=code_aliases[i].base;
        if(start<=other ? size>other-start : start-other<code_aliases[i].size)
            atomic_store_explicit(&code_aliases[i].enabled,false,memory_order_release);
    }
}
bool gsv_fetch_instruction(uint64_t pc,uint32_t *instruction) {
    if(!instruction || (pc&3) || gsv_address((void *)(uintptr_t)pc)) return false;
    size_t count=atomic_load_explicit(&code_alias_count,memory_order_acquire);
    for(size_t i=0;i<count;i++) {
        if(atomic_load_explicit(&code_aliases[i].enabled,memory_order_acquire) &&
           pc>=code_aliases[i].base && pc-code_aliases[i].base<=code_aliases[i].size-4) {
            atomic_fetch_add_explicit(&alias_fetches,1,memory_order_relaxed);
            memcpy(instruction,(const void *)(code_aliases[i].readable+(uintptr_t)(pc-code_aliases[i].base)),sizeof *instruction);
            return true;
        }
    }
    atomic_fetch_add_explicit(&checked_fetches,1,memory_order_relaxed);
    vm_size_t actual=0;
    return vm_read_overwrite(mach_task_self(),(vm_address_t)pc,sizeof *instruction,
                            (vm_address_t)instruction,&actual)==KERN_SUCCESS && actual==sizeof *instruction;
}
static bool fetch_instruction(uint64_t pc,uint32_t *instruction,void *context) {
    (void)context;
    return gsv_fetch_instruction(pc,instruction);
}
static bool handle_fault(siginfo_t *info, void *context) {
    if (!info || !gsv_address(info->si_addr)) return false;
    ucontext_t *u = context;
    // Hardware data abort only. Instruction aborts and software-raised signals
    // must never cause an instruction fetch or a fabricated return to execution.
    if ((u->uc_mcontext->__es.__esr >> 26) != 0x24) return false;
    uintptr_t pc = u->uc_mcontext->__ss.__pc;
    if ((pc & 3) || gsv_address((void *)pc)) return false;
    uint32_t instruction;
    if(!fetch_instruction(pc,&instruction,NULL)) return false;
    GMMemoryRegisters r = {0};
    for (unsigned i = 0; i < 29; ++i) r.x[i] = u->uc_mcontext->__ss.__x[i];
    r.x[29] = u->uc_mcontext->__ss.__fp; r.x[30] = u->uc_mcontext->__ss.__lr;
    r.sp = u->uc_mcontext->__ss.__sp; r.pc = pc;
    memcpy(r.vector, u->uc_mcontext->__ns.__v, sizeof r.vector);
    GMResult fault = GM_OK;
    GMMemoryStep result;
    uint8_t nzcv=(u->uc_mcontext->__ss.__cpsr>>28)&15;
    if(gm_exclusive_instruction(instruction)) {
        GCRegisters state={0};memcpy(state.x,r.x,sizeof state.x);
        state.sp=r.sp;state.pc=r.pc;state.nzcv=nzcv;
        GMExclusiveDiagnostic diagnostic={0};
        result=gm_exclusive_sequence(&memory,instruction,&state,fetch_instruction,NULL,&fault,&diagnostic);
        if(result!=GM_STEP_OK && diagnostic.reason) {
            uint32_t word=0;
            report(diagnostic.reason,diagnostic.pc);
            if(fetch_instruction(diagnostic.pc,&word,NULL)) report("[software-vm] instruction word ",word);
        }
        if(result==GM_STEP_OK) {
            memcpy(r.x,state.x,sizeof r.x);r.sp=state.sp;r.pc=state.pc;nzcv=state.nzcv;
        }
    } else result = atomic_load(&x86_ordered) ?
        gm_memory_step_x86_ordered(&memory, instruction, &r, &fault) :
        gm_memory_step(&memory, instruction, &r, &fault);
    if (result != GM_STEP_OK) {
        if (result == GM_STEP_UNSUPPORTED) {
            const char *family = "[software-vm] unsupported memory encoding at ";
            if ((instruction & 0x3fa07c00) == 0x08207c00 && (instruction >> 30) < 2)
                family = "[software-vm] requires CASP support at ";
            else if ((instruction & 0x3f800000) == 0x08000000)
                family = "[software-vm] requires exclusive sequence support at ";
            else if ((instruction & 0x3f000000) == 0x08000000)
                family = "[software-vm] requires ordered access support at ";
            else if ((instruction & 0xbe000000) == 0x0c000000)
                family = "[software-vm] requires SIMD structure access support at ";
            else if ((instruction & 0x3ffffc00) == 0x38bfc000)
                family = "[software-vm] requires LDAPR support at ";
            else if ((instruction & 0xffffffe0) == 0xd50b7420)
                family = "[software-vm] requires cache-zero support at ";
            report(family, pc);
        }
        report(result == GM_STEP_UNSUPPORTED ? "[software-vm] unsupported memory instruction at " :
               "[software-vm] failed memory access at ", pc);
        if (fault == GM_INVALID && ((instruction & 0x3f9ffc00) == 0x089ffc00 ||
                                   (instruction & 0x3ffffc00) == 0x38bfc000)) {
            unsigned rn = (instruction >> 5) & 31;
            size_t width = (size_t)1 << (instruction >> 30);
            uintptr_t address = rn == 31 ? r.sp : r.x[rn];
            report("[software-vm] ordered-access width ", width);
            report("[software-vm] ordered-access alignment remainder ", address % width);
        }
        report("[software-vm] memory result ", fault);
        report("[software-vm] handled faults ", atomic_load(&fault_count));
        report("[software-vm] backing pages ", gm_sparse_stats(&memory).resident_pages);
        return false;
    }
    for (unsigned i = 0; i < 29; ++i) u->uc_mcontext->__ss.__x[i] = r.x[i];
    u->uc_mcontext->__ss.__fp = r.x[29]; u->uc_mcontext->__ss.__lr = r.x[30];
    u->uc_mcontext->__ss.__sp = r.sp; u->uc_mcontext->__ss.__pc = r.pc;
    u->uc_mcontext->__ss.__cpsr=(u->uc_mcontext->__ss.__cpsr&0x0fffffff)|((uint32_t)nzcv<<28);
    memcpy(u->uc_mcontext->__ns.__v, r.vector, sizeof r.vector);
    uint64_t count = atomic_fetch_add(&fault_count, 1) + 1;
    if (!(count & (count - 1))) report("[software-vm] handled faults ", count);
    return true;
}
bool gsv_handle_signal(int number, siginfo_t *info, void *context) {
    int saved_errno = errno;
    bool handled = gsv_enabled() && context &&
                   (number == SIGSEGV || number == SIGBUS) && handle_fault(info, context);
    errno = saved_errno;
    return handled;
}
static void dispatch_signal(int number, siginfo_t *info, void *context) {
    int saved_errno = errno;
    if (gsv_handle_signal(number, info, context)) return;
    unsigned index = number == SIGBUS;
    struct sigaction *selected = atomic_load_explicit(&current[index], memory_order_acquire);
    struct sigaction action = *selected;
    if (action.sa_flags & SA_RESETHAND) atomic_compare_exchange_strong(&current[index], &selected, &actions[0]);
    errno = saved_errno;
    if (action.sa_handler == SIG_IGN) return;
    if (action.sa_handler == SIG_DFL) {
        sigaction(number, &action, NULL); raise(number); return;
    }
    if (action.sa_flags & SA_SIGINFO) action.sa_sigaction(number, info, context);
    else action.sa_handler(number);
}
int gsv_sigaction(int number, const struct sigaction *action, struct sigaction *old) {
    if (!gsv_enabled() || (number != SIGSEGV && number != SIGBUS)) return sigaction(number, action, old);
    pthread_mutex_lock(&action_lock);
    unsigned index = number == SIGBUS;
    struct sigaction *previous = atomic_load(&current[index]);
    int result = 0;
    if (action) {
        if (action_count == ACTION_LIMIT) { errno = ENOMEM; result = -1; }
        else {
            struct sigaction *next = &actions[action_count++]; *next = *action;
            struct sigaction installed = *action;
            installed.sa_sigaction = dispatch_signal;
            installed.sa_flags = (installed.sa_flags & ~SA_RESETHAND) | SA_SIGINFO;
            atomic_store(&current[index], next);
            result = sigaction(number, &installed, NULL);
            if (result) atomic_store(&current[index], previous);
        }
    }
    if (!result && old) *old = *previous;
    pthread_mutex_unlock(&action_lock);
    return result;
}
static bool start(size_t backing_bytes, size_t force, int fd, bool small_blocks) {
    if (gsv_enabled()) return false;
    span = UINT64_C(512) << 30; base = UINT64_C(1) << 40;
    guard = MAP_FAILED;
    task_vm_info_data_t vm = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) != KERN_SUCCESS ||
        count < TASK_VM_INFO_REV2_COUNT) return false;
    if (vm.max_address > base) {
        guard = mmap(NULL, span, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (guard == MAP_FAILED) return false;
        base = (uintptr_t)guard;
    }
    GMResult initialized=small_blocks ? gm_sparse_init_blocks(&memory,base,span,backing_bytes) :
                                       gm_sparse_init(&memory,base,span,backing_bytes);
    if (initialized != GM_OK) {
        if (guard != MAP_FAILED) munmap(guard, span);
        return false;
    }
    memset(actions, 0, sizeof actions); actions[0].sa_handler = SIG_DFL;
    sigemptyset(&actions[0].sa_mask); action_count = 1;
    struct sigaction installed = {0};
    sigemptyset(&installed.sa_mask); installed.sa_sigaction = dispatch_signal; installed.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, NULL, &original[0]); sigaction(SIGBUS, NULL, &original[1]);
    atomic_store(&current[0], &original[0]); atomic_store(&current[1], &original[1]);
    if (sigaction(SIGSEGV, &installed, NULL) || sigaction(SIGBUS, &installed, NULL)) {
        sigaction(SIGSEGV, &original[0], NULL); sigaction(SIGBUS, &original[1], NULL);
        gm_sparse_destroy(&memory); if (guard != MAP_FAILED) munmap(guard, span);
        return false;
    }
    log_fd = fd; force_threshold = force; native_pool_size=forced_pool_size=0; atomic_store(&fault_count, 0);
    atomic_store(&io_reports,0);
    atomic_store(&x86_ordered,false);
    atomic_store(&pending_native_pool,NULL);
    atomic_store(&alias_fetches,0);atomic_store(&checked_fetches,0);
    atomic_store(&code_alias_count,0);
    atomic_store_explicit(&enabled, true, memory_order_release);
    report("[software-vm] base ", base); report("[software-vm] backing bytes ", backing_bytes);
    return true;
}
bool gsv_start(size_t backing_bytes, size_t force, int fd) {
    return start(backing_bytes,force,fd,false);
}
bool gsv_start_blocks(size_t backing_bytes, size_t force, int fd) {
    return start(backing_bytes,force,fd,true);
}
void gsv_stop(void) {
    if (!gsv_enabled()) return;
    atomic_store(&enabled, false);
    atomic_store(&code_alias_count,0);
    sigaction(SIGSEGV, &original[0], NULL); sigaction(SIGBUS, &original[1], NULL);
    void *pending=atomic_exchange(&pending_native_pool,NULL);
    if(pending)munmap(pending,native_pool_size);
    gm_sparse_destroy(&memory); if (guard != MAP_FAILED) munmap(guard, span);
}
void *gsv_reserve_aligned(size_t size, size_t alignment, size_t offset, int prot) {
    uint64_t length, at;
    if (!gsv_enabled() || !rounded(size, &length) || (prot & ~(PROT_READ | PROT_WRITE))) {
        errno = EINVAL; return MAP_FAILED;
    }
    GMResult result;
    do {
        result = gm_sparse_find_aligned(&memory, length, alignment, offset, &at);
        if (result == GM_OK) result = gm_sparse_map(&memory, at, length, (unsigned)prot, 3, false);
    } while (result == GM_OVERLAP);
    if (result != GM_OK) { errno = error_code(result); return MAP_FAILED; }
    report("[software-vm] aligned reservation bytes ", length);
    return (void *)(uintptr_t)at;
}
void *gsv_map(void *address, size_t size, int prot, int flags, int fd, off_t offset) {
    if(flags&MAP_FIXED)gsv_forget_code_alias(address,size);
    if (!gsv_enabled()) return mmap(address, size, prot, flags, fd, offset);
    bool software_hint = gsv_address(address);
    bool eligible = (flags & (MAP_ANON | MAP_PRIVATE)) == (MAP_ANON | MAP_PRIVATE) &&
                    !(flags & ~(MAP_ANON | MAP_PRIVATE | MAP_FIXED | MAP_NORESERVE)) &&
                    !(prot & ~(PROT_READ | PROT_WRITE)) && fd == -1 && offset == 0;
    bool force = eligible && !(flags & MAP_FIXED) &&
                 ((forced_pool_size && size == forced_pool_size) ||
                  (force_threshold && size >= force_threshold) ||
                  (native_pool_size && size >= (64u<<20) && size != native_pool_size));
    if(!address && eligible && !(flags&MAP_FIXED) && !force && size==native_pool_size) {
        void *reserved=atomic_exchange(&pending_native_pool,NULL);
        if(reserved) {
            if(!mprotect(reserved,size,prot))return reserved;
            int failure=errno;munmap(reserved,size);errno=failure;return MAP_FAILED;
        }
    }
    if (!software_hint && !force) {
        void *result = mmap(address, size, prot, flags, fd, offset);
        if (result != MAP_FAILED || errno != ENOMEM || size < (64u << 20)) return result;
    }
    uint64_t length;
    if (!gsv_enabled() || !eligible || !rounded(size, &length) || (!software_hint && (flags & MAP_FIXED))) {
        errno = software_hint ? EINVAL : ENOMEM; return MAP_FAILED;
    }
    uint64_t at = (uintptr_t)address; GMResult result;
    if (software_hint && (flags & MAP_FIXED)) result = gm_sparse_map(&memory, at, length, (unsigned)prot, 3, true);
    else do {
        result = gm_sparse_find_free(&memory, length, &at);
        if (result == GM_OK) result = gm_sparse_map(&memory, at, length, (unsigned)prot, 3, false);
    } while (result == GM_OVERLAP);
    if (result != GM_OK) { errno = error_code(result); return MAP_FAILED; }
    report("[software-vm] mapped bytes ", length); report("[software-vm] mapped at ", at);
    return (void *)(uintptr_t)at;
}
int gsv_protect(void *address, size_t size, int prot) {
    if(!(prot&PROT_READ))gsv_forget_code_alias(address,size);
    if (!gsv_address(address)) return mprotect(address, size, prot);
    uint64_t length;
    if (!rounded(size, &length) || (prot & ~(PROT_READ | PROT_WRITE))) { errno = EINVAL; return -1; }
    GMResult result = gm_sparse_protect(&memory, (uintptr_t)address, length, (unsigned)prot);
    if (result != GM_OK) { errno = error_code(result); return -1; }
    return 0;
}
int gsv_unmap(void *address, size_t size) {
    gsv_forget_code_alias(address,size);
    if (!gsv_address(address)) return munmap(address, size);
    uint64_t length;
    if (!rounded(size, &length)) { errno = EINVAL; return -1; }
    GMResult result = gm_sparse_unmap(&memory, (uintptr_t)address, length);
    if (result != GM_OK) { errno = error_code(result); return -1; }
    return 0;
}
int gsv_advise(void *address, size_t size, int advice) {
    if (!gsv_address(address)) return madvise(address, size, advice);
    switch (advice) {
        case MADV_NORMAL: case MADV_RANDOM: case MADV_SEQUENTIAL: case MADV_WILLNEED:
        case MADV_DONTNEED: case MADV_FREE: case MADV_FREE_REUSABLE: case MADV_FREE_REUSE: break;
        default: errno = EINVAL; return -1;
    }
    GMResult result = gm_sparse_prepare(&memory, (uintptr_t)address, size, 0);
    if (result != GM_OK) { errno = error_code(result); return -1; }
    return 0; // Advice is optional; retain valid data rather than discard it.
}
static GMResult prepare(const void *p, size_t n, unsigned permissions) {
    return gsv_address(p) ? gm_sparse_prepare(&memory, (uintptr_t)p, n, permissions) : GM_OK;
}
const char *gsv_string(const char *source, char *buffer, size_t capacity) {
    if (!source) { errno = EFAULT; return NULL; }
    if (!gsv_address(source)) return source;
    for (size_t i = 0; i < capacity; ++i) {
        if (gm_sparse_read(&memory, (uintptr_t)source + i, buffer + i, 1) != GM_OK) {
            errno = EFAULT; return NULL;
        }
        if (!buffer[i]) return buffer;
    }
    errno = ENAMETOOLONG; return NULL;
}
static size_t scan_chunk(const void *pointer, size_t remaining) {
    size_t n=remaining<256?remaining:256;
    if(gsv_address(pointer)) {
        size_t page_left=GM_PAGE_SIZE-(uintptr_t)pointer%GM_PAGE_SIZE;
        if(n>page_left)n=page_left;
    }
    return n;
}
static void scan_read(const void *source, void *out, size_t size) {
    if(!gsv_address(source)) { memcpy(out,source,size);return; }
    if(gm_sparse_read(&memory,(uintptr_t)source,out,size)!=GM_OK) {
        report("[software-vm] invalid string/buffer access at ",(uintptr_t)source);
        abort();
    }
}
size_t gsv_strnlen(const char *string, size_t limit) {
    if(!limit)return 0;
    if(!gsv_address(string))return strnlen(string,limit);
    size_t done=0;
    while(done<limit) {
        const char *at=string+done;size_t n=scan_chunk(at,limit-done);
        unsigned char bytes[256];scan_read(at,bytes,n);
        unsigned char *end=memchr(bytes,0,n);
        if(end)return done+(size_t)(end-bytes);
        done+=n;
    }
    return done;
}
size_t gsv_strlen(const char *string) {
    return gsv_address(string)?gsv_strnlen(string,SIZE_MAX):strlen(string);
}
int gsv_memcmp(const void *left, const void *right, size_t size) {
    if(!size)return 0;
    if(!gsv_address(left) && !gsv_address(right))return memcmp(left,right,size);
    const unsigned char *a=left,*b=right;
    for(size_t done=0;done<size;) {
        size_t n=scan_chunk(a+done,size-done),other=scan_chunk(b+done,size-done);
        if(n>other)n=other;
        unsigned char aa[256],bb[256];scan_read(a+done,aa,n);scan_read(b+done,bb,n);
        int result=memcmp(aa,bb,n);if(result)return result;
        done+=n;
    }
    return 0;
}
void *gsv_memchr(const void *source, int value, size_t size) {
    if(!size)return NULL;
    if(!gsv_address(source))return memchr(source,value,size);
    const unsigned char *bytes=source;
    for(size_t done=0;done<size;) {
        size_t n=scan_chunk(bytes+done,size-done);
        unsigned char chunk[256];scan_read(bytes+done,chunk,n);
        unsigned char *found=memchr(chunk,value,n);
        if(found)return (void *)(bytes+done+(size_t)(found-chunk));
        done+=n;
    }
    return NULL;
}
int gsv_strncmp(const char *left, const char *right, size_t limit) {
    if(!limit)return 0;
    if(!gsv_address(left) && !gsv_address(right))return strncmp(left,right,limit);
    for(size_t done=0;done<limit;) {
        const char *a=left+done,*b=right+done;
        size_t n=scan_chunk(a,limit-done),other=scan_chunk(b,limit-done);
        if(n>other)n=other;
        // Native strings may be tiny objects: do not memcpy beyond their NUL.
        if(!gsv_address(a)) { size_t length=strnlen(a,n);if(length<n)n=length+1; }
        if(!gsv_address(b)) { size_t length=strnlen(b,n);if(length<n)n=length+1; }
        unsigned char aa[256],bb[256];scan_read(a,aa,n);scan_read(b,bb,n);
        for(size_t i=0;i<n;i++) {
            if(aa[i]!=bb[i])return (int)aa[i]-(int)bb[i];
            if(!aa[i])return 0;
        }
        done+=n;
    }
    return 0;
}
int gsv_strcmp(const char *left, const char *right) {
    return gsv_strncmp(left,right,SIZE_MAX);
}
char *gsv_strchr(const char *string, int value) {
    if(!gsv_address(string))return strchr(string,value);
    for(size_t done=0;;) {
        const char *at=string+done;size_t n=scan_chunk(at,SIZE_MAX);
        unsigned char bytes[256];scan_read(at,bytes,n);
        for(size_t i=0;i<n;i++) {
            if(bytes[i]==(unsigned char)value)return (char *)(at+i);
            if(!bytes[i])return NULL;
        }
        done+=n;
    }
}
GMResult gsv_copy(void *destination, const void *source, size_t size) {
    bool to = gsv_address(destination), from = gsv_address(source);
    if (!to && !from) { memmove(destination, source, size); return GM_OK; }
    GMResult result = prepare(source, size, GM_READ);
    if (result == GM_OK) result = prepare(destination, size, GM_WRITE);
    if (result != GM_OK) return result;
    unsigned char bounce[BOUNCE_SIZE];
    uintptr_t d = (uintptr_t)destination, s = (uintptr_t)source;
    bool reverse = d > s && d - s < size;
    for (size_t completed = 0; completed < size;) {
        size_t chunk = size - completed; if (chunk > sizeof bounce) chunk = sizeof bounce;
        size_t offset = reverse ? size - completed - chunk : completed;
        if (from) result = gm_sparse_read(&memory, s + offset, bounce, chunk);
        else memcpy(bounce, (const void *)(s + offset), chunk);
        if (result != GM_OK) return result;
        if (to) result = gm_sparse_write(&memory, d + offset, bounce, chunk);
        else memcpy((void *)(d + offset), bounce, chunk);
        if (result != GM_OK) return result;
        completed += chunk;
    }
    return GM_OK;
}
GMResult gsv_fill(void *destination, int value, size_t size) {
    if (!gsv_address(destination)) { memset(destination, value, size); return GM_OK; }
    GMResult result = prepare(destination, size, GM_WRITE);
    if (result != GM_OK) return result;
    unsigned char bounce[BOUNCE_SIZE]; memset(bounce, value, sizeof bounce);
    for (size_t completed = 0; completed < size;) {
        size_t chunk = size - completed; if (chunk > sizeof bounce) chunk = sizeof bounce;
        result = gm_sparse_write(&memory, (uintptr_t)destination + completed, bounce, chunk);
        if (result != GM_OK) return result;
        completed += chunk;
    }
    return GM_OK;
}
static ssize_t io_result(int fd, size_t size, ssize_t result, bool software) {
    int saved=errno;
    // Native nonblocking reads commonly have no data yet. Logging each retry
    // floods the guest log and adds synchronous writes to the I/O hot path.
    // Keep software-buffer failures and unexpected native errors diagnostic.
    if (!software && result < 0 && (saved == EAGAIN || saved == EWOULDBLOCK)) {
        errno=saved;
        return result;
    }
    if(result<0 || atomic_fetch_add_explicit(&io_reports,1,memory_order_relaxed)<16) {
        report("[software-vm] file I/O fd ",(uint64_t)fd);
        report("[software-vm] file I/O requested bytes ",size);
        report("[software-vm] file I/O software buffer ",software);
        report("[software-vm] file I/O result ",(uint64_t)result);
        if(result<0)report("[software-vm] file I/O errno ",(uint64_t)saved);
    }
    errno=saved;return result;
}
static ssize_t file_io(int fd, void *buffer, size_t size, off_t offset, bool positional, bool writing) {
    if (!gsv_address(buffer)) {
        ssize_t result=writing ? (positional ? pwrite(fd,buffer,size,offset) : write(fd,buffer,size)) :
                                 (positional ? pread(fd,buffer,size,offset) : read(fd,buffer,size));
        return io_result(fd,size,result,false);
    }
    if (size > INT_MAX) { errno = EINVAL; return io_result(fd,size,-1,true); }
    // Preserve a single syscall's size, file-offset atomicity, short-read and
    // EINTR behavior. Large buffers use temporary ordinary host memory.
    GMResult result = prepare(buffer, size, writing ? GM_READ : GM_WRITE);
    if (result != GM_OK) { errno = EFAULT; return io_result(fd,size,-1,true); }
    unsigned char stack[BOUNCE_SIZE];
    void *bounce = size > sizeof stack ? malloc(size) : stack;
    if (!bounce) { errno = ENOMEM; return io_result(fd,size,-1,true); }
    if (writing && gm_sparse_read(&memory, (uintptr_t)buffer, bounce, size) != GM_OK) {
        if (bounce != stack) free(bounce);
        errno = EFAULT; return io_result(fd,size,-1,true);
    }
    ssize_t done = writing ? (positional ? pwrite(fd, bounce, size, offset) : write(fd, bounce, size)) :
                            (positional ? pread(fd, bounce, size, offset) : read(fd, bounce, size));
    if (!writing && done > 0 && gm_sparse_write(&memory, (uintptr_t)buffer, bounce, (size_t)done) != GM_OK) {
        errno = EFAULT; done = -1;
    }
    int saved_errno = errno;
    if (bounce != stack) free(bounce);
    errno = saved_errno;
    return io_result(fd,size,done,true);
}
ssize_t gsv_read(int fd, void *b, size_t n) { return file_io(fd, b, n, 0, false, false); }
ssize_t gsv_pread(int fd, void *b, size_t n, off_t o) { return file_io(fd, b, n, o, true, false); }
ssize_t gsv_write(int fd, const void *b, size_t n) { return file_io(fd, (void *)b, n, 0, false, true); }
ssize_t gsv_pwrite(int fd, const void *b, size_t n, off_t o) { return file_io(fd, (void *)b, n, o, true, true); }
static size_t stream_io(void *buffer, size_t size, size_t count, FILE *file, bool writing) {
    if (!gsv_address(buffer)) return writing ? fwrite(buffer, size, count, file) : fread(buffer, size, count, file);
    if (!size || !count) return 0;
    if (count > SIZE_MAX / size) { errno = EOVERFLOW; return 0; }
    size_t total = size * count;
    if (prepare(buffer, total, writing ? GM_READ : GM_WRITE) != GM_OK) { errno = EFAULT; return 0; }
    unsigned char bounce[BOUNCE_SIZE]; size_t completed = 0;
    flockfile(file);
    while (completed < total) {
        size_t chunk = total - completed; if (chunk > sizeof bounce) chunk = sizeof bounce;
        if (writing && gm_sparse_read(&memory, (uintptr_t)buffer + completed, bounce, chunk) != GM_OK) { errno = EFAULT; break; }
        size_t done = writing ? fwrite(bounce, 1, chunk, file) : fread(bounce, 1, chunk, file);
        if (!writing && gm_sparse_write(&memory, (uintptr_t)buffer + completed, bounce, done) != GM_OK) { errno = EFAULT; break; }
        completed += done;
        if (done < chunk) break;
    }
    funlockfile(file);
    return completed / size;
}
size_t gsv_fread(void *b, size_t s, size_t n, FILE *f) { return stream_io(b, s, n, f, false); }
size_t gsv_fwrite(const void *b, size_t s, size_t n, FILE *f) { return stream_io((void *)b, s, n, f, true); }
GMSparseStats gsv_stats(void) { return gm_sparse_stats(&memory); }
uint64_t gsv_fault_count(void) { return atomic_load(&fault_count); }

GSVFetchStats gsv_fetch_stats(void) {
    return (GSVFetchStats){atomic_load_explicit(&alias_fetches,memory_order_relaxed),
                          atomic_load_explicit(&checked_fetches,memory_order_relaxed)};
}
