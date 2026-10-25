#import <AudioToolbox/AudioToolbox.h>
#import <AVFAudio/AVFAudio.h>
#import "AKSupport.h"
#import "SessionAudio.h"
#include <dlfcn.h>
#include <stdatomic.h>
@interface AKAudioRenderProbe : NSObject {
@public
    AURenderCallbackStruct original;
    size_t processSlot;
    atomic_uint_fast64_t calls, frames, nonzeroBuffers, errors, silent;
}
@end
@implementation AKAudioRenderProbe @end
static NSMutableDictionary<NSValue *,NSMutableArray<AKAudioRenderProbe *> *> *renderProbes;
static void prepareProbes(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        renderProbes=[NSMutableDictionary new];
        static dispatch_source_t timer;
        timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
        dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),5*NSEC_PER_SEC,NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer,^{
            NSMutableArray *groups=[NSMutableArray new];
            @synchronized(renderProbes) { for(NSArray *group in renderProbes.allValues)[groups addObject:[group copy]]; }
            for(NSArray *group in groups)for(AKAudioRenderProbe *probe in group) {
                AKLogC("audio render calls=%llu frames=%llu nonzero_buffers=%llu errors=%llu silence_flags=%llu",(unsigned long long)atomic_load(&probe->calls),(unsigned long long)atomic_load(&probe->frames),(unsigned long long)atomic_load(&probe->nonzeroBuffers),(unsigned long long)atomic_load(&probe->errors),(unsigned long long)atomic_load(&probe->silent));
            }
        });dispatch_resume(timer);
    });
}
static OSStatus observeRender(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *buffers) {
    AKAudioRenderProbe *probe=(__bridge AKAudioRenderProbe *)context;
    if (!AKEnterProcessCallback(probe->processSlot)) {
        if (buffers) for (UInt32 b=0; b<buffers->mNumberBuffers; b++)
            if (buffers->mBuffers[b].mData)
                memset(buffers->mBuffers[b].mData,0,buffers->mBuffers[b].mDataByteSize);
        if (flags) *flags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    OSStatus status=probe->original.inputProc(probe->original.inputProcRefCon,flags,time,bus,frames,buffers);
    AKLeaveProcessCallback(probe->processSlot);
    atomic_fetch_add_explicit(&probe->calls,1,memory_order_relaxed);
    atomic_fetch_add_explicit(&probe->frames,frames,memory_order_relaxed);
    if(status)atomic_fetch_add_explicit(&probe->errors,1,memory_order_relaxed);
    if(flags && (*flags&kAudioUnitRenderAction_OutputIsSilence))atomic_fetch_add_explicit(&probe->silent,1,memory_order_relaxed);
    if(!status && buffers)for(UInt32 b=0;b<buffers->mNumberBuffers;b++) {
        const uint8_t *bytes=buffers->mBuffers[b].mData;UInt32 size=buffers->mBuffers[b].mDataByteSize;
        if(bytes)for(UInt32 i=0;i<size;i++)if(bytes[i]) { atomic_fetch_add_explicit(&probe->nonzeroBuffers,1,memory_order_relaxed);break; }
    }
    return status;
}
static void *native(const char *name) {
    static void *library; static dispatch_once_t once;
    dispatch_once(&once,^{library=dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",RTLD_NOW|RTLD_LOCAL);});
    return library?dlsym(library,name):NULL;
}
static BOOL remoteOutput(AudioUnit unit) {
    AudioComponentDescription description={0};
    AudioComponent component=AudioComponentInstanceGetComponent(unit);
    return component && !AudioComponentGetDescription(component,&description) && description.componentType==kAudioUnitType_Output && description.componentSubType==kAudioUnitSubType_RemoteIO;
}
static OSStatus defaultOutput(UInt32 *device) {
    if(AKSessionAudioOnly()) {
        if(!AVAudioSession.sharedInstance.currentRoute.outputs.count)return kAudioUnitErr_InvalidPropertyValue;
        *device=AK_SESSION_OUTPUT_DEVICE;return 0;
    }
    static OSStatus (*get)(UInt32,UInt32 *,void *);static dispatch_once_t once;
    dispatch_once(&once,^{void *library=dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio",RTLD_NOW|RTLD_LOCAL);get=library?dlsym(library,"AudioHardwareGetProperty"):NULL;});
    if(!get || !AVAudioSession.sharedInstance.currentRoute.outputs.count)return kAudioUnitErr_InvalidPropertyValue;
    UInt32 size=sizeof *device;return get('dOut',&size,device);
}
AudioComponent AudioComponentFindNext(AudioComponent previous,const AudioComponentDescription *description) {
    AudioComponent (*f)(AudioComponent,const AudioComponentDescription *)=native(__func__);
    if(!f || !description)return NULL;
    AudioComponentDescription mapped=*description;
    if(mapped.componentType==kAudioUnitType_Output && (mapped.componentSubType=='ahal' || mapped.componentSubType=='def ')) {
        mapped.componentSubType=kAudioUnitSubType_RemoteIO;
        NSError *error=nil;AVAudioSession *session=AVAudioSession.sharedInstance;
        BOOL active=[session setCategory:AVAudioSessionCategoryPlayback error:&error] && [session setActive:YES error:&error];
        AKLog(@"audio playback session active=%d error_code=%ld",active,(long)error.code);
    }
    AudioComponent component=f(previous,&mapped);
    AKLogC("audio component type=%#x subtype=%#x mapped=%#x found=%d",(unsigned)description->componentType,(unsigned)description->componentSubType,(unsigned)mapped.componentSubType,component!=NULL);
    return component;
}
OSStatus AudioComponentInstanceNew(AudioComponent component,AudioComponentInstance *instance) {
    OSStatus (*f)(AudioComponent,AudioComponentInstance *)=native(__func__);OSStatus s=f?f(component,instance):-4;
    AKLogC("audio instance new status=%d",(int)s);return s;
}
OSStatus AudioUnitSetProperty(AudioUnit unit,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement element,const void *data,UInt32 size) {
    OSStatus (*f)(AudioUnit,AudioUnitPropertyID,AudioUnitScope,AudioUnitElement,const void *,UInt32)=native(__func__);
    OSStatus s;
    // Desktop HAL chooses a device explicitly. RemoteIO uses the session's
    // route. Accept only that actual default device, never an arbitrary ID.
    if(property==2000 && scope==kAudioUnitScope_Global && element==0 && remoteOutput(unit)) {
        UInt32 requested=0,current=0;
        if(!data || size!=sizeof requested)s=kAudioUnitErr_InvalidPropertyValue;
        else { memcpy(&requested,data,sizeof requested);s=defaultOutput(&current);if(!s && requested!=current)s=kAudioUnitErr_InvalidPropertyValue; }
    } else if(property==kAudioUnitProperty_SetRenderCallback && scope==kAudioUnitScope_Input && element==0 && data && size==sizeof(AURenderCallbackStruct) && remoteOutput(unit)) {
        prepareProbes();AKAudioRenderProbe *probe=[AKAudioRenderProbe new];memcpy(&probe->original,data,size);
        probe->processSlot=AKCallbackProcess((uintptr_t)probe->original.inputProc);
        if(probe->original.inputProc) {
            AURenderCallbackStruct observed={observeRender,(__bridge void *)probe};
            @synchronized(renderProbes) {
                NSValue *key=[NSValue valueWithPointer:unit];
                if(!renderProbes[key])renderProbes[key]=[NSMutableArray new];
                [renderProbes[key] addObject:probe];
            }
            s=f?f(unit,property,scope,element,&observed,sizeof observed):-4;
        } else s=f?f(unit,property,scope,element,data,size):-4;
    } else s=f?f(unit,property,scope,element,data,size):-4;
    if(property==kAudioUnitProperty_StreamFormat && data && size==sizeof(AudioStreamBasicDescription)) {
        AudioStreamBasicDescription format;memcpy(&format,data,sizeof format);
        AKLogC("audio stream rate=%.0f format=%#x flags=%#x channels=%u bytes_per_frame=%u bits=%u",format.mSampleRate,(unsigned)format.mFormatID,(unsigned)format.mFormatFlags,(unsigned)format.mChannelsPerFrame,(unsigned)format.mBytesPerFrame,(unsigned)format.mBitsPerChannel);
    }
    AKLogC("audio set property=%u scope=%u element=%u size=%u status=%d",(unsigned)property,(unsigned)scope,(unsigned)element,(unsigned)size,(int)s);return s;
}
OSStatus AudioUnitGetProperty(AudioUnit unit,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement element,void *data,UInt32 *size) {
    OSStatus (*f)(AudioUnit,AudioUnitPropertyID,AudioUnitScope,AudioUnitElement,void *,UInt32 *)=native(__func__);
    OSStatus s;
    if(property==2000 && scope==kAudioUnitScope_Global && element==0 && remoteOutput(unit)) {
        UInt32 current=0;
        if(!data || !size || *size<sizeof current)s=kAudioUnitErr_InvalidPropertyValue;
        else { s=defaultOutput(&current);if(!s) { memcpy(data,&current,sizeof current);*size=sizeof current; } }
    } else s=f?f(unit,property,scope,element,data,size):-4;
    if(!s && property==kAudioUnitProperty_StreamFormat && data && size && *size==sizeof(AudioStreamBasicDescription) && remoteOutput(unit)) {
        AudioStreamBasicDescription format;memcpy(&format,data,sizeof format);
        // RemoteIO exposes an unspecified rate before initialization. A desktop
        // HAL client expects the selected hardware device's concrete format.
        if(format.mSampleRate==0 && AVAudioSession.sharedInstance.sampleRate>0) {
            format.mSampleRate=AVAudioSession.sharedInstance.sampleRate;memcpy(data,&format,sizeof format);
        }
        AKLogC("audio queried stream rate=%.0f channels=%u",format.mSampleRate,(unsigned)format.mChannelsPerFrame);
    }
    AKLogC("audio get property=%u scope=%u element=%u status=%d",(unsigned)property,(unsigned)scope,(unsigned)element,(int)s);return s;
}
OSStatus AudioUnitInitialize(AudioUnit unit) {
    OSStatus (*f)(AudioUnit)=native(__func__);OSStatus s=f?f(unit):-4;AKLogC("audio initialize status=%d",(int)s);return s;
}
OSStatus AudioOutputUnitStart(AudioUnit unit) {
    OSStatus (*f)(AudioUnit)=native(__func__);OSStatus s=f?f(unit):-4;AKLogC("audio start status=%d",(int)s);
    AVAudioSession *session=AVAudioSession.sharedInstance;
    AKLog(@"audio route types=%@ volume=%.2f sample_rate=%.0f channels=%lu",[session.currentRoute.outputs valueForKey:@"portType"],session.outputVolume,session.sampleRate,(unsigned long)session.outputNumberOfChannels);
    return s;
}
OSStatus AudioComponentInstanceDispose(AudioComponentInstance instance) {
    OSStatus (*f)(AudioComponentInstance)=native(__func__);OSStatus s=f?f(instance):-4;
    if(!s && renderProbes)@synchronized(renderProbes) { [renderProbes removeObjectForKey:[NSValue valueWithPointer:instance]]; }
    return s;
}
