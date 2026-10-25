// Synthetic callback and native buffers only; no application or audio device runs.
#import "../translation/AudioToolbox/Output.m"
#include <assert.h>
#include <pthread.h>
static pthread_mutex_t gate=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed=PTHREAD_COND_INITIALIZER;
static bool entered, finish;
static unsigned calls;
static size_t owner(uintptr_t address) { (void)address; return 1; }
static OSStatus render(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *buffers) {
    (void)context; (void)flags; (void)time; (void)bus; (void)frames; (void)buffers;
    pthread_mutex_lock(&gate);
    calls++; entered=true; pthread_cond_broadcast(&changed);
    while(!finish) pthread_cond_wait(&changed,&gate);
    pthread_mutex_unlock(&gate);
    return noErr;
}
static void *run(void *context) {
    @autoreleasepool { assert(!observeRender(context,NULL,NULL,0,0,NULL)); }
    return NULL;
}
int main(void) { @autoreleasepool {
    AKConfigureProcessCallbacks(3,owner);
    AKAudioRenderProbe *probe=[AKAudioRenderProbe new];
    probe->original=(AURenderCallbackStruct){render,NULL};
    probe->processSlot=AKCallbackProcess((uintptr_t)render);
    pthread_t thread;
    assert(!pthread_create(&thread,NULL,run,(__bridge void *)probe));
    pthread_mutex_lock(&gate);
    while(!entered) pthread_cond_wait(&changed,&gate);
    AKRetireProcessCallbacks(1);
    assert(!AKProcessCallbacksDrained(1));
    assert(!AKEnterProcessCallback(1));
    finish=true; pthread_cond_broadcast(&changed); pthread_mutex_unlock(&gate);
    assert(!pthread_join(thread,NULL));
    assert(AKProcessCallbacksDrained(1));
    unsigned char samples[16]; memset(samples,0x7f,sizeof samples);
    AudioBufferList buffers={.mNumberBuffers=1,.mBuffers={{1,sizeof samples,samples}}};
    AudioUnitRenderActionFlags flags=0;
    assert(!observeRender((__bridge void *)probe,&flags,NULL,0,4,&buffers));
    assert(calls==1 && (flags & kAudioUnitRenderAction_OutputIsSilence));
    for(size_t i=0;i<sizeof samples;i++) assert(samples[i]==0);
    assert(AKEnterProcessCallback(2)); AKLeaveProcessCallback(2);
    assert(!AKProcessCallbacksDrained(2));
    assert(!AKEnterProcessCallback(3));
    puts("PASS: in-flight audio drains; retired callbacks produce silence without guest entry");
} }
