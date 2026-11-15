#import "Diagnostics.h"
#import "CapturedShaderProbe.h"
#import "CPUProbe.h"
#import "GuestImage.h"
#import "HostDiagnostics.h"
#import "LocalShaderProbe.h"
#import "MemoryProbe.h"
#import "ShaderPauseProbe.h"
#import "SignedCodeProbe.h"
#import "SparseMemoryProbe.h"
#import <UIKit/UIKit.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

NSString *TKDocumentsPath(NSString *name) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name];
}

void TKKeepEarlierLogs(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *current = TKDocumentsPath(@"native-guest.log");
    if (![files fileExistsAtPath:current]) return;
    for (int index = 3; index >= 1; index--) {
        NSString *to = TKDocumentsPath([NSString stringWithFormat:@"native-guest.%d.log", index]);
        NSString *from = index == 1 ? current : TKDocumentsPath([NSString stringWithFormat:@"native-guest.%d.log", index - 1]);
        [files removeItemAtPath:to error:NULL];
        [files moveItemAtPath:from toPath:to error:NULL];
    }
}

NSString *TKHostDiagnosticsReport(void) {
    HostDiagnostics report;
    hd_collect(&report,false,NULL);
    char text[4096];
    hd_format(&report,text,sizeof text);
    NSString *result=[NSString stringWithUTF8String:text];
    [result writeToFile:TKDocumentsPath(@"host-diagnostics.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return result;
}

NSString *TKLoaderCheck(NSString *executable, NSString *missing) {
    // Read/allocate away from the UI thread. Never cast a guest VA to a host pointer.
    char error[2048];
    NSString *message;
    if (!guest_memory_probe(error, sizeof error)) {
        message = [NSString stringWithFormat:@"Memory emulation check failed:\n%s", error];
    } else {
        fprintf(stderr, "[softmmu] PASS: MAP_JIT, write protection, fetch, mprotect, fixed remap, munmap\n");
        GuestImage image = {0};
        if (!executable) {
            message=[NSString stringWithFormat:@"Standalone runtime development\n\n%@\n\nThe signed app contains no game executable. Standalone game execution is not integrated yet.",missing?:@"No app selected."];
        } else if (!gi_load(executable.fileSystemRepresentation, &image, error, sizeof error)) {
            message = [NSString stringWithFormat:@"Original guest load failed:\n%s", error];
        } else {
            gi_report(&image, stderr);
            message = [NSString stringWithFormat:
                @"Separate application module verified\nOriginal executable loaded unchanged\n\nGuest memory: %.1f MiB\nInitializers: %llu\nFirst initializer: 0x%llx\n\nMemory emulation checks passed.\n\nStandalone execution is not integrated yet.",
                image.mapped_size / 1048576.0,
                (unsigned long long)image.initializer_count,
                (unsigned long long)image.first_initializer];
            gi_destroy(&image);
        }
    }
    fprintf(stderr, "[host] %s\n", message.UTF8String);
    return message;
}

NSString *TKCPUProbeReport(void) {
    NSString *path=TKDocumentsPath(@"cpu-probe.log");
    FILE *log=fopen(path.fileSystemRepresentation,"w");
    BOOL ok=log && guest_cpu_probe(log,2000000);
    if (log) fclose(log);
    NSString *report=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    fprintf(stderr,"%s",report.UTF8String?:"CPU probe log unavailable.");
    return [NSString stringWithFormat:@"CPU interpreter probe %@\n\n%@",ok?@"passed":@"failed",report?:@""];
}

NSString *TKSparseMemoryProbeReport(void) {
    NSString *path=TKDocumentsPath(@"sparse-memory-probe.log");
    FILE *log=fopen(path.fileSystemRepresentation,"w");
    BOOL ok=log && guest_sparse_memory_probe(log);
    if (log) fclose(log);
    NSString *details=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    return [NSString stringWithFormat:@"Software address-space fixture %@\n\n%@",
        ok?@"passed":@"failed",details?:@"Log unavailable."];
}

NSString *TKLocalShaderProbeReport(void) {
    NSString *report=TKRunLocalShaderProbe(TKDocumentsPath(@"LocalShaderProbe"));
    [report writeToFile:TKDocumentsPath(@"local-shader-probe.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return report;
}

NSString *TKCapturedShaderProbeReport(void) {
    NSString *runID=nil;
    for(NSString *argument in NSProcessInfo.processInfo.arguments)
        if([argument hasPrefix:@"--probe-run-id="])runID=[argument substringFromIndex:@"--probe-run-id=".length];
    NSString *report=TKRunCapturedShaderProbe(TKDocumentsPath(@"ShaderRequests"),TKDocumentsPath(@"TranslatedShaders"),runID);
    [report writeToFile:TKDocumentsPath(@"captured-shader-probe.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    fprintf(stderr,"%s",report.UTF8String);
    return report;
}

NSString *TKSignedCacheProbeReport(void) {
    FILE *log=fopen(TKDocumentsPath(@"signed-code-probe.log").fileSystemRepresentation,"w");
    if(!log) return @"Cannot open signed-code probe log.";
    BOOL ok=HostSignedCodeProbe(log);fclose(log);
    return ok?@"Signed code-cache mapping passed.\nNo debugger or game code used.":@"Signed code-cache mapping unavailable. See probe log.";
}

NSString *TKShaderPauseProbeReport(void) {
    BOOL previousIdleSetting=UIApplication.sharedApplication.idleTimerDisabled;
    UIApplication.sharedApplication.idleTimerDisabled=YES;
    FILE *log=fopen(TKDocumentsPath(@"shader-pause-probe.log").fileSystemRepresentation,"w");
    NSString *result=@"Cannot open shader probe log.";
    if(log) {
        BOOL ok=HostShaderPauseProbe(NSBundle.mainBundle.privateFrameworksPath,log);
        fclose(log);
        result=ok?@"Shader pause and recovery passed.\nNo game code was executed.":@"Shader pause test incomplete. See probe log.";
    }
    UIApplication.sharedApplication.idleTimerDisabled=previousIdleSetting;
    return result;
}

// Reservations of `size` until one fails (at most `limit`), then released: the total.
static uint64_t TKReserveUntilRefused(uint64_t size, int prot, unsigned limit) {
    void *held[64]; unsigned count=0;
    while (count<limit && count<64) {
        void *p=mmap(NULL,size,prot,MAP_PRIVATE|MAP_ANON,-1,0);
        if (p==MAP_FAILED) break;
        held[count++]=p;
    }
    uint64_t total=count*size;
    while (count) munmap(held[--count],size);
    return total;
}
// At fixed addresses without replacing anything: vm_allocate without
// VM_FLAGS_OVERWRITE fails where something is already mapped.
static void TKReserveFixed(NSMutableString *report, NSString *label, const uint64_t *bases, unsigned count, uint64_t size) {
    const uint64_t GB=1024ULL*1024*1024;
    vm_address_t held[8]={0}; uint64_t total=0;
    for (unsigned i=0;i<count && i<8;i++) {
        vm_address_t address=(vm_address_t)bases[i];
        kern_return_t kr=vm_allocate(mach_task_self(),&address,(vm_size_t)size,VM_FLAGS_FIXED);
        [report appendFormat:@"fixed %#llx %llu GB: %@\n",(unsigned long long)bases[i],size/GB,
            kr==KERN_SUCCESS?@"ok":kr==KERN_NO_SPACE?@"in use or out of range":[NSString stringWithFormat:@"fails kr=%d",kr]];
        if (kr==KERN_SUCCESS) { held[i]=address; total+=size; }
    }
    [report appendFormat:@"%@ held together: %llu GB\n",label,total/GB];
    for (unsigned i=0;i<count && i<8;i++) if (held[i]) vm_deallocate(mach_task_self(),held[i],(vm_size_t)size);
}
NSString *TKVMProbeReport(void) {
    const uint64_t GB=1024ULL*1024*1024;
    NSMutableString *report=[NSMutableString stringWithString:@"Virtual-memory reservations (experimental probe; no app code)\n"];
    const uint64_t singles[]={112,64,48,32,16,8};
    for (unsigned i=0;i<sizeof singles/sizeof *singles;i++) {
        void *p=mmap(NULL,singles[i]*GB,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
        [report appendFormat:@"single %llu GB: %@\n",singles[i],p==MAP_FAILED?@"fails":@"ok"];
        if (p!=MAP_FAILED) munmap(p,singles[i]*GB);
    }
    [report appendFormat:@"cumulative 4 GB reservations: %llu GB\n",TKReserveUntilRefused(4*GB,PROT_READ|PROT_WRITE,40)/GB];
    // Dense chart: where will the kernel take a fixed 1 GiB mapping at all?
    [report appendString:@"fixed 1 GB scan, 4..512 GiB, mappable windows:"];
    uint64_t windowStart=0; BOOL inWindow=NO;
    for (uint64_t base=0x100000000ULL; base<0x8000000000ULL; base+=0x40000000ULL) {
        vm_address_t address=(vm_address_t)base;
        kern_return_t kr=vm_allocate(mach_task_self(),&address,(vm_size_t)0x40000000ULL,VM_FLAGS_FIXED);
        BOOL ok=kr==KERN_SUCCESS;
        if (ok) vm_deallocate(mach_task_self(),address,(vm_size_t)0x40000000ULL);
        if (ok && !inWindow) { inWindow=YES; windowStart=base; }
        if (!ok && inWindow) { inWindow=NO; [report appendFormat:@" %#llx-%#llx",(unsigned long long)windowStart,(unsigned long long)base]; }
    }
    if (inWindow) [report appendFormat:@" %#llx-end",(unsigned long long)windowStart];
    [report appendString:@"\n"];
    [report appendFormat:@"cumulative 4 GB PROT_NONE reservations: %llu GB\n",TKReserveUntilRefused(4*GB,PROT_NONE,40)/GB];
    void *p=mmap(NULL,112*GB,PROT_NONE,MAP_PRIVATE|MAP_ANON,-1,0);
    [report appendFormat:@"single 112 GB PROT_NONE: %@\n",p==MAP_FAILED?@"fails":@"ok"];
    if (p!=MAP_FAILED) munmap(p,112*GB);
    // Commit on demand: reserve PROT_NONE, then make one page usable.
    p=mmap(NULL,4*GB,PROT_NONE,MAP_PRIVATE|MAP_ANON,-1,0);
    if (p==MAP_FAILED) [report appendString:@"reserve 4 GB PROT_NONE: fails\n"];
    else {
        size_t page=(size_t)getpagesize();
        if (mprotect(p,page,PROT_READ|PROT_WRITE)) [report appendFormat:@"PROT_NONE then read-write page: errno=%d\n",errno];
        else { memset(p,0x5a,page); [report appendString:@"PROT_NONE then read-write page and write: ok\n"]; }
        munmap(p,4*GB);
    }
    const uint64_t high[]={0x8000000000ULL,0x10000000000ULL,0x20000000000ULL,0x40000000000ULL};
    TKReserveFixed(report,@"fixed high reservations",high,4,16*GB);
    const uint64_t middle[]={0x1000000000ULL,0x2000000000ULL,0x4000000000ULL,0x6000000000ULL};
    TKReserveFixed(report,@"fixed middle reservations",middle,4,16*GB);
    // File-backed private mappings of a sparse file, in the temporary folder.
    NSString *sparse=[NSTemporaryDirectory() stringByAppendingPathComponent:@"vm-probe-sparse.bin"];
    int fd=open(sparse.fileSystemRepresentation,O_RDWR|O_CREAT|O_TRUNC,0600);
    if (fd<0) [report appendFormat:@"sparse file: errno=%d\n",errno];
    else {
        void *held[40]; unsigned count=0;
        if (!ftruncate(fd,(off_t)(8*GB)))
            while (count<40) {
                void *q=mmap(NULL,4*GB,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_FILE,fd,(off_t)((count%2)*4*GB));
                if (q==MAP_FAILED) break;
                held[count++]=q;
            }
        [report appendFormat:@"cumulative 4 GB file-backed private: %llu GB\n",(unsigned long long)count*4];
        while (count) munmap(held[--count],4*GB);
        close(fd); unlink(sparse.fileSystemRepresentation);
    }
    [report writeToFile:TKDocumentsPath(@"vm-probe.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return report;
}

NSString *TKExecutionProbeReport(HPMode mode, NSArray<NSString *> *arguments) {
    BOOL previousIdleSetting = UIApplication.sharedApplication.idleTimerDisabled;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    NSString *logPath = TKDocumentsPath(@"execution-probe.log");
    FILE *log = fopen(logPath.fileSystemRepresentation, "w");
    if (!log) {
        UIApplication.sharedApplication.idleTimerDisabled = previousIdleSetting;
        return @"Cannot open execution probe log.";
    }
    for (NSString *argument in arguments) {
        if ([argument hasPrefix:@"--probe-run-id="]) fprintf(log, "[execution] %s\n", argument.UTF8String);
    }
    HPResult result = host_execution_probe(mode, log);
    UIApplication.sharedApplication.idleTimerDisabled = previousIdleSetting;
    fclose(log);
    NSString *report = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:NULL];
    fprintf(stderr, "%s", report.UTF8String);
    return [NSString stringWithFormat:
        @"Host-generated arm64 execution test\n\nMode: %@\nExecute: %@\nRewrite and execute: %@\n\nAllocation errno: %d\nProtection errno: %d\n\nThis tests host code only. No imported app code has been executed.",
        mode==HP_DUAL_MAPPING ? @"Shared RW / RX views" : mode==HP_READ_WRITE_EXECUTE ? @"RWX" : @"RW → RX", result.executable ? @"PASS" : @"DENIED / FAILED",
        result.rewrite_executable ? @"PASS" : @"DENIED / FAILED",
        result.allocation_errno, result.protection_errno];
}
