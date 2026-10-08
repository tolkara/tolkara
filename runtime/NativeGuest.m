#import <Foundation/Foundation.h>
#include "NativeGuest.h"
#include "DebuggerArena.h"
#include "HostDiagnostics.h"
#include "NativeCodeMemory.h"
#if TOLKARA_INTEGRATED_AUTH
#import "LocalAuthorization.h"
static NativeCodeMemory local_quarantine;
#endif
#include "GuestFixups.h"
#include "GuestLink.h"
#include "GuestPaths.h"
#include "GuestVMBudget.h"
#include "GuestSoftwareVM.h"
#include "NativeGuestPolicy.h"
#include <TargetConditionals.h>
#include "GuestStubs.h"
#include "GuestTLS.h"
#include "GuestWrap.h"
#include "GuestUnwind.h"
#include "HostExecutionProbe.h"
#include "GuestWait.h"
#include "GuestWaitTrace.h"
#include "SignedImage.h"
#include <dlfcn.h>
#include <mach-o/loader.h>
#import <objc/objc-exception.h>
#import <objc/runtime.h>
#include <dirent.h>
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <sys/utsname.h>
#include <sys/ucontext.h>
#include <fcntl.h>
#include <os/lock.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <mach/mach_time.h>
static atomic_bool initialization_attempted;
static unsigned software_cpu_limit;
// ng_startup_step: a new step restarts its clock; counting within it does not.
static os_unfair_lock startup_lock=OS_UNFAIR_LOCK_INIT;
static NGStartupStep startup_step;
static void startup_begin(const char *step, unsigned long long total) {
    os_unfair_lock_lock(&startup_lock);
    startup_step=(NGStartupStep){step,0,total,mach_absolute_time()};
    os_unfair_lock_unlock(&startup_lock);
}
static void startup_count(unsigned long long done) {
    os_unfair_lock_lock(&startup_lock); startup_step.done=done; os_unfair_lock_unlock(&startup_lock);
}
NGStartupStep ng_startup_step(void) {
    os_unfair_lock_lock(&startup_lock); NGStartupStep step=startup_step; os_unfair_lock_unlock(&startup_lock);
    return step;
}
#if TOLKARA_INTEGRATED_AUTH
static atomic_bool use_local_authorization;
#endif
// Local signing: a page container signed with the user's own identity carries
// the guest's final (post-unpack) __TEXT. It is dlopened so dyld establishes
// kernel-validated executable pages; those pages are then vm_remap'd into the
// guest arena at their preferred addresses. No debugger or JIT is involved.
static char signed_container_path[1024];
static atomic_bool use_signed_image;
static bool refuse(char *error, size_t error_size, const char *reason) {
    if (error && error_size) snprintf(error,error_size,"%s",reason);
    return false;
}
bool ng_use_signed_image(const char *container_path, char *error, size_t error_size) {
    if (atomic_load(&initialization_attempted)) return refuse(error,error_size,"startup was already attempted; restart the app");
#if TOLKARA_INTEGRATED_AUTH
    if (atomic_load(&use_local_authorization)) return refuse(error,error_size,"Developer service is already selected");
#endif
    if (!container_path || !container_path[0]) return refuse(error,error_size,"no container path");
    if (strlen(container_path) >= sizeof signed_container_path) return refuse(error,error_size,"container path is too long");
    strcpy(signed_container_path, container_path);
    atomic_store(&use_signed_image,true);
    return true;
}
static struct {
    bool active, shadow;        // shadow: the rewritten range is still anonymous
    bool verified_write;        // a guest write into signed pages already matched
    void *handle;
    SIImage image;              // container's final __TEXT; arena offset 0 is guest.base
    uintptr_t shadow_size;      // leading __TEXT bytes held anonymously during unpack
} signed_image;
bool ng_use_local_authorization(void) {
#if TOLKARA_INTEGRATED_AUTH
    if(atomic_load(&initialization_attempted) || atomic_load(&use_signed_image)) return false;
    atomic_store(&use_local_authorization,true);return true;
#else
    return false;
#endif
}
#if !TOLKARA_INTEGRATED_AUTH
static atomic_bool use_external_authorization;
#endif
bool ng_use_external_authorization(void) {
#if TOLKARA_INTEGRATED_AUTH
    return false;
#else
    if(atomic_load(&initialization_attempted) || atomic_load(&use_signed_image)) return false;
    atomic_store(&use_external_authorization,true);return true;
#endif
}

static struct {
    GuestImage image;
    NativeCodeMemory arena;
    void *libraries[GI_MAX_DYLIBS];
    uint64_t base, slide;
    FILE *log;
    const char *path;
} guest;
// The libraries the application carries, for the life of the guest.
static GuestLinkSet carried;
static NativeCodeMemory external_quarantine;
// Prepared before the launch, while a debugger was there.
static NativeCodeMemory reserved_arena;
bool ng_arena_reserved(void) { return reserved_arena.published; }
bool ng_reserve_arena(FILE *log) {
    if (reserved_arena.published) return true;
    if (atomic_load(&initialization_attempted) || !da_debugger_present()) return false;
    // A script may refuse the largest; take what it gives, down to 64 MiB.
    size_t page=(size_t)getpagesize(), smallest=64u*1024u*1024u;
    for (size_t size=nc_arena_limit(); size; ) {
        if (da_request_arena(&reserved_arena,size,log) || size<=smallest) break;
        size=size/2<smallest?smallest:size/2; size-=size%page;
    }
    if (!reserved_arena.published) return false;
    (void)da_release_debugger(&reserved_arena,log);
    if (hd_is_executable(reserved_arena.executable)) return true;
    // Useless now, and there is no second chance to ask.
    if (log) fprintf(log,"[native] the reserved arena did not survive the detach\n");
    nc_destroy(&reserved_arena);
    return false;
}
#define LOG(...) do { fprintf(guest.log, __VA_ARGS__); fflush(guest.log); } while (0)
static void log_once(const char *format, ...) __attribute__((format(printf,1,2)));
static unsigned trace_tid(void);
__attribute__((noinline,used,visibility("default")))
void host_debugger_publish_arena(void *address, size_t size, volatile uint64_t *completion) {
    __asm__ volatile("" : : "r"(address), "r"(size), "r"(completion) : "memory");
}
static objc_exception_preprocessor previous_exception_preprocessor;
static id log_exception(id exception) {
    if ([exception isKindOfClass:NSException.class]) {
        NSException *error=exception;
        LOG("[native] Objective-C exception %s: %s\n",error.name.UTF8String,error.reason.UTF8String);
        unsigned index=0;
        for(NSNumber *frame in NSThread.callStackReturnAddresses) {
            uintptr_t address=frame.unsignedLongLongValue;
            uintptr_t base=(uintptr_t)guest.arena.executable;
            BOOL isGuest=address>=base && address-base<guest.arena.size;
            Dl_info symbol={0}; dladdr((void *)address,&symbol);
            LOG("[native] exception frame %u native=%#lx preferred=%#llx symbol=%s\n",index++,address,isGuest?address-guest.slide:0,symbol.dli_sname?:"unknown");
            if(index>=24) break;
        }
    } else LOG("[native] Objective-C exception object class=%s\n",object_getClassName(exception));
    return previous_exception_preprocessor ? previous_exception_preprocessor(exception) : exception;
}
// Opt-in crash diagnostics use only a preopened fd and raw memory reads in the
// signal handler. Chain the client's handler unchanged after saving evidence.
static int signal_log_fd=-1;
static struct sigaction guest_signal_actions[NSIG];
static void signal_hex(const char *label, uintptr_t value) {
    char buffer[128]; size_t n=0; while(label[n] && n<96) { buffer[n]=label[n]; n++; }
    buffer[n++]='0'; buffer[n++]='x';
    for(int shift=60;shift>=0;shift-=4) buffer[n++]="0123456789abcdef"[(value>>shift)&15];
    buffer[n++]='\n'; (void)write(signal_log_fd,buffer,n);
}
static void signal_text(const char *label, const char *text) {
    char buffer[256]; size_t n=0;
    for(;*label && n<64;label++) buffer[n++]=*label;
    for(;text && *text && n<sizeof buffer-1;text++) buffer[n++]=*text;
    buffer[n++]='\n'; (void)write(signal_log_fd,buffer,n);
}
// Which image an address lies in: a placed one by its file and unslid
// address, anything else by what dladdr says (this handler is opt-in).
static void signal_where(const char *label, uintptr_t address) {
    signal_hex(label,address);
    const GuestLibrary *library=gl_library_at(&carried,address);
    uintptr_t base=(uintptr_t)guest.arena.executable;
    if(library) {
        const char *leaf=strrchr(library->path,'/');
        signal_text("  image=",leaf?leaf+1:library->path); signal_hex("  preferred=",address-library->slide);
    }
    else if(address>=base && address-base<guest.arena.size) signal_hex("  preferred=",address-guest.slide);
    else {
        Dl_info info={0};
        if(dladdr((void *)address,&info)) {
            const char *leaf=info.dli_fname?strrchr(info.dli_fname,'/'):NULL;
            signal_text("  image=",leaf?leaf+1:info.dli_fname); signal_text("  symbol=",info.dli_sname);
        }
    }
}
static void diagnostic_signal(int number,siginfo_t *info,void *context) {
    ucontext_t *uc=context;
    signal_hex("signal=",number); signal_hex("fault=",(uintptr_t)info->si_addr);
    arm_thread_state64_t state=uc->uc_mcontext->__ss;
    uintptr_t pc=arm_thread_state64_get_pc(state),fp=arm_thread_state64_get_fp(state);
    signal_where("pc=",pc); signal_where("lr=",arm_thread_state64_get_lr(state));
    for(unsigned i=0;i<32 && fp && !(fp&7);i++) {
        uintptr_t frame[2]; vm_size_t actual=0;
        if(vm_read_overwrite(mach_task_self(),fp,sizeof frame,(vm_address_t)frame,&actual)!=KERN_SUCCESS || actual!=sizeof frame) break;
        uintptr_t lr=frame[1]&0x0000ffffffffffffULL;
        signal_where("frame=",lr);
        if(frame[0]<=fp || frame[0]-fp>8*1024*1024) break; fp=frame[0];
    }
    struct sigaction action=guest_signal_actions[number];
    if(action.sa_flags&SA_SIGINFO) action.sa_sigaction(number,info,context);
    else action.sa_handler(number);
}
static int guest_sigaction(int number,const struct sigaction *action,struct sigaction *old) {
    if (gsv_enabled() && (number==SIGSEGV || number==SIGBUS)) return gsv_sigaction(number,action,old);
    if(signal_log_fd<0 || number<=0 || number>=NSIG) return sigaction(number,action,old);
    struct sigaction installed={0},replacement;
    const struct sigaction *requested=action;
    if(action && (number==SIGABRT || number==SIGSEGV || number==SIGBUS || number==SIGILL || number==SIGTRAP) && action->sa_handler!=SIG_DFL && action->sa_handler!=SIG_IGN) {
        replacement=*action; replacement.sa_sigaction=diagnostic_signal; replacement.sa_flags|=SA_SIGINFO; requested=&replacement;
    }
    int result=sigaction(number,requested,&installed);
    if(result==0) {
        if(old) *old=installed.sa_sigaction==diagnostic_signal ? guest_signal_actions[number] : installed;
        if(action) guest_signal_actions[number]=*action;
    }
    return result;
}
// Nothing to publish: an enabler outside the app prepared this.
static NCPreparation prepare_externally(void *address, size_t size, void *context) {
    (void)context;
    LOG("[native] arena prepared outside this app address=%p size=%zu\n",address,size);
    return NC_PREPARED;
}
static bool publish(void *address, size_t size, void *context) {
    (void)context;
#if TARGET_OS_SIMULATOR
    // The simulator is a Mac process: memory it maps executes without a helper.
    LOG("[native] simulator: arena address=%p size=%zu needs no preparation\n", address, size);
    return true;
#endif
    volatile uint64_t completion = 0;
    LOG("[native] publish fresh zeroed arena address=%p size=%zu\n", address, size);
    host_debugger_publish_arena(address, size, &completion);
    return completion == 0x49504144434f4445ULL;
}
static bool inside(const void *address, size_t size) {
    uintptr_t a = (uintptr_t)address, base = (uintptr_t)guest.arena.executable;
    return a >= base && a - base <= guest.arena.size && size <= guest.arena.size - (a - base);
}
// Progress telemetry reads only runtime counters and kernel thread metadata.
// In particular, it does not sample registers, stacks or application memory.
static void schedule_memory_progress(unsigned tick, uint64_t previous) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        if(!gsv_enabled()) return;
        uint64_t faults=gsv_fault_count();
        GMSparseStats stats=gsv_stats();
        GSVFetchStats fetches=gsv_fetch_stats();
        thread_act_array_t threads=NULL; mach_msg_type_number_t count=0;
        unsigned running=0,waiting=0,other=0;
        if(task_threads(mach_task_self(),&threads,&count)==KERN_SUCCESS) {
            for(mach_msg_type_number_t i=0;i<count;i++) {
                thread_basic_info_data_t info={0}; mach_msg_type_number_t length=THREAD_BASIC_INFO_COUNT;
                if(thread_info(threads[i],THREAD_BASIC_INFO,(thread_info_t)&info,&length)==KERN_SUCCESS) {
                    if(info.run_state==TH_STATE_RUNNING) running++;
                    else if(info.run_state==TH_STATE_WAITING) waiting++;
                    else other++;
                } else other++;
                mach_port_deallocate(mach_task_self(),threads[i]);
            }
            vm_deallocate(mach_task_self(),(vm_address_t)threads,count*sizeof(thread_act_t));
        }
        log_once("[software-vm] progress tick=%u faults=%llu delta=%llu backing_pages=%zu writes=%llu threads_running=%u waiting=%u other=%u\n",
            tick,(unsigned long long)faults,(unsigned long long)(faults-previous),stats.resident_pages,
            (unsigned long long)stats.write_operations,running,waiting,other);
        log_once("[software-vm] fetch paths tick=%u alias=%llu checked=%llu\n",tick,
            (unsigned long long)fetches.alias_fetches,(unsigned long long)fetches.checked_fetches);
        task_vm_info_data_t vm={0};mach_msg_type_number_t vm_count=TASK_VM_INFO_COUNT;
        if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vm,&vm_count)==KERN_SUCCESS &&
           vm_count>=TASK_VM_INFO_REV1_COUNT)
            log_once("[software-vm] host memory tick=%u footprint=%llu resident=%llu virtual=%llu available=%zu\n",
                tick,(unsigned long long)vm.phys_footprint,(unsigned long long)vm.resident_size,
                (unsigned long long)vm.virtual_size,nc_available_memory());
        for(unsigned thread=1;thread<=GWT_THREAD_LIMIT;thread++) {
            GWWaitRecord wait;
            if(gwt_snapshot(thread,&wait))
                log_once("[software-vm] wait tick=%u t%u %s address=%p software=%d\n",tick,thread,
                    wait.operation,(void *)wait.address,gsv_address((void *)wait.address));
        }
        schedule_memory_progress(tick+1,faults);
    });
}
// Optional diagnostics after debugger detachment. Log our own threads'
// program counters and symbols only; never copy guest code or data, attach,
// suspend a thread, or modify guest registers/instructions.
static void describe_caller(const void *address, char *out, size_t size);
static void sample_all_threads(unsigned number) {
    thread_act_array_t threads=NULL; mach_msg_type_number_t count=0;
    if(task_threads(mach_task_self(),&threads,&count)!=KERN_SUCCESS) return;
    flockfile(guest.log);
    LOG("[native] threads sample %u count=%u\n",number,count);
    for(mach_msg_type_number_t i=0;i<count;i++) {
        arm_thread_state64_t state={0}; mach_msg_type_number_t stateCount=ARM_THREAD_STATE64_COUNT;
        kern_return_t kr=thread_get_state(threads[i],ARM_THREAD_STATE64,(thread_state_t)&state,&stateCount);
        uintptr_t pc=kr==KERN_SUCCESS?arm_thread_state64_get_pc(state):0;
        char where[512]; describe_caller((void *)pc,where,sizeof where);
        LOG("[native] thread %u pc=%#lx %s\n",i,(unsigned long)pc,where);
        if(kr!=KERN_SUCCESS) { mach_port_deallocate(mach_task_self(),threads[i]); continue; }
        // Poor-man's stack: guest frames carry no frame pointers, so scan the
        // live stack and log only words that resolve to code, never the data.
        uintptr_t sp=arm_thread_state64_get_sp(state);
        uintptr_t lr=arm_thread_state64_get_lr(state)&0x0000ffffffffffffULL;
        describe_caller((void *)lr,where,sizeof where);
        LOG("[native] thread %u lr=%#lx %s\n",i,(unsigned long)lr,where);
        enum { SCAN=16384 };
        uintptr_t window[SCAN/8];
        vm_size_t got=0;
        if(sp && vm_read_overwrite(mach_task_self(),sp,SCAN,(vm_address_t)window,&got)==KERN_SUCCESS) {
            unsigned shown=0; uintptr_t previous=0;
            for(unsigned w=0;w<got/8 && shown<12;w++) {
                uintptr_t value=window[w]&0x0000ffffffffffffULL;
                if(value==previous || !(value&0xffff00000000ULL)) continue;
                Dl_info vinfo={0}; dladdr((void *)value,&vinfo);
                bool guestCode=inside((void *)value,1);
                if(!guestCode && !vinfo.dli_fname) continue;
                previous=value; shown++;
                describe_caller((void *)value,where,sizeof where);
                LOG("[native] thread %u stack %u %#lx %s\n",i,shown,(unsigned long)value,where);
            }
        }
        mach_port_deallocate(mach_task_self(),threads[i]);
    }
    funlockfile(guest.log);
    if(threads) vm_deallocate(mach_task_self(),(vm_address_t)threads,count*sizeof(thread_act_t));
}
static void schedule_native_sample(thread_t thread, unsigned number) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        arm_thread_state64_t state={0}; mach_msg_type_number_t count=ARM_THREAD_STATE64_COUNT;
        kern_return_t kr=thread_get_state(thread,ARM_THREAD_STATE64,(thread_state_t)&state,&count);
        if(kr==KERN_SUCCESS) {
            uintptr_t pc=arm_thread_state64_get_pc(state), fp=arm_thread_state64_get_fp(state);
            flockfile(guest.log);
            LOG("[native] sample %u pc=%#lx preferred=%#llx\n",number,pc,inside((void *)pc,1)?pc-guest.slide:0);
            Dl_info info={0}; dladdr((void *)pc,&info);
            LOG("[native] sample symbol=%s image=%s\n",info.dli_sname?:"unknown",info.dli_fname?:"unknown");
            for(unsigned i=0;i<24 && fp && !(fp&7);i++) {
                uintptr_t frame[2]; vm_size_t actual=0;
                if(vm_read_overwrite(mach_task_self(),fp,sizeof frame,(vm_address_t)frame,&actual)!=KERN_SUCCESS || actual!=sizeof frame) break;
                uintptr_t lr=frame[1] & 0x0000ffffffffffffULL; info=(Dl_info){0}; dladdr((void *)lr,&info);
                LOG("[native] sample frame %u lr=%#lx preferred=%#llx symbol=%s image=%s\n",i,lr,inside((void *)lr,1)?lr-guest.slide:0,info.dli_sname?:"unknown",info.dli_fname?:"unknown");
                if(frame[0]<=fp || frame[0]-fp>8*1024*1024) break; fp=frame[0];
            }
            funlockfile(guest.log);
        } else LOG("[native] sample unavailable kr=%d\n",kr);
        sample_all_threads(number);
        if(number<360) schedule_native_sample(thread,number+1);
        else mach_port_deallocate(mach_task_self(),thread);
    });
}
static NSBundle *guest_bundle;
static CFBundleRef guest_cf_bundle;
static NSArray<NSString *> *guest_arguments;
// argv[1..] for a compatibility runtime (profile command line); see ng_set_arguments.
static char *launch_arguments[64];
static size_t launch_argument_count;
void ng_set_arguments(const char *const *arguments, size_t count) {
    for (size_t i=0;i<launch_argument_count;i++) { free(launch_arguments[i]); launch_arguments[i]=NULL; }
    launch_argument_count=0;
    for (size_t i=0;i<count && i<64;i++) {
        if (!arguments[i] || strlen(arguments[i])>4096) break;
        launch_arguments[launch_argument_count++]=strdup(arguments[i]);
    }
}
// Libraries a profile names beside the executable's own list; see ng_set_libraries.
static char *launch_root, *launch_libraries[GL_MAX_LIBRARIES];
static size_t launch_library_count;
void ng_set_libraries(const char *root, const char *const *paths, size_t count) {
    free(launch_root); launch_root=NULL;
    for (size_t i=0;i<launch_library_count;i++) { free(launch_libraries[i]); launch_libraries[i]=NULL; }
    launch_library_count=0;
    if (root && strlen(root)<PATH_MAX) launch_root=strdup(root);
    for (size_t i=0;i<count && i<GL_MAX_LIBRARIES;i++) {
        if (!paths[i] || strlen(paths[i])>=PATH_MAX) break;
        launch_libraries[launch_library_count++]=strdup(paths[i]);
    }
}
// See ng_set_code_pool.
static size_t code_pool_size;
void ng_set_code_pool(size_t size) { code_pool_size=size; }
// ${CodePool} in the environment's values, now that the pool exists.
static void expand_code_pool(const char *executable, const char *writable, size_t size) {
    char replacement[64], value[4096];
    snprintf(replacement,sizeof replacement,"%#lx-%#lx@%#lx",(unsigned long)(uintptr_t)executable,
             (unsigned long)((uintptr_t)executable+size),(unsigned long)(uintptr_t)writable);
    extern char **environ;
    // Names first: setenv may reallocate environ.
    NSMutableArray<NSString *> *names=[NSMutableArray new];
    for (char **entry=environ;*entry;entry++) if (strstr(*entry,"${CodePool}")) {
        const char *equals=strchr(*entry,'=');
        if (equals) [names addObject:[[NSString alloc] initWithBytes:*entry length:(NSUInteger)(equals-*entry) encoding:NSUTF8StringEncoding]];
    }
    for (NSString *name in names) {
        const char *current=getenv(name.UTF8String);
        if (current && ng_expand(current,"${CodePool}",replacement,value,sizeof value)) {
            setenv(name.UTF8String,value,1);
            LOG("[native] environment %s: code pool %s\n",name.UTF8String,replacement);
        }
    }
}
static NSArray<NSString *> *(*original_arguments)(id,SEL);
static NSArray<NSString *> *guest_process_arguments(id receiver,SEL selector) {
    if(guest_arguments && inside(__builtin_return_address(0),1)) {
        static BOOL reported;
        if(!reported){reported=YES;LOG("[native] guest NSProcessInfo arguments count=%lu\n",(unsigned long)guest_arguments.count);}
        return guest_arguments;
    }
    return original_arguments(receiver,selector);
}
static NSBundle *(*original_main_bundle)(id,SEL);
static NSBundle *guest_main_bundle(id receiver, SEL selector) {
    if (guest_bundle && inside(__builtin_return_address(0),1)) return guest_bundle;
    return original_main_bundle(receiver,selector);
}
static CFBundleRef guest_cf_main_bundle(void) {
    if (guest_cf_bundle) return guest_cf_bundle;
    return CFBundleGetMainBundle();
}
// A guest write into signed __TEXT pages must reproduce the baked bytes
// exactly: the guest's unpacking initializer re-derives the same unpacked code
// every launch. Any mismatch proves non-determinism (or a stale container) and
// is logged with the exact address before the hook aborts.
static void explain_exec_mismatch(void) {
    if (signed_image.shadow_size || signed_image.verified_write) return;
    LOG("[signed-image] FATAL: the container holds this guest's on-disk __TEXT, but the guest rewrites its code at startup; "
        "build the container from a capture of the final pages\n");
}
static bool verify_exec_write(const void *destination, const void *source, size_t size) {
    const unsigned char *d=destination,*s=source;
    for (size_t i=0;i<size;i++) if (d[i]!=s[i]) {
        uintptr_t offset=(uintptr_t)destination-(uintptr_t)guest.arena.executable+i;
        LOG("[signed-image] FATAL: regenerated code mismatch at preferred=%#llx baked=%02x regenerated=%02x (write size=%zu)\n",
            (unsigned long long)(guest.base+offset),d[i],s[i],size);
        explain_exec_mismatch();
        return false;
    }
    if (size) signed_image.verified_write=true;
    return true;
}
static bool inside_exec(const void *address, size_t size) {
    if (!signed_image.active || !inside(address,size)) return false;
    uintptr_t offset=(uintptr_t)address-(uintptr_t)guest.arena.executable;
    return offset<signed_image.image.size && size<=signed_image.image.size-offset;
}
// The leading [0, shadow_size) __TEXT pages hold the packed bytes on writable
// anonymous memory while the unpacking initializer runs; the remaining pages
// are already the kernel-validated signed ones.
static bool inside_shadow(const void *address, size_t size) {
    if (!signed_image.shadow || !inside_exec(address,size)) return false;
    uintptr_t offset=(uintptr_t)address-(uintptr_t)guest.arena.executable;
    return offset<signed_image.shadow_size && size<=signed_image.shadow_size-offset;
}
// Leading bytes of a __TEXT write that land in the still-anonymous shadow.
static size_t shadow_part(const void *destination, size_t size) {
    uintptr_t offset=(uintptr_t)destination-(uintptr_t)guest.arena.executable;
    if (!signed_image.shadow || offset>=signed_image.shadow_size) return 0;
    return signed_image.shadow_size-offset<size ? signed_image.shadow_size-offset : size;
}
// Guest memcpy/memmove into __TEXT: shadow bytes are written, signed bytes must
// regenerate identically. The signed part is verified first, before the shadow
// write can overwrite its overlapping source; memmove handles overlap.
static bool final_image_write(void *destination, const void *source, size_t size) {
    size_t shadow=shadow_part(destination,size);
    if (shadow<size && !verify_exec_write((char *)destination+shadow,(const char *)source+shadow,size-shadow)) return false;
    if (shadow) memmove(destination,source,shadow);
    return true;
}
static bool final_image_memset(void *destination, int value, size_t size) {
    size_t shadow=shadow_part(destination,size);
    const unsigned char *d=destination;
    for (size_t i=shadow;i<size;i++) if (d[i]!=(unsigned char)value) {
        uintptr_t at=(uintptr_t)destination-(uintptr_t)guest.arena.executable+i;
        LOG("[signed-image] FATAL: memset verification mismatch at preferred=%#llx baked=%02x value=%02x\n",
            (unsigned long long)(guest.base+at),d[i],(unsigned)value&0xff);
        explain_exec_mismatch();
        return false;
    }
    if (shadow<size) signed_image.verified_write=true;
    if (shadow) memset(destination,value,shadow);
    return true;
}
static void *write_view(void *destination, size_t size) {
    // Local signing: the mem* hooks shadow or verify writes into __TEXT.
    if (signed_image.active) return destination;
    if (inside(destination, size)) return (char *)guest.arena.writable + ((uintptr_t)destination - (uintptr_t)guest.arena.executable);
    return destination;
}
static void *guest_memcpy(void *destination, const void *source, size_t size) {
    if (inside_exec(destination,size)) {
        if (!final_image_write(destination,source,size)) abort();
        return destination;
    }
    void *alias = write_view(destination, size);
    if (gsv_address(alias) || gsv_address(source)) {
        GMResult result=gsv_copy(alias,source,size);
        if (result!=GM_OK) { LOG("[software-vm] memcpy failed result=%d bytes=%zu\n",result,size); abort(); }
    } else memcpy(alias, source, size);
    if (alias != destination) { sys_dcache_flush(alias,size); sys_icache_invalidate(destination,size); }
    return destination;
}
static void *guest_memmove(void *destination, const void *source, size_t size) {
    if (inside_exec(destination,size)) {
        if (!final_image_write(destination,source,size)) abort();
        return destination;
    }
    void *alias = write_view(destination, size);
    // Use the same view for overlapping guest source and destination.
    if (alias != destination && inside(source,size)) source = write_view((void *)source,size);
    if (gsv_address(alias) || gsv_address(source)) {
        GMResult result=gsv_copy(alias,source,size);
        if (result!=GM_OK) { LOG("[software-vm] memmove failed result=%d bytes=%zu\n",result,size); abort(); }
    } else memmove(alias, source, size);
    if (alias != destination) { sys_dcache_flush(alias,size); sys_icache_invalidate(destination,size); }
    return destination;
}
static void *guest_memset(void *destination, int value, size_t size) {
    if (inside_exec(destination,size)) {
        if (!final_image_memset(destination,value,size)) abort();
        return destination;
    }
    void *alias = write_view(destination,size);
    if (gsv_address(alias)) {
        GMResult result=gsv_fill(alias,value,size);
        if (result!=GM_OK) { LOG("[software-vm] memset failed result=%d bytes=%zu\n",result,size); abort(); }
    } else memset(alias,value,size);
    if (alias != destination) { sys_dcache_flush(alias,size); sys_icache_invalidate(destination,size); }
    return destination;
}
static void guest_bzero(void *destination,size_t size) { guest_memset(destination,0,size); }
static void *guest_memcpy_chk(void *d,const void *s,size_t n,size_t bound) {
    if(n>bound) abort(); return guest_memcpy(d,s,n);
}
static void *guest_memmove_chk(void *d,const void *s,size_t n,size_t bound) {
    if(n>bound) abort(); return guest_memmove(d,s,n);
}
static void *guest_memset_chk(void *d,int c,size_t n,size_t bound) {
    if(n>bound) abort(); return guest_memset(d,c,n);
}
static int guest_dladdr(const void *address, Dl_info *info) {
    // Libraries find their own file and header this way, as they would with dyld.
    const GuestLibrary *library=gl_library_at(&carried,(uint64_t)(uintptr_t)address);
    if (library) {
        *info = (Dl_info){.dli_fname=library->path,.dli_fbase=(void *)(uintptr_t)(library->image.header_address+library->slide)};
        LOG("[native] dladdr(%p) -> %s base=%p\n",address,library->install_name,info->dli_fbase); return 1;
    }
    if (inside(address,1)) {
        *info = (Dl_info){.dli_fname=guest.path,.dli_fbase=guest.arena.executable};
        LOG("[native] dladdr(%p) -> original image base=%p\n",address,info->dli_fbase); return 1;
    }
    return dladdr(address,info);
}
// Experimental, opt-in (TOLKARA_VM_BUDGET_MB, off by default): the guest's
// large anonymous reservations fit a virtual-memory budget; see GuestVMBudget.h.
static GVBudget vm_budget;
static bool trace_memory_operations(void) {
    static dispatch_once_t once;
    static bool enabled;
    dispatch_once(&once, ^{
        const char *value=getenv("TOLKARA_TRACE_MEMORY");
        enabled=value && !strcmp(value,"1");
    });
    return enabled;
}
static int guest_madvise(void *address, size_t size, int advice) {
    return gsv_enabled()?gsv_advise(address,size,advice):gv_advise(&vm_budget,address,size,advice);
}
static int guest_mprotect(void *address, size_t size, int prot) {
    if(trace_memory_operations()) LOG("[native] mprotect(%p,%#zx,%d)\n",address,size,prot);
    // Local signing: shadow pages are plain writable anonymous memory; signed
    // pages already have their final protection by construction.
    if (inside_exec(address,size)) {
        if (inside_shadow(address,size)) return mprotect(address,size,PROT_READ|PROT_WRITE);
        return 0;
    }
    // Keep executable backing RX; imported stores/copies use its shared RW view.
    if (inside(address,size) && (prot & PROT_EXEC)) prot &= ~PROT_WRITE;
    int result = gsv_enabled()?gsv_protect(address,size,prot):gv_protect(&vm_budget,address,size,prot);
    if (result) LOG("[native] mprotect failed errno=%d\n",errno);
    return result;
}
static int guest_munmap(void *address, size_t size) {
    gsv_forget_code_alias(address,size);
    if(trace_memory_operations()) LOG("[native] munmap(%p,%#zx)\n",address,size);
    // Local signing: keep validated pages; shadow pages stay mapped+writable.
    if (inside_exec(address,size)) {
        if (inside_shadow(address,size)) return mprotect(address,size,PROT_READ|PROT_WRITE);
        return 0;
    }
    // Reserve the runtime arena so a later fixed/hinted remap preserves the RX
    // backing established before guest execution. Inaccessible until remapped.
    if (inside(address,size)) return mprotect(address,size,PROT_NONE);
    return gsv_enabled()?gsv_unmap(address,size):gv_unmap(&vm_budget,address,size);
}
static void *guest_mmap(void *address, size_t size, int prot, int flags, int fd, off_t offset) {
    if(trace_memory_operations()) LOG("[native] mmap(%p,%#zx,%d,%#x,%d,%lld)\n",address,size,prot,flags,fd,(long long)offset);
    if (inside_exec(address,size) && (flags & MAP_ANON) && (flags & MAP_PRIVATE) &&
        fd == -1 && offset == 0 && !((uintptr_t)address % GM_PAGE_SIZE) && size && !(size % GM_PAGE_SIZE)) {
        if (inside_shadow(address,size)) {
            memset(address,0,size);
            return address;
        }
        // The unpacker's MAP_JIT re-map of a signed range is a no-op: the
        // signed pages already hold the final bytes and the following memcpy
        // verifies them.
        LOG("[signed-image] MAP_JIT remap of signed range satisfied in place\n");
        return address;
    }
    if (inside(address,size) && (flags & MAP_ANON) && (flags & MAP_PRIVATE) && fd == -1 && offset == 0 &&
        !((uintptr_t)address % GM_PAGE_SIZE) && size && !(size % GM_PAGE_SIZE)) {
        void *alias = write_view(address,size); memset(alias,0,size);
        if (guest_mprotect(address,size,prot)) return MAP_FAILED;
        sys_dcache_flush(alias,size); sys_icache_invalidate(address,size);
        return address;
    }
    void *result;
    if (gsv_enabled()) result=gsv_map(address,size,prot,flags,fd,offset);
    else if (gv_counts(&vm_budget,address,size,flags)) {
        size_t granted;
        result=gv_reserve(&vm_budget,size,prot,flags,fd,&granted);
        int code=errno;
        if (result!=MAP_FAILED && granted<size)
            log_once("[native] reservation of %zu MB downsized to %zu MB (TOLKARA_VM_BUDGET_MB)\n",size>>20,granted>>20);
        errno=code;
    } else result=gv_map(&vm_budget,address,size,prot,flags,fd,offset);
    if(trace_memory_operations() || result==MAP_FAILED) LOG("[native] mmap -> %p errno=%d\n",result,result==MAP_FAILED?errno:0);
    return result;
}
static void guest_jit_protect(int enabled) { LOG("[native] jit write protection=%d (separate RW/RX views)\n",enabled); }
// compiler-rt's instruction cache flush, which iPadOS's libSystem does not
// export: after code is written, before it runs.
static void guest_clear_cache(char *start, char *end) { if (start && end>start) sys_icache_invalidate(start,(size_t)(end-start)); }
static void guest_unexpected_lazy_bind(void) {
    LOG("[native] unexpected lazy binder call after eager binding\n"); __builtin_trap();
}
__attribute__((noinline,used,visibility("default")))
void host_debugger_guest_complete(bool ok) { __asm__ volatile("" : : "r"(ok) : "memory"); }
extern void *guest_tlv_bootstrap(const uint64_t descriptor[3]);
// One registration per image, found by its descriptor range.
static GTImage guest_tls[1+GL_MAX_LIBRARIES];
static size_t guest_tls_count;
void *guest_tlv_address(const uint64_t descriptor[3]) {
    const char *owner;
    void *value=gt_find(guest_tls,guest_tls_count,descriptor,&owner);
    if (value) return value;
    if (owner) LOG("[native] %s: no thread-local storage for descriptor %p\n",owner,descriptor);
    else LOG("[native] invalid TLS descriptor %p\n",descriptor);
    abort();
}
// The image's initial thread-local bytes and its descriptors.
static bool setup_tls(GuestImage *image, uint64_t slide, const char *name) {
    if (!image->has_tls) return true;
    if (image->tls_initializer_count) { LOG("[native] %s: TLS constructors unsupported\n",name); return false; }
    // No descriptors of its own: nothing to set up.
    if (!image->tls_descriptors_size) return true;
    if (guest_tls_count==sizeof guest_tls/sizeof *guest_tls) { LOG("[native] %s: too many images with TLS\n",name); return false; }
    GTImage *tls=&guest_tls[guest_tls_count];
    void *template=image->tls_size?malloc((size_t)image->tls_size):NULL;
    bool ready=(!image->tls_size ||
                (template && gm_read(&image->memory,image->tls_address,template,(size_t)image->tls_size)==GM_OK)) &&
        gt_register(tls,name,template,(size_t)image->tls_size,image->tls_alignment,
            (uintptr_t)(image->tls_descriptors+slide),(size_t)image->tls_descriptors_size);
    free(template);
    if (!ready) { LOG("[native] %s: TLS template setup failed\n",name); return false; }
    if (image->tls_size) LOG("[native] %s: TLS template size=%zu alignment=%zu descriptors=%zu\n",
        name,tls->tls.size,tls->tls.alignment,tls->descriptors_size/24);
    else LOG("[native] %s: %zu thread-local descriptors with no storage; refused where used\n",
        name,tls->descriptors_size/24);
    guest_tls_count++;
    return true;
}
static int guest_executable_path(char *buffer, uint32_t *size) {
    size_t required=strlen(guest.path)+1;
    if (!size) { errno=EINVAL; return -1; }
    if (!buffer || *size<required) { *size=(uint32_t)required; return -1; }
    memcpy(buffer,guest.path,required); return 0;
}
static void *guest_dlsym(void *, const char *);
static void *guest_dlopen(const char *, int);
static int guest_dlclose(void *);
static char *guest_dlerror(void);
static int guest_system(const char *);
static FILE *guest_popen(const char *, const char *);
static int guest_posix_spawn(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *,
                             char *const *, char *const *);
static NGExitObserver guest_exit_observer;
static void *guest_exit_context;
static atomic_bool guest_exit_notifying;
static void guest_exit(int) __attribute__((noreturn));
static void guest_quick_exit(int) __attribute__((noreturn));
static void guest_abort(void) __attribute__((noreturn));
// Opt-in tracing (--trace-guest): the guest's failed file access, the
// directories it creates and the environment variables it reads. Off by
// default, and then the guest binds straight to libc for these.
static bool trace_guest;
static int guest_open(const char *, int, ...);
static int guest_openat(int, const char *, int, ...);
static int guest_stat(const char *, struct stat *);
static int guest_fstatat(int, const char *, struct stat *, int);
static int guest_lstat(const char *, struct stat *);
static int guest_fstat(int, struct stat *);
static int guest_access(const char *, int);
static FILE *guest_fopen(const char *, const char *);
static FILE *guest_fopen_extsn(const char *, const char *);
static int guest_mkdir(const char *, mode_t);
static char *guest_getenv(const char *);
// Experimental, opt-in (--case-insensitive-files): a file lookup that fails
// with ENOENT or ENOTDIR is retried with each missing component matched
// ignoring case, as on macOS. Off by default; a profile's caseAliases covers
// known cases without it.
static bool case_insensitive_files;
static DIR *guest_opendir(const char *);
static struct dirent *guest_readdir(DIR *);
static int guest_socket(int, int, int);
static int guest_connect(int, const struct sockaddr *, socklen_t);
static int guest_getsockopt(int, int, int, void *, socklen_t *);
static int guest_setsockopt(int, int, int, const void *, socklen_t);
static int guest_shutdown(int, int);
static int guest_poll(struct pollfd *, nfds_t, int);
static ssize_t guest_sendto(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static ssize_t guest_recvfrom(int, void *, size_t, int, struct sockaddr *, socklen_t *);
static int guest_sysctlbyname(const char *, void *, size_t *, void *, size_t);
static int guest_sysctl(int *, u_int, void *, size_t *, void *, size_t);
static long guest_sysconf(int);
static int guest_uname(struct utsname *);
static int guest_gethostname(char *, size_t);
static char *guest_realpath(const char *, char *);
static char *guest_realpath_extsn(const char *, char *);
// Handles to the placed images a guest dlopen yields: the tag, RTLD_FIRST, and
// the image in the low byte (0 the executable, n carried library n-1).
#define GUEST_HANDLE_TAG 0x7400000000000000ULL
#define GUEST_HANDLE_FIRST 0x100ULL
static bool guest_handle(const void *handle, size_t *index, bool *first) {
    uintptr_t value=(uintptr_t)handle;
    if ((value&~(GUEST_HANDLE_FIRST|0xffULL))!=GUEST_HANDLE_TAG || (value&0xff)>carried.count) return false;
    *index=value&0xff; *first=(value&GUEST_HANDLE_FIRST)!=0;
    return true;
}
static void *placed_symbol(size_t index, const char *name, bool first);
extern int __ulock_wait(uint32_t,void *,uint64_t,uint32_t);
static bool (*shader_wait_pending)(void);
static bool shader_pending(void) { return shader_wait_pending && shader_wait_pending(); }
static void pump_shader_wait(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode,.001,true); }
#define WAIT_TRACE_CALL(name,address,expression) \
    unsigned tid=(trace_guest && gsv_enabled())?trace_tid():0; \
    GWWaitRecord previous=gwt_begin(tid,name,address); \
    int result=(expression); int code=errno; gwt_end(tid,previous); errno=code; return result
static int guest_mutex_lock(pthread_mutex_t *mutex) {
    WAIT_TRACE_CALL("pthread_mutex_lock",mutex,pthread_mutex_lock(mutex));
}
static int guest_cond_wait(pthread_cond_t *condition,pthread_mutex_t *mutex) {
    WAIT_TRACE_CALL("pthread_cond_wait",condition,pthread_cond_wait(condition,mutex));
}
static int guest_cond_timedwait(pthread_cond_t *condition,pthread_mutex_t *mutex,const struct timespec *deadline) {
    WAIT_TRACE_CALL("pthread_cond_timedwait",condition,pthread_cond_timedwait(condition,mutex,deadline));
}
static int guest_cond_relativewait(pthread_cond_t *condition,pthread_mutex_t *mutex,const struct timespec *timeout) {
    WAIT_TRACE_CALL("pthread_cond_timedwait_relative_np",condition,pthread_cond_timedwait_relative_np(condition,mutex,timeout));
}
static int guest_rwlock_read(pthread_rwlock_t *lock) {
    WAIT_TRACE_CALL("pthread_rwlock_rdlock",lock,pthread_rwlock_rdlock(lock));
}
static int guest_rwlock_write(pthread_rwlock_t *lock) {
    WAIT_TRACE_CALL("pthread_rwlock_wrlock",lock,pthread_rwlock_wrlock(lock));
}
static kern_return_t guest_semaphore_wait(semaphore_t semaphore) {
    WAIT_TRACE_CALL("semaphore_wait",(void *)(uintptr_t)semaphore,semaphore_wait(semaphore));
}
#undef WAIT_TRACE_CALL
static long guest_dispatch_wait(dispatch_semaphore_t semaphore,dispatch_time_t timeout) {
    unsigned tid=(trace_guest && gsv_enabled())?trace_tid():0;
    GWWaitRecord previous=gwt_begin(tid,"dispatch_semaphore_wait",(__bridge void *)semaphore);
    long result=dispatch_semaphore_wait(semaphore,timeout);
    int code=errno;gwt_end(tid,previous);errno=code;return result;
}
static int guest_ulock_wait(uint32_t operation,void *address,uint64_t value,uint32_t timeout) {
    static _Thread_local bool pumping;
    if(pumping) return __ulock_wait(operation,address,value,timeout);
    pumping=true;
    unsigned tid=(trace_guest && gsv_enabled())?trace_tid():0;
    GWWaitRecord previous=gwt_begin(tid,"__ulock_wait",address);
    int result=gw_wait(__ulock_wait,operation,address,value,timeout,pthread_main_np()!=0,shader_pending,pump_shader_wait);
    int code=errno;gwt_end(tid,previous);errno=code;
    pumping=false; return result;
}
static void *hook(const char *name) {
#define HOOK(n,f) if (!strcmp(name,n)) return (void *)&f
    HOOK("sigaction",guest_sigaction);
    HOOK("__ulock_wait",guest_ulock_wait);
    HOOK("CFBundleGetMainBundle",guest_cf_main_bundle);
    HOOK("_NSGetExecutablePath",guest_executable_path);
    HOOK("_tlv_bootstrap",guest_tlv_bootstrap);
    HOOK("dyld_stub_binder",guest_unexpected_lazy_bind);
    HOOK("dladdr",guest_dladdr); HOOK("dlsym",guest_dlsym);
    HOOK("dlopen",guest_dlopen); HOOK("dlclose",guest_dlclose); HOOK("dlerror",guest_dlerror);
    HOOK("system",guest_system); HOOK("popen",guest_popen); HOOK("posix_spawn",guest_posix_spawn);
    HOOK("exit",guest_exit); HOOK("_exit",guest_quick_exit); HOOK("_Exit",guest_quick_exit); HOOK("abort",guest_abort);
    if (trace_guest || case_insensitive_files || gsv_enabled()) {
        HOOK("open",guest_open); HOOK("openat",guest_openat); HOOK("stat",guest_stat); HOOK("lstat",guest_lstat);
        HOOK("fstatat",guest_fstatat);
        HOOK("access",guest_access); HOOK("opendir",guest_opendir);
        HOOK("fopen",guest_fopen); HOOK("fopen$DARWIN_EXTSN",guest_fopen_extsn);
        HOOK("realpath",guest_realpath); HOOK("realpath$DARWIN_EXTSN",guest_realpath_extsn);
        if (trace_guest) HOOK("readdir",guest_readdir);
    }
    if (trace_guest) { HOOK("mkdir",guest_mkdir); HOOK("getenv",guest_getenv);
        HOOK("socket",guest_socket); HOOK("connect",guest_connect);
        HOOK("getsockopt",guest_getsockopt); HOOK("setsockopt",guest_setsockopt);
        HOOK("shutdown",guest_shutdown); HOOK("poll",guest_poll);
        HOOK("sendto",guest_sendto); HOOK("recvfrom",guest_recvfrom);
        HOOK("uname",guest_uname); HOOK("gethostname",guest_gethostname); }
    HOOK("mmap",guest_mmap); HOOK("mprotect",guest_mprotect); HOOK("munmap",guest_munmap);
    if (gv_enabled(&vm_budget) || gsv_enabled()) HOOK("madvise",guest_madvise);
    HOOK("memcpy",guest_memcpy); HOOK("memmove",guest_memmove); HOOK("memset",guest_memset);
    if (gsv_enabled()) {
        HOOK("fstat",guest_fstat);
        HOOK("bzero",guest_bzero);
        HOOK("__memcpy_chk",guest_memcpy_chk); HOOK("__memmove_chk",guest_memmove_chk); HOOK("__memset_chk",guest_memset_chk);
        HOOK("read",gsv_read); HOOK("pread",gsv_pread); HOOK("write",gsv_write); HOOK("pwrite",gsv_pwrite);
        HOOK("fread",gsv_fread); HOOK("fwrite",gsv_fwrite);
        HOOK("strlen",gsv_strlen); HOOK("strnlen",gsv_strnlen);
        HOOK("strcmp",gsv_strcmp); HOOK("strncmp",gsv_strncmp);
        HOOK("memcmp",gsv_memcmp); HOOK("memchr",gsv_memchr); HOOK("strchr",gsv_strchr);
        if(trace_guest) {
            HOOK("pthread_mutex_lock",guest_mutex_lock);
            HOOK("pthread_cond_wait",guest_cond_wait); HOOK("pthread_cond_timedwait",guest_cond_timedwait);
            HOOK("pthread_cond_timedwait_relative_np",guest_cond_relativewait);
            HOOK("pthread_rwlock_rdlock",guest_rwlock_read); HOOK("pthread_rwlock_wrlock",guest_rwlock_write);
            HOOK("semaphore_wait",guest_semaphore_wait); HOOK("dispatch_semaphore_wait",guest_dispatch_wait);
        }
    }
    HOOK("sysctlbyname",guest_sysctlbyname);
    HOOK("sysctl",guest_sysctl); HOOK("sysconf",guest_sysconf);
    HOOK("pthread_jit_write_protect_np",guest_jit_protect); HOOK("__clear_cache",guest_clear_cache);
#undef HOOK
    return NULL;
}
// What this loader refuses or does not find is reported once by the guest's
// dlerror, as dyld would; like dyld, each dlopen and dlsym starts without one.
static _Thread_local char guest_dl_error[512];
static void *guest_dlsym(void *handle, const char *name) {
    guest_dl_error[0]=0;
    void *value = name ? hook(name) : NULL;
    size_t index; bool first;
    bool placed=guest_handle(handle,&index,&first);
    if (!value && placed) {
        value = placed_symbol(index,name,first);
        (void)dlerror();   // a library it links lacking the name is not the guest's error
        if (!value) snprintf(guest_dl_error,sizeof guest_dl_error,"dlsym(%p, %s): symbol not found",handle,name?name:"(null)");
    }
    else if (!value && handle==RTLD_DEFAULT) {
        // Every loaded image in load order, as dyld searches: the placed ones
        // (the executable, then what it carries) come first.
        char symbol[1024]; uint64_t address=0;
        if (name && snprintf(symbol,sizeof symbol,"_%s",name)<(int)sizeof symbol &&
            gl_lookup(&carried,&guest.image,guest.path,BIND_SPECIAL_DYLIB_FLAT_LOOKUP,symbol,&address,NULL))
            value=(void *)(uintptr_t)address;
        else value=dlsym(handle,name);
    }
    else if (!value) value = dlsym(handle,name);
    // Tracing reaches through the application's own libraries: what a placed
    // image exports is wrapped so each call logs its arguments and result.
    if (trace_guest && placed && value && inside(value,4)) value=gw_wrap(name,value);
    LOG("[native] dlsym(%s) -> %p\n",name?name:"(null)",value); return value;
}
// Placed images stay for the life of the guest.
static int guest_dlclose(void *handle) {
    size_t index; bool first;
    return guest_handle(handle,&index,&first) ? 0 : dlclose(handle);
}
static char *guest_dlerror(void) {
    static _Thread_local char reported[sizeof guest_dl_error];
    if (!guest_dl_error[0]) return dlerror();
    memcpy(reported,guest_dl_error,sizeof reported); guest_dl_error[0]=0;
    return reported;
}
// Logs leave the device: show app-container paths relative to the home
// directory, whose absolute form carries a per-install UUID.
static void home_relative(const char *text, char *out, size_t size) {
    NSString *home=NSHomeDirectory(), *value=text?[NSString stringWithUTF8String:text]:nil;
    if (value && home.length>1) {
        value=[value stringByReplacingOccurrencesOfString:[@"/private" stringByAppendingString:home] withString:@"~"];
        value=[value stringByReplacingOccurrencesOfString:home withString:@"~"];
    }
    snprintf(out,size,"%s",value?value.UTF8String:"(unavailable)");
}
static void loggable_path(const char *path, char *out, size_t size) {
    home_relative(path,out,size);
    const char *name=strrchr(path,'/');
    if (out[0]=='/') snprintf(out,size,".../%s",name?name+1:path);
}
// How the guest starts helper processes or gives up: logged, then the real
// call. iPadOS runs no helper processes, so these fail as on a Mac without
// the tool. system and popen are not declared for iOS; the macOS guest
// imports them, so they are found at run time.
static int guest_system(const char *command) {
    char shown[1024]; home_relative(command,shown,sizeof shown);
    LOG("[native] system(%s)\n",command?shown:"NULL");
    static int (*real_system)(const char *);
    if (!real_system) real_system=dlsym(RTLD_DEFAULT,"system");
    return real_system?real_system(command):-1;
}
static FILE *guest_popen(const char *command, const char *mode) {
    char shown[1024]; home_relative(command,shown,sizeof shown);
    LOG("[native] popen(%s)\n",command?shown:"NULL");
    static FILE *(*real_popen)(const char *, const char *);
    if (!real_popen) real_popen=dlsym(RTLD_DEFAULT,"popen");
    return real_popen?real_popen(command,mode):NULL;
}
static int guest_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                             const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    char shown[1024]; if (path) loggable_path(path,shown,sizeof shown);
    int result=posix_spawn(pid,path,actions,attributes,argv,envp);
    LOG("[native] posix_spawn(%s) -> %d\n",path?shown:"NULL",result);
    return result;
}
// Where a placed image called from, as its file's own (unslid) address, for
// symbolizing on the Mac; host code is named by dladdr.
static void describe_caller(const void *address, char *out, size_t size) {
    uintptr_t at=(uintptr_t)address;
    const GuestLibrary *library=gl_library_at(&carried,at);
    const char *path=library?library->path:inside(address,1)?guest.path:NULL;
    if (path) {
        const char *leaf=strrchr(path,'/');
        snprintf(out,size,"%s preferred=%#lx",leaf?leaf+1:path,(unsigned long)(at-(library?library->slide:guest.slide)));
        return;
    }
    Dl_info info={0};
    if (dladdr(address,&info) && info.dli_fname) snprintf(out,size,"%s+%#lx",info.dli_sname?:info.dli_fname,(unsigned long)(at-(uintptr_t)(info.dli_sname?info.dli_saddr:info.dli_fbase)));
    else snprintf(out,size,"%p",address);
}
void ng_set_exit_observer(NGExitObserver observer, void *context) {
    guest_exit_observer=observer; guest_exit_context=context;
}
static void notify_guest_exit(int code) {
    BOOL alreadyNotified=guest_exit_observer ? atomic_exchange(&guest_exit_notifying,true) : atomic_load(&guest_exit_notifying);
    LOG("[native] exit observer registered=%d already_notified=%d\n",guest_exit_observer!=NULL,alreadyNotified);
    if (guest_exit_observer && !alreadyNotified) guest_exit_observer(code,guest_exit_context);
}
static void guest_quick_exit(int code) {
    LOG("[native] _exit(%d) called\n",code);
    notify_guest_exit(code); _exit(code);
}
static void guest_exit(int code) {
    char caller[512]; describe_caller(__builtin_return_address(0),caller,sizeof caller);
    LOG("[native] exit(%d) called from %s\n",code,caller); notify_guest_exit(code); exit(code);
}
static void guest_abort(void) {
    char caller[512]; describe_caller(__builtin_return_address(0),caller,sizeof caller);
    LOG("[native] abort() called from %s\n",caller); abort();
}
// Each distinct line once: games probe the same missing files in loops. A
// full table stops the logging, never the guest.
static void log_once(const char *format, ...) {
    char line[1536]; va_list arguments;
    va_start(arguments,format); vsnprintf(line,sizeof line,format,arguments); va_end(arguments);
    uint64_t hash=14695981039346656037ULL;   // FNV-1a
    for (const char *c=line;*c;c++) hash=(hash^(unsigned char)*c)*1099511628211ULL;
    enum { SLOTS=1<<14, LIMIT=SLOTS*3/4 };
    static uint64_t seen[SLOTS]; static size_t used; static os_unfair_lock lock=OS_UNFAIR_LOCK_INIT;
    bool fresh=false; size_t count=0;
    if (!hash) hash=1;
    os_unfair_lock_lock(&lock);
    if (used<LIMIT) {
        size_t slot=hash&(SLOTS-1);
        while (seen[slot] && seen[slot]!=hash) slot=(slot+1)&(SLOTS-1);
        if (!seen[slot]) { seen[slot]=hash; fresh=true; count=++used; }
    }
    os_unfair_lock_unlock(&lock);
    if (fresh) LOG("%s",line);
    if (fresh && count==LIMIT) LOG("[native] %zu distinct trace lines logged; later ones are not\n",count);
}
// Trace lines carry a small per-thread number; the first tracer is the main
// thread, which starts the guest.
static unsigned trace_tid(void) {
    static _Thread_local unsigned mine;
    static atomic_uint handed_out;
    if (!mine) mine=atomic_fetch_add(&handed_out,1)+1;
    return mine;
}
// Logging must not change the errno the guest reads.
static void trace_failure(const char *call, const char *path) {
    if (!trace_guest) return;
    int code=errno;
    char shown[1024]; if (path) loggable_path(path,shown,sizeof shown);
    log_once("[native] %s(%s) failed errno=%d\n",call,path?shown:"NULL",code);
    errno=code;
}
// What the guest finds, not only what it misses: a depot built from a
// directory listing differs when a file is absent, added or truncated.
static void trace_success(const char *call, const char *path, long long size) {
    if (!trace_guest) return;
    char shown[1024]; if (path) loggable_path(path,shown,sizeof shown);
    log_once("[native] [t%u] %s(%s) ok size=%lld\n",trace_tid(),call,path?shown:"NULL",size);
}
static struct dirent *guest_readdir(DIR *directory) {
    struct dirent *entry=readdir(directory);
    if (trace_guest && entry) {
        char base[PATH_MAX];
        int fd=dirfd(directory);
        if (fd>=0 && fcntl(fd,F_GETPATH,base)==0) {
            char shown[1024]; loggable_path(base,shown,sizeof shown);
            log_once("[native] [t%u] readdir(%s) -> %s type=%d\n",trace_tid(),shown,entry->d_name,(int)entry->d_type);
        }
    }
    return entry;
}
// --case-insensitive-files: the lookup's variant to retry, if any. Never for
// creating files; Foundation's own file APIs are not covered.
static bool case_variant(const char *path, char *found, size_t size) {
    int code=errno;
    bool retry=case_insensitive_files && path && (code==ENOENT || code==ENOTDIR) && gp_case_insensitive(NULL,path,found,size);
    errno=code;
    return retry;
}
// Relative to a directory descriptor: resolved through its path.
static bool case_variant_at(int directory, const char *path, char *found, size_t size) {
    if (!path || path[0]=='/' || directory==AT_FDCWD) return case_variant(path,found,size);
    int code=errno;
    char base[PATH_MAX], joined[PATH_MAX];
    bool retry=case_insensitive_files && (code==ENOENT || code==ENOTDIR) && fcntl(directory,F_GETPATH,base)!=-1 &&
        snprintf(joined,sizeof joined,"%s/%s",base,path)<(int)sizeof joined && gp_case_insensitive(NULL,joined,found,size);
    errno=code;
    return retry;
}
// Once per directory spelled differently, with the profile entry that avoids the lookup.
static void case_found(const char *path, const char *found) {
    int code=errno;
    // Up to the last component that differs; a path made absolute is shown whole.
    size_t length=strlen(path), last=0;
    if (strlen(found)==length) {
        for (size_t i=0;i<length;i++) if (path[i]!=found[i]) last=i;
        while (last<length && path[last]!='/') last++;
    }
    char asked[PATH_MAX], actual[PATH_MAX], shown_asked[1024], shown_actual[1024];
    snprintf(asked,sizeof asked,"%.*s",(int)(last?last:length),path);
    snprintf(actual,sizeof actual,"%.*s",(int)(last?last:strlen(found)),found);
    loggable_path(asked,shown_asked,sizeof shown_asked); loggable_path(actual,shown_actual,sizeof shown_actual);
    log_once("[native] %s found as %s ignoring case (--case-insensitive-files); a caseAliases entry in the app's profile avoids the lookup\n",
        shown_asked,shown_actual);
    errno=code;
}
static int guest_open(const char *path, int flags, ...) {
    char local_path[PATH_MAX]; path=gsv_string(path,local_path,sizeof local_path);
    if(!path) return -1;
    int mode=0;
    if (flags&O_CREAT) { va_list arguments; va_start(arguments,flags); mode=va_arg(arguments,int); va_end(arguments); }
    int fd=open(path,flags,mode);
    char found[PATH_MAX];
    if (fd<0 && !(flags&O_CREAT) && case_variant(path,found,sizeof found) && (fd=open(found,flags,mode))>=0) case_found(path,found);
    if (fd<0) trace_failure("open",path);
    else if (trace_guest && !(flags&O_CREAT)) { struct stat s; trace_success("open",path,!fstat(fd,&s)?(long long)s.st_size:-1); }
    return fd;
}
static int guest_openat(int directory, const char *path, int flags, ...) {
    char local_path[PATH_MAX]; path=gsv_string(path,local_path,sizeof local_path);
    if(!path) return -1;
    int mode=0;
    if (flags&O_CREAT) { va_list arguments; va_start(arguments,flags); mode=va_arg(arguments,int); va_end(arguments); }
    int fd=openat(directory,path,flags,mode);
    char found[PATH_MAX];
    if (fd<0 && !(flags&O_CREAT) && case_variant_at(directory,path,found,sizeof found) &&
        (fd=openat(directory,found,flags,mode))>=0) case_found(path,found);
    if (fd<0) trace_failure("openat",path);
    else if (trace_guest && !(flags&O_CREAT)) { struct stat s; trace_success("openat",path,!fstat(fd,&s)?(long long)s.st_size:-1); }
    return fd;
}
static int guest_stat(const char *path, struct stat *buffer) {
    char local_path[PATH_MAX]; path=gsv_string(path,local_path,sizeof local_path);
    if(!path) return -1;
    struct stat local_stat, *output=buffer;
    if(gsv_address(buffer)) buffer=&local_stat;
    int result=stat(path,buffer);
    char found[PATH_MAX];
    if (result && case_variant(path,found,sizeof found) && !(result=stat(found,buffer))) case_found(path,found);
    if (result) trace_failure("stat",path);
    else trace_success("stat",path,(long long)buffer->st_size);
    if(!result && output!=buffer && gsv_copy(output,buffer,sizeof *buffer)!=GM_OK) { errno=EFAULT; return -1; }
    return result;
}
static int guest_fstatat(int directory, const char *path, struct stat *buffer, int flags) {
    int result=fstatat(directory,path,buffer,flags);
    char found[PATH_MAX];
    if (result && case_variant_at(directory,path,found,sizeof found) && !(result=fstatat(directory,found,buffer,flags)))
        case_found(path,found);
    if (result) trace_failure("fstatat",path);
    return result;
}
static int guest_lstat(const char *path, struct stat *buffer) {
    char local_path[PATH_MAX]; path=gsv_string(path,local_path,sizeof local_path);
    if(!path) return -1;
    struct stat local_stat, *output=buffer;
    if(gsv_address(buffer)) buffer=&local_stat;
    int result=lstat(path,buffer);
    char found[PATH_MAX];
    if (result && case_variant(path,found,sizeof found) && !(result=lstat(found,buffer))) case_found(path,found);
    if (result) trace_failure("lstat",path);
    else trace_success("lstat",path,(long long)buffer->st_size);
    if(!result && output!=buffer && gsv_copy(output,buffer,sizeof *buffer)!=GM_OK) { errno=EFAULT; return -1; }
    return result;
}
static int guest_fstat(int fd, struct stat *buffer) {
    if(!gsv_address(buffer)) return fstat(fd,buffer);
    struct stat local_stat;
    int result=fstat(fd,&local_stat);
    if(!result && gsv_copy(buffer,&local_stat,sizeof local_stat)!=GM_OK) { errno=EFAULT; return -1; }
    return result;
}
static int guest_access(const char *path, int mode) {
    char local_path[PATH_MAX]; path=gsv_string(path,local_path,sizeof local_path);
    if(!path) return -1;
    int result=access(path,mode);
    char found[PATH_MAX];
    if (result && case_variant(path,found,sizeof found) && !(result=access(found,mode))) case_found(path,found);
    if (result) trace_failure("access",path);
    else trace_success("access",path,-1);
    return result;
}
// A guest imports fopen and realpath plainly or as $DARWIN_EXTSN (the name
// iOS's headers give the plain call); each hook calls the variant imported.
extern FILE *plain_fopen(const char *, const char *) __asm("_fopen");
extern char *plain_realpath(const char *, char *) __asm("_realpath");
static FILE *traced_fopen(FILE *(*real)(const char *, const char *), const char *path, const char *mode) {
    char local_path[PATH_MAX],local_mode[32];
    path=gsv_string(path,local_path,sizeof local_path); mode=gsv_string(mode,local_mode,sizeof local_mode);
    if(!path || !mode) return NULL;
    FILE *file=real(path,mode);
    char found[PATH_MAX];
    bool creates=mode && (strchr(mode,'w') || strchr(mode,'a'));
    if (!file && !creates && case_variant(path,found,sizeof found) && (file=real(found,mode))) case_found(path,found);
    if (!file) trace_failure("fopen",path);
    else trace_success("fopen",path,-1);
    return file;
}
static FILE *guest_fopen(const char *path, const char *mode) { return traced_fopen(plain_fopen,path,mode); }
static FILE *guest_fopen_extsn(const char *path, const char *mode) { return traced_fopen(fopen,path,mode); }
static DIR *guest_opendir(const char *path) {
    char local_path[PATH_MAX]; path=gsv_string(path,local_path,sizeof local_path);
    if(!path) return NULL;
    DIR *directory=opendir(path);
    char found[PATH_MAX];
    if (!directory && case_variant(path,found,sizeof found) && (directory=opendir(found))) case_found(path,found);
    if (!directory) trace_failure("opendir",path);
    else trace_success("opendir",path,-1);
    return directory;
}
static char *traced_realpath(char *(*real)(const char *, char *), const char *path, char *resolved) {
    char local_path[PATH_MAX],local_result[PATH_MAX];
    path=gsv_string(path,local_path,sizeof local_path);
    if(!path) return NULL;
    char *output=resolved;
    if(gsv_address(resolved)) resolved=local_result;
    char *result=real(path,resolved);
    char found[PATH_MAX];
    if (!result && case_variant(path,found,sizeof found) && (result=real(found,resolved))) case_found(path,found);
    if (!result) trace_failure("realpath",path);
    if(result && output!=resolved) {
        if(gsv_copy(output,result,strlen(result)+1)!=GM_OK) { errno=EFAULT; return NULL; }
        return output;
    }
    return result;
}
static char *guest_realpath(const char *path, char *resolved) { return traced_realpath(plain_realpath,path,resolved); }
static char *guest_realpath_extsn(const char *path, char *resolved) { return traced_realpath(realpath,path,resolved); }
// Trace lines carry a small per-thread number; the first tracer is the main
// thread, which starts the guest.
static unsigned trace_tid(void);
// Sockets, under --trace-guest: who the guest tries to talk to (a Galaxy
// client's local socket, an HTTPS endpoint) says what a failed sign-in needed.
static int guest_socket(int domain, int type, int protocol) {
    int fd=socket(domain,type,protocol);
    int code=errno;
    if (trace_guest) {
        const char *family=domain==AF_UNIX?"AF_UNIX":domain==AF_INET?"AF_INET":domain==AF_INET6?"AF_INET6":"?";
        log_once("[native] [t%u] socket(%s,%d) -> %d errno=%d\n",trace_tid(),family,type,fd,fd<0?code:0);
    }
    return fd;
}
static int guest_connect(int fd, const struct sockaddr *address, socklen_t size) {
    int result=connect(fd,address,size);
    int code=errno;
    if (trace_guest && address) {
        char shown[1024]="?";
        if (address->sa_family==AF_UNIX && size>=sizeof(sa_family_t)) {
            const struct sockaddr_un *un=(const struct sockaddr_un *)address;
            loggable_path(un->sun_path,shown,sizeof shown);
        } else if (address->sa_family==AF_INET && size>=sizeof(struct sockaddr_in)) {
            const struct sockaddr_in *in=(const struct sockaddr_in *)address;
            unsigned char *o=(unsigned char *)&in->sin_addr;
            snprintf(shown,sizeof shown,"%u.%u.%u.%u:%u",o[0],o[1],o[2],o[3],ntohs(in->sin_port));
        } else snprintf(shown,sizeof shown,"(family %d)",address->sa_family);
        log_once("[native] [t%u] connect(%s) -> %d errno=%d\n",trace_tid(),shown,result,result?code:0);
    }
    return result;
}
// What a non-blocking connect is followed by: polling and the error it ends in.
static int guest_getsockopt(int fd, int level, int option, void *value, socklen_t *size) {
    int result=getsockopt(fd,level,option,value,size);
    int code=errno;
    if (trace_guest)
        log_once("[native] [t%u] getsockopt(%d,%d,%d) -> %d errno=%d value=%d\n",trace_tid(),fd,level,option,result,result?code:0,
            value&&size&&*size>=sizeof(int)?*(int *)value:-1);
    return result;
}
static int guest_setsockopt(int fd, int level, int option, const void *value, socklen_t size) {
    int result=setsockopt(fd,level,option,value,size);
    int code=errno;
    if (trace_guest)
        log_once("[native] [t%u] setsockopt(%d,%d,%d) -> %d errno=%d\n",trace_tid(),fd,level,option,result,result?code:0);
    return result;
}
static int guest_shutdown(int fd, int how) {
    int result=shutdown(fd,how);
    int code=errno;
    if (trace_guest) log_once("[native] [t%u] shutdown(%d,%d) -> %d errno=%d\n",trace_tid(),fd,how,result,result?code:0);
    return result;
}
// macOS answers machdep.cpu.brand_string; the iPadOS sandbox denies it with
// EPERM. A guest that collects hardware info then holds a null where it never
// has one on a Mac. The chip is known from the model, which is not denied.
static const char *guest_chip_name(void) {
    static char chip[64];
    if (chip[0]) return chip;
    char model[64]={0}; size_t size=sizeof model;
    (void)sysctlbyname("hw.model",model,&size,NULL,0);
    static const struct { const char *prefix; const char *name; } chips[]={
        {"iPad17,", "Apple M5"},
        {"iPad16,3", "Apple M4"}, {"iPad16,4", "Apple M4"},
        {"iPad16,5", "Apple M4"}, {"iPad16,6", "Apple M4"},
        {"iPad16,", "Apple A17 Pro"},
        {"iPhone18,", "Apple A19 Pro"}, {"iPhone17,", "Apple A18 Pro"},
    };
    const char *name=NULL;
    for (size_t i=0;i<sizeof chips/sizeof *chips;i++)
        if (!strncmp(model,chips[i].prefix,strlen(chips[i].prefix))) { name=chips[i].name; break; }
    snprintf(chip,sizeof chip,"%s",name?name:"Apple Silicon");
    return chip;
}
// What the guest learns about the machine: an answer the simulator's host
// passes through (a Mac model name) and the iPad does not have is invisible
// to every other hook.
static int guest_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int result=sysctlbyname(name,oldp,oldlenp,newp,newlen);
    int code=errno;
    if(!result && gsv_enabled() && oldlenp && !newp && !newlen &&
       ng_limit_cpu_answer(name,oldp,*oldlenp,software_cpu_limit))
        log_once("[software-vm] guest CPU topology query %s capped at %u\n",name,software_cpu_limit);
    if (result && name && !strcmp(name,"machdep.cpu.brand_string") && oldp && oldlenp && !newp) {
        const char *chip=guest_chip_name();
        size_t need=strlen(chip)+1;
        if (*oldlenp>=need) {
            memcpy(oldp,chip,need); *oldlenp=need-1;
            result=0;
            if (trace_guest) log_once("[native] [t%u] sysctlbyname(%s) denied; answering \"%s\" from the model\n",trace_tid(),name,chip);
        } else {
            size_t room=*oldlenp; *oldlenp=need-1;
            if (room) { memcpy(oldp,chip,room-1); ((char *)oldp)[room-1]=0; }
            result=0;
            if (trace_guest) log_once("[native] [t%u] sysctlbyname(%s) denied; answering a truncated \"%s\"\n",trace_tid(),name,chip);
        }
        if (!result) return 0;
        errno=code;
    }
    if (trace_guest && name) {
        char shown[280]="";
        if (!result && oldp && oldlenp) {
            size_t n=*oldlenp;
            const unsigned char *bytes=oldp;
            bool text=n && memchr(bytes,0,n)==bytes+n-1;
            for (size_t i=0;!result&&text&&i<n-1;i++) if (bytes[i]<32||bytes[i]>126) text=false;
            if (text) snprintf(shown,sizeof shown,"\"%s\"",bytes);
            else { for (size_t i=0;i<n&&i<32;i++) snprintf(shown+i*3,sizeof shown-i*3,"%02x ",bytes[i]); if (n>32) snprintf(shown+96,sizeof shown-96,"...(%zu)",n); }
        }
        log_once("[native] [t%u] sysctlbyname(%s) -> %d errno=%d %s\n",trace_tid(),name,result,result?code:0,shown);
    }
    return result;
}
static int guest_sysctl(int *name,u_int count,void *oldp,size_t *oldlenp,void *newp,size_t newlen) {
    int result=sysctl(name,count,oldp,oldlenp,newp,newlen), saved=errno;
    const char *cpu=result ? NULL : ng_cpu_mib_name(name,count);
    if(!result && gsv_enabled() && oldlenp && !newp && !newlen &&
       ng_limit_cpu_answer(cpu,oldp,*oldlenp,software_cpu_limit))
        log_once("[software-vm] guest numeric CPU topology query %s capped at %u\n",cpu,software_cpu_limit);
    if(trace_guest && cpu) {
        int value=0;
        if(!result && oldp && oldlenp && *oldlenp==sizeof value) memcpy(&value,oldp,sizeof value);
        log_once("[native] [t%u] sysctl(%s) -> %d errno=%d value=%d\n",trace_tid(),cpu,result,result?saved:0,value);
    }
    errno=saved;return result;
}
static long guest_sysconf(int name) {
    long value=sysconf(name);int saved=errno;
    if(gsv_enabled()) value=ng_limit_cpu_sysconf(name,value,software_cpu_limit);
    if(trace_guest && (name==_SC_NPROCESSORS_CONF || name==_SC_NPROCESSORS_ONLN))
        log_once("[native] [t%u] sysconf(%d) -> %ld\n",trace_tid(),name,value);
    errno=saved;return value;
}
static int guest_uname(struct utsname *u) {
    int result=uname(u);
    if (trace_guest && !result) log_once("[native] [t%u] uname() -> %s %s %s\n",trace_tid(),u->sysname,u->release,u->machine);
    return result;
}
static int guest_gethostname(char *name, size_t size) {
    int result=gethostname(name,size);
    if (trace_guest && !result) log_once("[native] [t%u] gethostname() -> %s\n",trace_tid(),name);
    return result;
}
static int guest_poll(struct pollfd *fds, nfds_t count, int timeout) {
    int result=poll(fds,count,timeout);
    int code=errno;
    if (trace_guest)
        log_once("[native] [t%u] poll(%d,%dms) -> %d errno=%d revents=%#x\n",trace_tid(),(int)count,timeout,result,result<0?code:0,
            result>0?fds[0].revents:0);
    return result;
}
static ssize_t guest_sendto(int fd, const void *bytes, size_t length, int flags, const struct sockaddr *to, socklen_t tosize) {
    ssize_t result=sendto(fd,bytes,length,flags,to,tosize);
    int code=errno;
    if (trace_guest) log_once("[native] [t%u] sendto(%d,%zu) -> %zd errno=%d\n",trace_tid(),fd,length,result,result<0?code:0);
    return result;
}
static ssize_t guest_recvfrom(int fd, void *bytes, size_t length, int flags, struct sockaddr *from, socklen_t *fromsize) {
    ssize_t result=recvfrom(fd,bytes,length,flags,from,fromsize);
    int code=errno;
    if (trace_guest) log_once("[native] [t%u] recvfrom(%d,%zu) -> %zd errno=%d\n",trace_tid(),fd,length,result,result<0?code:0);
    return result;
}
// A crash on the guest's own pages reports no registers; when tracing, log
// them before the system takes its report.
static void guest_crash_registers(int signal_number, siginfo_t *info, void *uap) {
    ucontext_t *context=uap;
    arm_thread_state64_t state=context->uc_mcontext->__ss;
    LOG("[native] guest fault signal=%d pc=%016llx address=%p\n",signal_number,
        (unsigned long long)arm_thread_state64_get_pc(state),info?info->si_addr:NULL);
    for (unsigned i=0;i+3<29;i+=4)
        LOG("[native] x%-2u=%016llx x%-2u=%016llx x%-2u=%016llx x%-2u=%016llx\n",
            i,(unsigned long long)state.__x[i],i+1,(unsigned long long)state.__x[i+1],
            i+2,(unsigned long long)state.__x[i+2],i+3,(unsigned long long)state.__x[i+3]);
    LOG("[native] x28=%016llx fp=%016llx lr=%016llx sp=%016llx\n",(unsigned long long)state.__x[28],
        (unsigned long long)arm_thread_state64_get_fp(state),(unsigned long long)arm_thread_state64_get_lr(state),
        (unsigned long long)arm_thread_state64_get_sp(state));
    signal(signal_number,SIG_DFL);
    raise(signal_number);
}
static int guest_mkdir(const char *path, mode_t mode) {
    int result=mkdir(path,mode);
    if (result) { trace_failure("mkdir",path); return result; }
    int code=errno;
    char shown[1024]; loggable_path(path,shown,sizeof shown);
    log_once("[native] mkdir(%s)\n",shown);
    errno=code;
    return result;
}
// A value is shown only inside the app's home, as ~/...; any other (a user
// name, another home folder, an identifier) only by its length.
static char *guest_getenv(const char *name) {
    int code=errno;
    char *value=getenv(name);
    char shown[1024];
    if (!value) snprintf(shown,sizeof shown,"(unset)");
    else {
        home_relative(value,shown,sizeof shown);
        if (shown[0]!='~') snprintf(shown,sizeof shown,"set, %zu bytes",strlen(value));
    }
    log_once("[native] getenv(%s) -> %s\n",name?name:"NULL",shown);
    errno=code;
    return value;
}
// dlopen the signed container (dyld validates its CodeDirectory and maps its
// pages), check its layout and bind it to this guest before anything is
// mapped, then reserve the guest arena anonymously. Pages after the rewritten
// range equal the original ones and are remapped from the container at once.
// The rewritten range is remapped only AFTER the unpacking initializer has
// re-derived its bytes on the anonymous pages (the shadow phase): an anonymous
// overwrite of validated pages is rejected by the kernel, while the reverse
// direction, validated pages over anonymous, is allowed.
static bool signed_image_prepare(uint64_t end, char *error, size_t error_size) {
    char shown[1024];
    loggable_path(signed_container_path, shown, sizeof shown);
    LOG("[signed-image] container %s\n", shown);
    void *handle = dlopen(signed_container_path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        home_relative(dlerror(), shown, sizeof shown);
        snprintf(error, error_size, "container dlopen failed: %s", shown); return false;
    }
    size_t span = (size_t)(end - guest.base);
    void *arena = MAP_FAILED;
    SIImage image = {0};
    uint64_t shadow_size = 0;
    Dl_info info = {0};
    uintptr_t v1 = (uintptr_t)dlsym(handle, "tolkara_container_v1"), final = (uintptr_t)dlsym(handle, "tolkara_container_final");
    // No mapping changes and no guest code until the container matches.
    if (v1 && !dladdr((void *)v1, &info)) { snprintf(error, error_size, "container marker lies outside any loaded image"); goto fail; }
    if (!si_locate_image(info.dli_fbase, v1, final, &image, error, error_size) ||
        !si_match_guest(&image, &guest.image, error, error_size) ||
        !si_shadow_size(&image, &guest.image, &shadow_size, error, error_size)) goto fail;
    LOG("[signed-image] container matches the guest: %llu __TEXT pages, header and load commands identical\n",
        (unsigned long long)(image.size / GM_PAGE_SIZE));
    arena = mmap(NULL, span, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (arena == MAP_FAILED) { snprintf(error, error_size, "arena reservation failed errno=%d", errno); goto fail; }
    guest.arena = (NativeCodeMemory){ .executable = arena, .writable = arena, .size = span, .published = true };
    LOG("[signed-image] dlopen ok; shadow region %llu pages, signed suffix %llu pages\n",
        (unsigned long long)(shadow_size / GM_PAGE_SIZE),
        (unsigned long long)((image.size - shadow_size) / GM_PAGE_SIZE));
    if (shadow_size < image.size) {
        vm_address_t target = (vm_address_t)arena + shadow_size;
        vm_prot_t current = VM_PROT_READ | VM_PROT_EXECUTE, maximum = current;
        kern_return_t result = vm_remap_new(mach_task_self(), &target, image.size - shadow_size, 0,
            VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)image.bytes + shadow_size, false,
            &current, &maximum, VM_INHERIT_NONE);
        LOG("[signed-image] signed suffix remap result=%d protection=%d\n", result, current);
        if (result != KERN_SUCCESS || target != (vm_address_t)arena + shadow_size ||
            !(current & VM_PROT_EXECUTE) || (current & VM_PROT_WRITE)) {
            snprintf(error, error_size, "signed suffix remap failed kr=%d", result); goto fail;
        }
    }
    signed_image = (typeof(signed_image)){ .active = true, .shadow = shadow_size != 0, .handle = handle,
        .image = image, .shadow_size = shadow_size };
    return true;
fail:
    if (arena != MAP_FAILED) munmap(arena, span);
    guest.arena = (NativeCodeMemory){0};
    dlclose(handle);
    return false;
}
// Libraries a generic build presents as unavailable: the leaves its
// Guest/absent.json names (translation/<Leaf>/absent). A build made for one
// executable says so in its map instead, with a target of "".
static NSSet *absent_leaves;
static bool leaf_absent(NSString *install_name) {
    NSString *leaf=install_name.lastPathComponent;
    return [absent_leaves containsObject:[leaf hasSuffix:@".dylib"]?[leaf stringByDeletingPathExtension]:leaf];
}
// Our adapter for an install name's leaf, if this build has one.
static NSString *adapter_path(NSString *install_name, const char *frameworks) {
    NSString *leaf=install_name.lastPathComponent;
    NSString *adapter=[@(frameworks) stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ak%@.dylib",[leaf hasSuffix:@".dylib"]?[leaf stringByDeletingPathExtension]:leaf]];
    return [NSFileManager.defaultManager fileExistsAtPath:adapter] ? adapter : nil;
}
// No map: our adapter for the leaf name, else iOS; "" for an absent one.
static NSString *library_path(NSString *install_name, const char *frameworks) {
    if (leaf_absent(install_name)) return @"";
    NSString *leaf=install_name.lastPathComponent, *adapter=adapter_path(install_name,frameworks);
    if (adapter) return adapter;
    if ([leaf hasSuffix:@".dylib"]) return [@"/usr/lib" stringByAppendingPathComponent:leaf];
    return [NSString stringWithFormat:@"/System/Library/Frameworks/%@.framework/%@",leaf,leaf];
}
// No library map: a generic build, which stubs what nothing provides.
static bool guest_generic;
// What each carried library links against outside the application.
static void *carried_hosts[GL_MAX_LIBRARIES][GI_MAX_DYLIBS];
static const char *const stub_kinds[]={"function","data","class","metaclass"};
// A map entry with an empty target: the library is absent on this platform
// (classify.py's 'absent' kind). It is never opened, and its imports never
// fall back to whatever else the process has loaded.
static char absent_marker;
#define ABSENT_LIBRARY ((void *)&absent_marker)
// Opens what an image links against, except the application's own libraries,
// which are placed, never opened. handles[i] answers the image's dylib i.
static void open_dependencies(const GuestImage *image, const char *image_path, NSDictionary *mapping,
                              const char *frameworks, void **handles) {
    for(size_t i=0;i<image->dylib_count;i++) {
        handles[i]=NULL;
        if (gl_carried(&carried,image,image_path,image->dylibs[i])) continue;
        NSString *original=@(image->dylibs[i]); NSString *target=mapping[original]?:library_path(original,frameworks);
        if (!target.length) {
            handles[i]=ABSENT_LIBRARY; LOG("[native] library %s absent on this platform; not opened\n",original.UTF8String); continue;
        }
        if ([target hasPrefix:@"@rpath/"]) target=[@(frameworks) stringByAppendingPathComponent:target.lastPathComponent];
        handles[i]=dlopen(target.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL);
        if (!handles[i]) LOG("[native] library %s unavailable: %s\n",target.UTF8String,dlerror());
    }
}
// The library map and adapter folder, for the guest's own dlopen calls; set
// once before guest code runs.
static NSDictionary *guest_mapping;
static NSString *guest_frameworks;
// What the map says a dlopen of this path opens: an adapter, an iOS library,
// "" when absent, nil when it says nothing; a framework's /Versions/<v>/ may be
// left out. A generic build has no map and uses our adapter for the leaf name
// when there is one.
static NSString *mapped_library(NSString *original) {
    if (!guest_frameworks || !original) return nil;
    if (!guest_mapping) return leaf_absent(original) ? @"" : adapter_path(original,guest_frameworks.fileSystemRepresentation);
    id target=guest_mapping[original];
    if (!target) for (NSString *key in guest_mapping)
        if ([key isKindOfClass:NSString.class] && gl_same_install_name(key.UTF8String,original.UTF8String)) { target=guest_mapping[key]; break; }
    if (![target isKindOfClass:NSString.class]) return nil;
    if ([target hasPrefix:@"@rpath/"]) return [guest_frameworks stringByAppendingPathComponent:[target lastPathComponent]];
    return target;
}
static void *refuse_dlopen(const char *shown, const char *reason) {
    (void)dlerror();   // ours is the most recent error now
    snprintf(guest_dl_error,sizeof guest_dl_error,"dlopen(%s): %s",shown,reason);
    LOG("[native] dlopen(%s) refused: %s\n",shown,reason);
    return NULL;
}
static void *guest_dlopen(const char *path, int mode) {
    guest_dl_error[0]=0;
    if (!path) return dlopen(path,mode);   // the main program: the host's answer, as before
    char shown[1024]; loggable_path(path,shown,sizeof shown);
    // The executable or a carried library, by any name dyld takes, resolved
    // from the calling image (@loader_path, its @rpath).
    const GuestLibrary *caller=gl_library_at(&carried,(uint64_t)(uintptr_t)__builtin_return_address(0));
    size_t index;
    if (gl_placed(&carried,caller?&caller->image:&guest.image,caller?caller->path:guest.path,path,&index)) {
        LOG("[native] dlopen(%s) -> placed %s\n",shown,index?carried.libraries[index-1].install_name:"executable");
        return (void *)(uintptr_t)(GUEST_HANDLE_TAG|index|((mode&RTLD_FIRST)?GUEST_HANDLE_FIRST:0));
    }
    // A mapped library never falls back to the real one beside its adapter.
    NSString *target=mapped_library(@(path));
    if (target && !target.length) return refuse_dlopen(shown,"absent on this platform");
    if (target) {
        void *handle=dlopen(target.fileSystemRepresentation,mode);
        LOG("[native] dlopen(%s) mapped to %s -> %p\n",shown,target.lastPathComponent.UTF8String,handle);
        return handle;
    }
    // Original code inside the application folder is placed by this loader or
    // not at all: never handed to the host's dyld.
    if (gl_inside(&carried,path)) return refuse_dlopen(shown,"not a library this application carries; only its placed images open");
    void *handle=dlopen(path,mode);
    LOG("[native] dlopen(%s) -> %p\n",shown,handle);
    return handle;
}
// dlsym on a placed image: its own exports, then, unless it was opened
// RTLD_FIRST, those of the libraries it links, as dyld searches a handle.
static void *placed_symbol(size_t index, const char *name, bool first) {
    const GuestImage *image=index?&carried.libraries[index-1].image:&guest.image;
    const char *path=index?carried.libraries[index-1].path:guest.path;
    void *const *host=index?carried_hosts[index-1]:guest.libraries;
    char symbol[1024]; uint64_t address=0;
    if (!name || snprintf(symbol,sizeof symbol,"_%s",name)>=(int)sizeof symbol) return NULL;
    if (gl_lookup(&carried,image,path,BIND_SPECIAL_DYLIB_SELF,symbol,&address,NULL)) return (void *)(uintptr_t)address;
    for (size_t i=0;!first && i<image->dylib_count;i++) {
        if (gl_lookup(&carried,image,path,(int)i+1,symbol,&address,NULL)) return (void *)(uintptr_t)address;
        void *value=host[i] && host[i]!=ABSENT_LIBRARY ? dlsym(host[i],name) : NULL;
        if (value) return value;
    }
    return NULL;
}
// The image being fixed up. Ordinals index its own list.
typedef struct { const GuestImage *image; const char *path; void *const *host; } GuestBinder;
static bool resolve(const char *symbol, int ordinal, bool weak, bool lazy, uint64_t *value, void *context) {
    const GuestBinder *binder = context;
    const char *name = symbol[0]=='_' ? symbol+1 : symbol;
    void *pointer = hook(name);
    // The application itself (its executable, or the carried library the ordinal
    // names) answers before the system does.
    uint64_t own_value=0;
    if (!pointer && binder && gl_lookup(&carried,binder->image,binder->path,ordinal,symbol,&own_value,NULL)) {
        *value=own_value; return true;
    }
    bool named=binder && ordinal>0 && (size_t)ordinal<=binder->image->dylib_count;
    void *host=named && binder->host ? binder->host[ordinal-1] : NULL;
    // An absent library answers nothing, not even through what else is loaded.
    bool absent=host==ABSENT_LIBRARY;
    if (!pointer && host && !absent) pointer=dlsym(host,name);
    if (!pointer && !absent) pointer=dlsym(RTLD_DEFAULT,name);
    // Nothing provides it: a stub where no build-time analysis covered it, or null when weak.
    if (!pointer && ng_may_stub(guest_generic,binder && binder->image!=&guest.image,weak)) {
        GSKind kind=gs_kind_bound(symbol,binder && binder->image->lazy_bind_size,lazy);
        pointer=gs_bind(symbol,kind);
        if (pointer) LOG("[native] stub %s as %s ordinal=%d\n",symbol,stub_kinds[kind],ordinal);
    }
    if (!pointer && !weak) LOG("[native] unresolved %s ordinal=%d\n",symbol,ordinal);
    *value=(uintptr_t)pointer; return pointer || weak;
}
// Apple's ObjC SPI explicitly supports images created outside dyld.
static bool register_objc_image(const char *name, const struct mach_header *header) {
    static void (*map_images)(unsigned,const char *const *,const struct mach_header *const *);
    static void (*load_image)(const char *,const struct mach_header *);
    if (!map_images) map_images=dlsym(RTLD_DEFAULT,"_objc_map_images");
    if (!load_image) load_image=dlsym(RTLD_DEFAULT,"_objc_load_image");
    if (!map_images || !load_image) { LOG("[native] ObjC image registration unavailable\n"); return false; }
    const char *names[]={name};
    map_images(1,names,&header);
    load_image(name,header);
    return true;
}
// A carried library's own initializers, already relocated.
static bool run_initializers(const GuestImage *image, uint64_t slide, const char *name,
                             int argc, const char **argv, const char **env, const char **apple) {
    for (uint64_t i=0;i<image->initializer_count;i++) {
        uintptr_t function=(uintptr_t)gi_placed_initializer(image,slide,i);
        if (!inside((void *)function,4) || (function&3)) {
            LOG("[native] %s: initializer %llu is not in the arena (%p)\n",name,(unsigned long long)i,(void *)function);
            return false;
        }
        LOG("[native] %s: initializer %llu native=%p\n",name,(unsigned long long)i,(void *)function);
        ((void (*)(int,const char **,const char **,const char **))function)(argc,argv,env,apple);
    }
    return true;
}
bool ng_initialize(const char *path, const char *frameworks, const char *library_map, FILE *log, bool full_startup) {
    // Failure can leave installed Objective-C hooks and an uncertain helper.
    // Do not reinstall hooks recursively or attempt another attachment in this
    // process, even if failure happened before the arena became writable.
    if (atomic_exchange(&initialization_attempted,true)) {
        fprintf(log,"[native] startup was already attempted; restart the app\n"); return false;
    }
    guest.log=log; guest.path=strdup(path);
    gs_log(log); gw_log(log);
    startup_begin("loading the app's executable",0);
    NSMutableArray *process_arguments=[NSMutableArray arrayWithObject:@(path)];
    for (size_t i=0;i<launch_argument_count;i++) [process_arguments addObject:@(launch_arguments[i])];
    guest_arguments=process_arguments;
    Method arguments_method=class_getInstanceMethod(NSProcessInfo.class,@selector(arguments));
    original_arguments=(void *)method_setImplementation(arguments_method,(IMP)guest_process_arguments);
    previous_exception_preprocessor=objc_setExceptionPreprocessor(log_exception);
    if (full_startup) {
        NSString *bundle_path=[[[@(path) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        if ([bundle_path.pathExtension isEqual:@"app"]) {
            guest_bundle=[NSBundle bundleWithPath:bundle_path];
            guest_cf_bundle=CFBundleCreate(kCFAllocatorDefault,(__bridge CFURLRef)[NSURL fileURLWithPath:bundle_path isDirectory:YES]);
            LOG("[native] guest bundle path=%s identifier=%s CFBundle=%s\n",bundle_path.UTF8String,guest_bundle.bundleIdentifier.UTF8String,guest_cf_bundle?"present":"missing");
            if (guest_bundle) {
                Method method=class_getClassMethod(NSBundle.class,@selector(mainBundle));
                original_main_bundle=(void *)method_setImplementation(method,(IMP)guest_main_bundle);
            }
        }
    }
    char error[2048]; bool ok=false; GFStats stats;
    if (!gi_load(path,&guest.image,error,sizeof error)) { LOG("[native] load failed: %s\n",error); goto done; }
    // Carried libraries load as data too, placed beside the executable.
    if (!gl_load(&carried,&guest.image,path,error,sizeof error))
        LOG("[native] carried libraries unavailable: %s\n",error);
    // A runtime's libraries, opened by path later, are placed now as well.
    else if ((launch_root || launch_library_count) &&
             !gl_carry(&carried,launch_root,(const char *const *)launch_libraries,launch_library_count,error,sizeof error)) {
        LOG("[native] the profile's libraries cannot be placed: %s\n",error); goto done;
    }
    // The executable answers for its own exports whatever was carried.
    carried.executable_image=&guest.image;
    gl_report(&carried,log);
    guest.base=guest.image.header_address;
    uint64_t end=guest.base;
    for(size_t i=0;i<guest.image.segment_count;i++) {
        GISegment *s=&guest.image.segments[i]; if(s->prot && s->address+s->size>end) end=s->address+s->size;
    }
    // One region for everything: a debugger prepares it once.
    uint64_t library_offset[GL_MAX_LIBRARIES], library_low[GL_MAX_LIBRARIES];
    size_t total=(size_t)(end-guest.base);
    for (size_t i=0;i<carried.count;i++) {
        library_offset[i]=total;
        total+=(size_t)gi_extent(&carried.libraries[i].image,&library_low[i]);
    }
    // A runtime's own code pool after the images (ng_set_code_pool).
    size_t page_size=(size_t)getpagesize(), pool_offset=total, pool_size=0;
    if (code_pool_size) {
        pool_size=(code_pool_size+page_size-1)/page_size*page_size;
        total+=pool_size;
        LOG("[native] code pool of %zu bytes after the images\n",pool_size);
    }
    // --jit-probe: one spare page after everything, for the arena stage.
    bool jit_probe=[NSProcessInfo.processInfo.arguments containsObject:@"--jit-probe"];
    size_t probe_offset=total;
    if (jit_probe) total+=(size_t)getpagesize();
    bool arena_ready;
    bool signed_backend=atomic_load(&use_signed_image);
    // The signed container is captured from one executable's own pages.
    // Nothing but the signed pages executes there: no code pool.
    if (signed_backend && pool_size) {
        LOG("[native] Local signing cannot provide a code pool, which this runtime needs; guest entry blocked\n");
        goto done;
    }
    if (signed_backend && carried.count) {
        LOG("[native] Local signing places only the application's own image; this one carries %zu librar%s of its own; guest entry blocked\n",
            carried.count,carried.count==1?"y":"ies");
        goto done;
    }
    bool local=false;
#if TOLKARA_INTEGRATED_AUTH
    local=!signed_backend && (atomic_load(&use_local_authorization) ||
        [NSProcessInfo.processInfo.arguments containsObject:@"--local-native-authorization"]);
#endif
    bool external=false;
#if !TOLKARA_INTEGRATED_AUTH
    // External JIT exists only in TolkaraDiagnostics, like its mode.
    external=!signed_backend && !local && (atomic_load(&use_external_authorization) ||
        [NSProcessInfo.processInfo.arguments containsObject:@"--external-authorization"]);
#endif
    if (!signed_backend) {
        // Only what certainly cannot fit is refused; the rest is the device's answer.
        size_t limit=nc_launch_limit(), available=nc_available_memory();
        LOG("[native] this image needs %zu bytes of executable memory; the limit is %zu (%zu bytes left to this process%s)\n",
            total,limit,available,available?"":", unknown here");
        if (total>limit) { LOG("[native] not enough room for this arena; guest entry blocked\n"); goto done; }
    }
    // An arena an enabler provided earlier: taken, refused, or given back first.
    NGReservedChoice reserved=ng_reserved_choice(external,reserved_arena.published,total,reserved_arena.size);
    if (reserved==NG_RESERVED_REFUSE) {
        LOG("[native] the enabler provided %zu bytes and this image needs %zu; nothing is attached to ask again; guest entry blocked\n",
            reserved_arena.size,total);
        nc_destroy(&reserved_arena); goto done;
    }
    if (reserved==NG_RESERVED_GIVE_BACK) {
        LOG("[native] the arena reserved earlier (%zu bytes) is not used; given back\n",reserved_arena.size);
        nc_destroy(&reserved_arena);
    }
    bool take_reserved=reserved==NG_RESERVED_TAKE;
    startup_begin(signed_backend?"mapping the signed page container":"preparing execution memory",0);
    if (signed_backend)
        arena_ready=signed_image_prepare(guest.base+total,error,sizeof error);
#if TOLKARA_INTEGRATED_AUTH
    else if(local)
        arena_ready=nc_create_managed(&guest.arena,total,TKPrepareLocalArena,NULL,&local_quarantine);
#endif
    else if(take_reserved) {
        guest.arena=reserved_arena; reserved_arena=(NativeCodeMemory){0}; arena_ready=true;
        LOG("[native] using the arena reserved earlier: %zu bytes\n",guest.arena.size);
    }
    else if(external) {
        // An enabler first; otherwise an arena of our own.
        arena_ready=da_request_arena(&guest.arena,total,guest.log);
        if(!arena_ready) arena_ready=nc_create_managed(&guest.arena,total,prepare_externally,NULL,&external_quarantine);
    }
    else
        arena_ready=nc_create(&guest.arena,total,publish,NULL);
    if (!arena_ready) { LOG("[native] arena preparation failed errno=%d %s; guest entry blocked\n",errno,signed_backend?error:""); goto done; }
    // A protection change can be reported and not granted.
    LOG("[native] arena protection %#x\n",hd_protection(guest.arena.executable));
    // Whichever route prepared it: nothing attached, really executable.
    if (external && !da_entry_allowed(&guest.arena,guest.log)) { LOG("[native] guest entry blocked\n"); goto done; }
    guest.slide=(uintptr_t)guest.arena.executable-guest.base;
    carried.executable_slide=guest.slide;
    for (size_t i=0;i<carried.count;i++)
        carried.libraries[i].slide=(uintptr_t)guest.arena.executable+library_offset[i]-library_low[i];
    LOG("[native] arena ready base=%p slide=%#llx\n",guest.arena.executable,(unsigned long long)guest.slide);
    if (pool_size)
        expand_code_pool((char *)guest.arena.executable+pool_offset,(char *)guest.arena.writable+pool_offset,pool_size);
    if (jit_probe) {
        // Diagnostic (docs/WINDOWS.md): now that the helper has prepared the
        // arena and detached, may this process execute memory it maps itself?
        // A runtime that generates code (an x86 emulator) needs that. Only our
        // own two-instruction sample runs; a kernel rejection may end the
        // process, so each stage is flushed first. Guest entry is skipped.
        // The arena first: memory the helper prepared, as a code pool would use it.
        size_t page=(size_t)getpagesize();
        HPArenaResult arena=arena_execution_probe((char *)guest.arena.executable+probe_offset,
                                                  (char *)guest.arena.writable+probe_offset,page,log);
        LOG("[jit-probe] arena: alias=%s rewrite=%s direct=%s after-direct=%s direct_errno=%d rwx_errno=%d\n",
            arena.alias_execute?"PASS":"FAIL",arena.alias_rewrite?"PASS":"FAIL",arena.direct_rewrite?"PASS":"FAIL",
            arena.alias_after_direct?"PASS":"FAIL",arena.direct_errno,arena.rwx_errno);
        HPResult wx=host_execution_probe(HP_WRITE_THEN_EXECUTE,log);
        LOG("[jit-probe] write-then-execute: execute=%s rewrite=%s allocation_errno=%d protection_errno=%d\n",
            wx.executable?"PASS":"FAIL",wx.rewrite_executable?"PASS":"FAIL",wx.allocation_errno,wx.protection_errno);
        HPResult rwx=host_execution_probe(HP_READ_WRITE_EXECUTE,log);
        LOG("[jit-probe] read-write-execute: execute=%s rewrite=%s allocation_errno=%d protection_errno=%d\n",
            rwx.executable?"PASS":"FAIL",rwx.rewrite_executable?"PASS":"FAIL",rwx.allocation_errno,rwx.protection_errno);
        LOG("[jit-probe] done; guest entry skipped\n");
        goto done;
    }
    startup_begin("linking the app with system libraries",0);
    {
        NSData *data=[NSData dataWithContentsOfFile:@(library_map)];
        NSDictionary *mapping=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
        // A map comes with a build made for one executable.
        if (![mapping isKindOfClass:NSDictionary.class]) {
            LOG("[native] no library map; libraries are resolved by name and missing imports stubbed\n"); mapping=nil;
        }
        guest_generic=!mapping;
        guest_mapping=mapping; guest_frameworks=@(frameworks);
        // A generic build lists the libraries it presents as absent.
        if (!mapping) {
            NSString *list=[[@(library_map) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"absent.json"];
            NSData *absent=[NSData dataWithContentsOfFile:list];
            NSArray *leaves=absent?[NSJSONSerialization JSONObjectWithData:absent options:0 error:NULL]:nil;
            if ([leaves isKindOfClass:NSArray.class]) absent_leaves=[NSSet setWithArray:leaves];
        }
        NSString *support=[@(frameworks) stringByAppendingPathComponent:@"libAKSupport.dylib"];
        if (!dlopen(support.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL)) { LOG("[native] support load failed: %s\n",dlerror()); goto done; }
        open_dependencies(&guest.image,guest.path,mapping,frameworks,guest.libraries);
        // A carried library's own dependencies, which the executable may not link.
        for (size_t i=0;i<carried.count;i++)
            open_dependencies(&carried.libraries[i].image,carried.libraries[i].path,mapping,frameworks,carried_hosts[i]);
    }
    {
        void (*set_nibs)(const char *)=dlsym(RTLD_DEFAULT,"AKSetGuestNibDirectory");
        if(set_nibs) set_nibs([NSHomeDirectory() stringByAppendingPathComponent:@"Documents/GuestCompatibility/Nibs"].fileSystemRepresentation);
    }
    trace_guest=[NSProcessInfo.processInfo.arguments containsObject:@"--trace-guest"];
    if (trace_guest) LOG("[native] tracing failed file access, created directories, getenv, sockets and the calls dlsym hands out (--trace-guest)\n");
    if (trace_guest) {
        struct sigaction crash_registers={0};
        crash_registers.sa_sigaction=guest_crash_registers;
        crash_registers.sa_flags=SA_SIGINFO|SA_RESETHAND;
        sigaction(SIGSEGV,&crash_registers,NULL);
        sigaction(SIGBUS,&crash_registers,NULL);
    }
    case_insensitive_files=[NSProcessInfo.processInfo.arguments containsObject:@"--case-insensitive-files"];
    if (case_insensitive_files) LOG("[native] file lookups retried ignoring case (--case-insensitive-files; experimental)\n");
    bool software_requested=[NSProcessInfo.processInfo.arguments containsObject:@"--cyberpunk-software-vm"];
    if (software_requested) {
        if (![NSProcessInfo.processInfo.arguments containsObject:@"--app=cyberpunk-2077"] ||
            ![@(guest.path) hasSuffix:@"Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"] || signed_image.active) {
            LOG("[software-vm] refused: this opt-in is restricted to the Cyberpunk native profile\n"); goto done;
        }
        const char *backing=getenv("TOLKARA_SOFTWARE_VM_MB"), *force=getenv("TOLKARA_SOFTWARE_VM_FORCE_MB");
        char *rest=NULL; unsigned long long megabytes=4096, forced=0;
        if(backing && *backing) {
            megabytes=strtoull(backing,&rest,10);
            if(*rest || megabytes<64 || megabytes>8192) { LOG("[software-vm] backing must be 64..8192 whole MiB\n"); goto done; }
        }
        if(force && *force) {
            forced=strtoull(force,&rest,10);
            if(*rest || forced>(1ULL<<20)) { LOG("[software-vm] invalid forced reservation threshold\n"); goto done; }
        }
        const char *block_option=getenv("TOLKARA_SOFTWARE_VM_SMALL_BLOCKS");
        bool small_blocks=block_option && !strcmp(block_option,"1");
        bool started=small_blocks ? gsv_start_blocks((size_t)megabytes<<20,(size_t)forced<<20,fileno(guest.log)) :
                                    gsv_start((size_t)megabytes<<20,(size_t)forced<<20,fileno(guest.log));
        LOG("[software-vm] backing layout=%s\n",small_blocks?"small allocator blocks":"contiguous mmap");
        if(!started) {
            LOG("[software-vm] initialization failed\n"); goto done;
        }
        const char *native_pool=getenv("TOLKARA_SOFTWARE_VM_NATIVE_POOL_MB");
        if(native_pool && *native_pool) {
            unsigned long long native_mb=strtoull(native_pool,&rest,10);
            if(*rest || native_mb<64 || native_mb>(1ULL<<20)) {
                LOG("[software-vm] invalid preferred native pool size\n"); goto done;
            }
            gsv_prefer_native_pool((size_t)native_mb<<20);
            LOG("[software-vm] prefer native pool=%llu MiB; other large reservations use software\n",native_mb);
        }
        const char *forced_pool=getenv("TOLKARA_SOFTWARE_VM_FORCE_POOL_MB");
        if(forced_pool && *forced_pool) {
            unsigned long long forced_mb=strtoull(forced_pool,&rest,10);
            if(*rest || forced_mb<64 || forced_mb>(1ULL<<20)) {
                LOG("[software-vm] invalid forced software pool size\n"); goto done;
            }
            gsv_force_pool((size_t)forced_mb<<20);
            LOG("[software-vm] force exact pool=%llu MiB to software\n",forced_mb);
        }
        LOG("[software-vm] Cyberpunk-only runtime emulation enabled, backing=%llu MiB; native mappings attempted first\n",megabytes);
        const char *cpus=getenv("TOLKARA_SOFTWARE_VM_CPUS");
        if(cpus && *cpus) {
            unsigned long long limit=strtoull(cpus,&rest,10);
            if(*rest || !limit || limit>64) { LOG("[software-vm] CPU limit must be 1..64\n"); goto done; }
            software_cpu_limit=(unsigned)limit;
            LOG("[software-vm] experimental guest CPU topology limit=%u\n",software_cpu_limit);
        }
        if(trace_guest) schedule_memory_progress(1,0);
    }
    const char *budget_mb=getenv("TOLKARA_VM_BUDGET_MB");
    if (!software_requested && budget_mb && *budget_mb) {
        char *rest=NULL; unsigned long long megabytes=strtoull(budget_mb,&rest,10);
        if (*rest || !megabytes || megabytes>(1ULL<<24)) LOG("[native] TOLKARA_VM_BUDGET_MB ignored: whole megabytes, 1 to 16777216\n");
        else {
            // Reservations of 64 MB and more count; a downsized one is asked for 256 MB first.
            gv_init(&vm_budget,megabytes<<20,64u<<20,256u<<20);
            LOG("[native] virtual-memory budget of %llu MB for large reservations (TOLKARA_VM_BUDGET_MB; experimental)\n",megabytes);
        }
    }
    if([NSProcessInfo.processInfo.arguments containsObject:@"--sample-native"]) signal_log_fd=open([[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/native-signal.log"] fileSystemRepresentation],O_WRONLY|O_CREAT|O_TRUNC,0600);
    shader_wait_pending=dlsym(RTLD_DEFAULT,"AKShaderWaitPending");
    for (size_t i=0;i<carried.count;i++) {
        GuestLibrary *library=&carried.libraries[i];
        GFStats library_stats;
        GuestBinder binder={.image=&library->image,.path=library->path,.host=carried_hosts[i]};
        if (!gf_apply(&library->image,library->slide,resolve,&binder,&library_stats,error,sizeof error)) {
            LOG("[native] %s fixups failed: %s\n",library->install_name,error); goto done;
        }
        LOG("[native] %s rebases=%zu binds=%zu\n",library->install_name,library_stats.rebases,library_stats.binds);
    }
    GuestBinder binder={.image=&guest.image,.path=guest.path,.host=guest.libraries};
    if (!gf_apply(&guest.image,guest.slide,resolve,&binder,&stats,error,sizeof error)) { LOG("[native] fixups failed: %s\n",error); goto done; }
    LOG("[native] resolved rebases=%zu binds=%zu\n",stats.rebases,stats.binds);
    LOG("[native] stubs=%u of %u\n",gs_used(),gs_capacity());
    if (!setup_tls(&guest.image,guest.slide,"the application")) goto done;
    // Carried libraries get the treatment dyld gives them.
    for (size_t i=0;i<carried.count;i++)
        if (!setup_tls(&carried.libraries[i].image,carried.libraries[i].slide,carried.libraries[i].install_name)) goto done;
    size_t signed_pages_skipped=0;
    for(size_t i=0;i<guest.image.memory.count;i++) {
        GMPage *page=&guest.image.memory.pages[i];
        if(!page->bytes) continue;
        size_t offset=(size_t)(page->address-guest.base);
        if (signed_image.active) {
            // __TEXT pages after the rewritten range are already backed by the
            // signed container: never overwrite validated pages. Only the
            // rewritten range (original packed bytes) is staged onto anonymous
            // pages, with the bounds check nc_write applies in the other backend.
            if (offset>=signed_image.shadow_size && offset<signed_image.image.size) { signed_pages_skipped++; continue; }
            if (offset>guest.arena.size || GM_PAGE_SIZE>guest.arena.size-offset) {
                LOG("[signed-image] staged page %#llx lies outside the arena\n",(unsigned long long)page->address); goto done;
            }
            memcpy((char *)guest.arena.executable+offset,page->bytes,GM_PAGE_SIZE);
        }
        else if(!nc_write(&guest.arena,offset,page->bytes,GM_PAGE_SIZE)) goto done;
    }
    if (signed_image.active) LOG("[signed-image] %zu staged executable pages left to the signed container\n",signed_pages_skipped);
    for(size_t i=0;i<guest.image.segment_count;i++) {
        GISegment *s=&guest.image.segments[i]; if(!s->prot) continue;
        if (signed_image.active && (s->prot & GM_EXEC)) continue;  // remap already established RX
        if (mprotect((void *)(s->address+guest.slide),s->size,s->prot & ((s->prot&GM_EXEC)?~GM_WRITE:~0u))) {
            LOG("[native] segment protection failed: %s errno=%d\n",s->name,errno); goto done;
        }
    }
    // Carried libraries are never part of a signed container: plain pages.
    for (size_t i=0;i<carried.count;i++) {
        GuestLibrary *library=&carried.libraries[i];
        uint64_t base=library_low[i];
        for (size_t j=0;j<library->image.memory.count;j++) {
            GMPage *page=&library->image.memory.pages[j];
            if (page->bytes && !nc_write(&guest.arena,(size_t)(page->address-base+library_offset[i]),page->bytes,GM_PAGE_SIZE)) {
                LOG("[native] %s: cannot place page %#llx\n",library->install_name,(unsigned long long)page->address); goto done;
            }
        }
        for (size_t j=0;j<library->image.segment_count;j++) {
            GISegment *s=&library->image.segments[j]; if(!s->prot) continue;
            if (mprotect((void *)(s->address+library->slide),s->size,s->prot & ((s->prot&GM_EXEC)?~GM_WRITE:~0u))) {
                LOG("[native] %s: segment protection failed: %s errno=%d\n",library->install_name,s->name,errno); goto done;
            }
        }
        gm_destroy(&library->image.memory);
    }
    if (!ng_unwind_add(&guest.image, guest.slide)) {
        LOG("[native] cannot register executable unwind metadata\n"); goto done;
    }
    for (size_t i = 0; i < carried.count; ++i) {
        GuestLibrary *library = &carried.libraries[i];
        if (!ng_unwind_add(&library->image, library->slide)) {
            LOG("[native] cannot register library unwind metadata: %s\n", library->install_name); goto done;
        }
    }
    LOG("[native] unwind metadata registered for executable and %zu libraries\n", carried.count);
    if(gsv_enabled() && !gsv_code_alias(guest.arena.executable,guest.arena.writable,guest.arena.size)) {
        LOG("[software-vm] cannot register the loader-owned instruction view\n"); goto done;
    }
    {
        // The unpacking initializer runs in both backends. With Local signing
        // its code-writing operations verify the signed pages byte-for-byte
        // instead of writing through an RW alias. Read like the rest of the
        // initializers, after fixups: a chained record is no address.
        uintptr_t initializer=guest.image.initializer_count?(uintptr_t)gi_placed_initializer(&guest.image,guest.slide,0):0;
        gm_destroy(&guest.image.memory);
        if (guest.image.initializer_count && (!inside((void *)initializer,4) || (initializer&3))) {
            LOG("[native] invalid initializer 0=%p\n",(void *)initializer); goto done;
        }
        if (guest.image.initializer_count)
            LOG("[native] entering original initializer preferred=%#llx native=%p\n",(unsigned long long)(initializer-guest.slide),(void *)initializer);
        else LOG("[native] the application records no initializers\n");
        char *executable_argument=NULL;
        asprintf(&executable_argument,"executable_path=%s",guest.path);
        // argv outlives this call: the program may keep pointers into it. The
        // carried libraries' initializers, the client's and main all see it.
        const char **argv=calloc(launch_argument_count+2,sizeof *argv);
        argv[0]=guest.path;
        for (size_t i=0;i<launch_argument_count;i++) argv[i+1]=launch_arguments[i];
        const char *env[]={NULL}, *apple[]={executable_argument,NULL};
        int argc=(int)launch_argument_count+1;
        if (launch_argument_count) LOG("[native] %zu launch arguments after the executable path\n",launch_argument_count);
        // dyld order: a library's initializers before the client's, and
        // before those of the carried libraries that link it.
        size_t order[GL_MAX_LIBRARIES], ordered=gl_initialization_order(&carried,order);
        if (full_startup && ordered) startup_begin("starting the libraries the app carries",ordered);
        for (size_t n=0;full_startup && n<ordered;n++) {
            GuestLibrary *library=&carried.libraries[order[n]];
            LOG("[native] registering %s\n",library->install_name);
            if (!register_objc_image(library->path,(const struct mach_header *)(library->image.header_address+library->slide)) ||
                !run_initializers(&library->image,library->slide,library->install_name,argc,argv,env,apple)) { ok=false; goto done; }
            startup_count(n+1);
        }
        // Nothing to call where the image records no initializer.
        startup_begin("running the app's startup code",full_startup?guest.image.initializer_count:1);
        if (guest.image.initializer_count) {
            ((void (*)(int,const char **,const char **,const char **))initializer)(argc,argv,env,apple);
            LOG("[native] first original initializer returned\n");
            startup_count(1);
        }
        ok=true;
        if (signed_image.active && !signed_image.shadow)
            LOG("[signed-image] no rewritten range: every __TEXT page was signed before the initializer; no unpack verification or restore needed\n");
        if (signed_image.shadow) {
            startup_begin("checking the unpacked code against the page container",0);
            // Determinism evidence: the regenerated range must equal the signed
            // container before its pages replace it. Any difference means the
            // container came from another capture: stop before running more code.
            size_t first=0, mismatched=si_count_mismatches(guest.arena.executable,signed_image.image.bytes,signed_image.shadow_size,&first);
            if (mismatched) {
                const unsigned char *regenerated=guest.arena.executable, *baked=signed_image.image.bytes;
                LOG("[signed-image] FATAL: unpack verification: %zu differing bytes of %zu; first at preferred=%#llx regenerated=%02x baked=%02x\n",
                    mismatched,(size_t)signed_image.shadow_size,(unsigned long long)(guest.base+first),regenerated[first],baked[first]);
                LOG("[signed-image] FATAL: the container was built from a different capture of this executable; rebuild it. Guest entry blocked.\n");
                ok=false; goto done;
            }
            LOG("[signed-image] unpack verification: regenerated shadow image identical to the signed container (%zu bytes)\n",
                (size_t)signed_image.shadow_size);
            signed_image.shadow=false;
            // Restore the kernel-validated signed pages for execution.
            vm_address_t target=(vm_address_t)guest.arena.executable;
            vm_prot_t current=VM_PROT_READ|VM_PROT_EXECUTE,maximum=current;
            kern_return_t result=vm_remap_new(mach_task_self(),&target,signed_image.shadow_size,0,
                VM_FLAGS_FIXED|VM_FLAGS_OVERWRITE,mach_task_self(),(vm_address_t)signed_image.image.bytes,false,&current,&maximum,VM_INHERIT_NONE);
            LOG("[signed-image] signed pages restored result=%d protection=%d\n",result,current);
            if (result!=KERN_SUCCESS || target!=(vm_address_t)guest.arena.executable ||
                !(current&VM_PROT_EXECUTE) || (current&VM_PROT_WRITE)) { LOG("[signed-image] restore failed\n"); ok=false; goto done; }
        }
        if (full_startup) {
            // Apple's ObjC SPI explicitly supports images created outside dyld.
            // Invoke after the client's unpacking initializer restores its code.
            LOG("[native] registering original ObjC image\n");
            if (!register_objc_image(path,(const struct mach_header *)guest.arena.executable)) { ok=false; goto done; }
            LOG("[native] ObjC image registration returned\n");
            for(uint64_t i=1;i<guest.image.initializer_count;i++) {
                uintptr_t function=(uintptr_t)gi_placed_initializer(&guest.image,guest.slide,i);
                if (!inside((void *)function,4) || (function&3)) { LOG("[native] invalid initializer %llu=%p\n",(unsigned long long)i,(void *)function); ok=false; goto done; }
                LOG("[native] initializer %llu preferred=%#llx native=%p\n",(unsigned long long)i,(unsigned long long)(function-guest.slide),(void *)function);
                ((void (*)(int,const char **,const char **,const char **))function)(argc,argv,env,apple);
                startup_count(i+1);
            }
            LOG("[native] all %llu initializers returned; entering original main=%p\n",(unsigned long long)guest.image.initializer_count,(void *)(guest.image.entry+guest.slide));
            if([NSProcessInfo.processInfo.arguments containsObject:@"--sample-native"]) schedule_native_sample(mach_thread_self(),1);
            startup_begin("the app is running its own startup",0);
            int result=((int (*)(int,const char **,const char **,const char **))(guest.image.entry+guest.slide))(argc,argv,env,apple);
            LOG("[native] original main returned %d\n",result);
            ok=(result==0);
        }
    }
done:
    LOG("[native] result %s=%s\n",full_startup?"startup_return":"first_initializer",ok?"PASS":"FAIL");
    // Retain live mappings and library handles: initializer-created pointers and
    // worker threads may outlive this call. Only one guest per app process.
    host_debugger_guest_complete(ok);
    return ok;
}
