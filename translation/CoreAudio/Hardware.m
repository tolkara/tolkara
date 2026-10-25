#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import "AKSupport.h"
#import "SessionAudio.h"
#include <dlfcn.h>
#include <math.h>
typedef UInt32 AudioDeviceID;
typedef OSStatus (*HardwareListener)(UInt32,void *);
static _Atomic(UInt32) defaultOutputDevice;
static AudioDeviceID routeDevice(void);
static NSString *outputName(void) {
    AVAudioSession *session=AVAudioSession.sharedInstance; NSError *error=nil;
    if(![session.category isEqualToString:AVAudioSessionCategoryPlayback] || session.sampleRate<=0 || !session.currentRoute.outputs.count)
        if(![session setCategory:AVAudioSessionCategoryPlayback error:&error] || ![session setActive:YES error:&error])return nil;
    NSArray *outputs=session.currentRoute.outputs;
    return outputs.count?[(AVAudioSessionPortDescription *)outputs.firstObject portName]:nil;
}
static OSStatus copyName(UInt32 capacity,UInt32 *size,void *data) {
    NSString *name=outputName();if(!name)return 'what';
    NSData *bytes=[name dataUsingEncoding:NSUTF8StringEncoding];UInt32 required=(UInt32)bytes.length+1;
    if(size)*size=required;
    if(!size || !data || capacity<required)return '!siz';
    memcpy(data,bytes.bytes,bytes.length);((char *)data)[bytes.length]=0;return 0;
}
static void *native(const char *name) {
    if(AKSessionAudioOnly())return NULL;
    static void *library; static dispatch_once_t once;
    dispatch_once(&once,^{library=dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio",RTLD_NOW|RTLD_LOCAL);});
    return library?dlsym(library,name):NULL;
}
static void report(const char *operation,UInt32 property,OSStatus status,UInt32 size) {
    static unsigned count;
    @synchronized(NSProcessInfo.class) { if(count++>=64)return; }
    AKLogC("audio %s property=%c%c%c%c status=%d size=%u",operation,(property>>24)&255,(property>>16)&255,(property>>8)&255,property&255,(int)status,(unsigned)size);
}
// Wine calls these C entry points on long-lived pthreads without Cocoa pools.
// Both AVAudioSession and native HAL plugins can autorelease temporary objects.
// Drain them per call; returned CF strings retain their existing +1 ownership.
OSStatus AudioHardwareGetPropertyInfo(UInt32 property,UInt32 *size,Boolean *writable) {
    @autoreleasepool {
        if(AKSessionAudioOnly()) {
            if(property!='dOut' && property!='sOut' && property!='dIn ' && property!='dev#')return 'what';
            if(!size)return '!siz';
            *size=property=='dev#' && !routeDevice()?0:sizeof(UInt32);
            if(writable)*writable=false;
            return 0;
        }
        OSStatus (*f)(UInt32,UInt32 *,Boolean *)=native(__func__);
        OSStatus s=f?f(property,size,writable):-4;report(__func__,property,s,s==0&&size?*size:0);return s;
    }
}
OSStatus AudioHardwareGetProperty(UInt32 property,UInt32 *size,void *data) {
    @autoreleasepool {
        if(AKSessionAudioOnly()) {
            if(property!='dOut' && property!='sOut' && property!='dIn ' && property!='dev#')return 'what';
            UInt32 device=property=='dIn '?0:routeDevice();
            UInt32 required=property=='dev#' && !device?0:sizeof device;
            if(!size)return '!siz';
            UInt32 capacity=*size;*size=required;
            if(capacity<required || (required && !data))return '!siz';
            if(required)memcpy(data,&device,required);
            return 0;
        }
        OSStatus (*f)(UInt32,UInt32 *,void *)=native(__func__);
        OSStatus s=f?f(property,size,data):-4;
        if(!s && property=='dOut' && size && *size==sizeof(UInt32) && data) { UInt32 device;memcpy(&device,data,sizeof device);defaultOutputDevice=device;AKLogC("audio default output device=%u",(unsigned)device); }
        report(__func__,property,s,s==0&&size?*size:0);return s;
    }
}
OSStatus AudioHardwareAddPropertyListener(UInt32 property,HardwareListener listener,void *context) {
    @autoreleasepool {
        OSStatus (*f)(UInt32,HardwareListener,void *)=native(__func__);
        OSStatus s=f?f(property,listener,context):-4;report(__func__,property,s,0);return s;
    }
}
OSStatus AudioDeviceGetPropertyInfo(AudioDeviceID device,UInt32 channel,Boolean input,UInt32 property,UInt32 *size,Boolean *writable) {
    @autoreleasepool {
        OSStatus (*f)(AudioDeviceID,UInt32,Boolean,UInt32,UInt32 *,Boolean *)=native(__func__);
        OSStatus s=f?f(device,channel,input,property,size,writable):-4;
        if(s && device==defaultOutputDevice && !input && property=='name') { NSString *name=outputName();if(name) { if(size)*size=(UInt32)[name lengthOfBytesUsingEncoding:NSUTF8StringEncoding]+1;if(writable)*writable=false;s=0; } }
        if(device==defaultOutputDevice && !input && (property=='nsrt' || property=='fsz#')) {
            if(size)*size=property=='nsrt'?sizeof(Float64):sizeof(UInt32);
            if(writable)*writable=false;s=0;
        }
        report(__func__,property,s,s==0&&size?*size:0);return s;
    }
}
OSStatus AudioDeviceGetProperty(AudioDeviceID device,UInt32 channel,Boolean input,UInt32 property,UInt32 *size,void *data) {
    @autoreleasepool {
        OSStatus (*f)(AudioDeviceID,UInt32,Boolean,UInt32,UInt32 *,void *)=native(__func__);
        UInt32 capacity=size?*size:0;OSStatus s=f?f(device,channel,input,property,size,data):-4;
        if(s && device==defaultOutputDevice && !input && property=='name')s=copyName(capacity,size,data);
        if(device==defaultOutputDevice && !input && (property=='nsrt' || property=='fsz#')) {
            // The legacy iOS hardware API may return success with a zero nominal
            // rate. RemoteIO's route comes from the activated audio session.
            NSString *route=outputName();AVAudioSession *session=AVAudioSession.sharedInstance;
            Float64 rate=session.sampleRate;UInt32 frames=(UInt32)llround(rate*session.IOBufferDuration);
            UInt32 required=property=='nsrt'?sizeof rate:sizeof frames;
            if(!route || rate<=0 || (property=='fsz#' && !frames))s='what';
            else if(!size || !data || capacity<required) { if(size)*size=required;s='!siz'; }
            else { memcpy(data,property=='nsrt'?(const void *)&rate:(const void *)&frames,required);*size=required;s=0; }
            AKLogC("audio route nominal_rate=%.0f buffer_frames=%u",rate,(unsigned)frames);
        }
        report(__func__,property,s,s==0&&size?*size:0);return s;
    }
}
OSStatus AudioDeviceSetProperty(AudioDeviceID device,const void *when,UInt32 channel,Boolean input,UInt32 property,UInt32 size,const void *data) {
    @autoreleasepool {
        OSStatus (*f)(AudioDeviceID,const void *,UInt32,Boolean,UInt32,UInt32,const void *)=native(__func__);
        OSStatus s=f?f(device,when,channel,input,property,size,data):-4;report(__func__,property,s,size);return s;
    }
}

// The property API (Wine's Mac audio driver asks through it). iPadOS's own
// answers name no device with output channels; the one output device is the
// session's route, under the ID the legacy API reports as the default output
// (the AudioToolbox adapter accepts that one for RemoteIO). Everything else,
// and every other object, goes to the system.
typedef struct { UInt32 mSelector, mScope, mElement; } AKPropertyAddress;
typedef OSStatus (*PropertySize)(UInt32,const AKPropertyAddress *,UInt32,const void *,UInt32 *);
typedef OSStatus (*PropertyData)(UInt32,const AKPropertyAddress *,UInt32,const void *,UInt32 *,void *);
typedef OSStatus (*PropertySet)(UInt32,const AKPropertyAddress *,UInt32,const void *,UInt32,const void *);
static NSString *const AKOutputUID=@"TolkaraOutput";
static AudioDeviceID routeDevice(void) {
    if(!outputName())return 0;
    if(AKSessionAudioOnly()) { defaultOutputDevice=AK_SESSION_OUTPUT_DEVICE;return AK_SESSION_OUTPUT_DEVICE; }
    OSStatus (*get)(UInt32,UInt32 *,void *)=native("AudioHardwareGetProperty");
    UInt32 device=0,size=sizeof device;
    return get && !get('dOut',&size,&device) && size==sizeof device ? device : 0;
}
// The size of a property this adapter answers, or 0 when the system answers.
static UInt32 answeredSize(UInt32 object,const AKPropertyAddress *address,AudioDeviceID route) {
    if(!route || !address)return 0;
    if(object==1)return address->mSelector=='dOut' || address->mSelector=='sOut' || address->mSelector=='dIn ' || address->mSelector=='dev#' ? sizeof(AudioDeviceID) : 0;
    if(object!=route)return 0;
    switch(address->mSelector) {
        case 'slay': return (UInt32)(offsetof(AudioBufferList,mBuffers)+(address->mScope=='inpt'?0:sizeof(AudioBuffer)));
        case 'lnam': case 'uid ': return sizeof(CFStringRef);
        case 'nsrt': return sizeof(Float64);
        case 'ltnc': return sizeof(UInt32);
        case 'stm#': return UINT32_MAX;   // present, and empty
        default: return 0;
    }
}
OSStatus AudioObjectGetPropertyDataSize(UInt32 object,const AKPropertyAddress *address,UInt32 qualifierSize,const void *qualifier,UInt32 *size) {
    @autoreleasepool {
        UInt32 answered=answeredSize(object,address,routeDevice());
        if(answered) { if(!size)return '!siz';*size=answered==UINT32_MAX?0:answered;return 0; }
        PropertySize f=native(__func__);return f?f(object,address,qualifierSize,qualifier,size):'who?';
    }
}
OSStatus AudioObjectGetPropertyData(UInt32 object,const AKPropertyAddress *address,UInt32 qualifierSize,const void *qualifier,UInt32 *size,void *data) {
    @autoreleasepool {
        AudioDeviceID route=routeDevice();
        // A UID names our device, whatever the system says.
        if(route && object==1 && address && address->mSelector=='uidd' && qualifierSize==sizeof(CFStringRef) && qualifier && size && *size>=sizeof route && data &&
           [(__bridge NSString *)*(CFStringRef const *)qualifier isEqualToString:AKOutputUID]) { memcpy(data,&route,sizeof route);*size=sizeof route;return 0; }
        UInt32 answered=answeredSize(object,address,route);
        if(!answered) { PropertyData f=native(__func__);return f?f(object,address,qualifierSize,qualifier,size,data):'who?'; }
        if(answered==UINT32_MAX) { if(size)*size=0;return 0; }
        if(!size || !data || *size<answered)return '!siz';
        AVAudioSession *session=AVAudioSession.sharedInstance;
        switch(address->mSelector) {
            case 'dOut': case 'sOut': case 'dev#': memcpy(data,&route,sizeof route);break;
            case 'dIn ': { UInt32 input=0;memcpy(data,&input,sizeof input);break; }
            case 'slay': {
                AudioBufferList *buffers=data;
                buffers->mNumberBuffers=address->mScope=='inpt'?0:1;
                if(buffers->mNumberBuffers)buffers->mBuffers[0]=(AudioBuffer){(UInt32)MAX(session.outputNumberOfChannels,1),0,NULL};
                break;
            }
            case 'lnam': { CFStringRef name=CFBridgingRetain(outputName()?:@"iPad");memcpy(data,&name,sizeof name);break; }
            case 'uid ': { CFStringRef uid=CFBridgingRetain(AKOutputUID);memcpy(data,&uid,sizeof uid);break; }
            case 'nsrt': { Float64 rate=session.sampleRate>0?session.sampleRate:48000;memcpy(data,&rate,sizeof rate);break; }
            case 'ltnc': { UInt32 frames=(UInt32)llround(session.outputLatency*(session.sampleRate>0?session.sampleRate:48000));memcpy(data,&frames,sizeof frames);break; }
        }
        *size=answered;return 0;
    }
}
OSStatus AudioObjectSetPropertyData(UInt32 object,const AKPropertyAddress *address,UInt32 qualifierSize,const void *qualifier,UInt32 size,const void *data) {
    @autoreleasepool {
        // The route's volume belongs to the user; a program's own level is applied in its mix.
        if(address && address->mSelector=='volm' && object && object==routeDevice())return 0;
        PropertySet f=native(__func__);return f?f(object,address,qualifierSize,qualifier,size,data):'who?';
    }
}
