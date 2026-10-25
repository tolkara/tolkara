// A native HAL implementation may autorelease even through a C API. The caller
// deliberately has no pool: every adapter call must drain native temporaries.
#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <assert.h>
static atomic_uint released;
@interface AudioTemporary : NSObject @end
@implementation AudioTemporary
- (void)dealloc { atomic_fetch_add(&released,1); }
@end
extern void *objc_autorelease(void *);
static OSStatus fakeInfo(UInt32 property,UInt32 *size,Boolean *writable) {
    (void)objc_autorelease((__bridge_retained void *)[AudioTemporary new]);
    *size=123;*writable=false;
    return property ? 0 : -4;
}
static void *testOpen(const char *path,int flags) { (void)path;(void)flags;return (void *)1; }
static void *testSymbol(void *handle,const char *name) {
    (void)handle;return !strcmp(name,"AudioHardwareGetPropertyInfo")?(void *)fakeInfo:NULL;
}
#define dlopen testOpen
#define dlsym testSymbol
#include "../translation/CoreAudio/Hardware.m"
#undef dlopen
#undef dlsym
static void *worker(void *unused) {
    (void)unused;
    for(unsigned i=0;i<2000;i++) {
        UInt32 size=0;Boolean writable=true;
        assert(AudioHardwareGetPropertyInfo(i%2,&size,&writable)==(i%2?0:-4));
        assert(size==123 && !writable);
        assert(atomic_load(&released)==i+1); // before thread exit or an outer pool
    }
    return NULL;
}
int main(void) {
    pthread_t thread;assert(!pthread_create(&thread,NULL,worker,NULL));
    assert(!pthread_join(thread,NULL));
    puts("audio C API drains native temporaries on success and failure: PASS");
}
