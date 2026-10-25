// The virtual session device must agree across desktop properties and RemoteIO.
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "SessionAudio.h"
#include <assert.h>
typedef struct { UInt32 mSelector,mScope,mElement; } Address;
extern OSStatus AudioHardwareGetProperty(UInt32,UInt32 *,void *);
extern OSStatus AudioObjectGetPropertyData(UInt32,const Address *,UInt32,const void *,UInt32 *,void *);
int main(void) { @autoreleasepool {
    assert(AKSessionAudioOnly());
    UInt32 device=0,size=sizeof device;
    assert(!AudioHardwareGetProperty('dOut',&size,&device) && device==AK_SESSION_OUTPUT_DEVICE);
    UInt32 input=123;size=sizeof input;
    assert(!AudioHardwareGetProperty('dIn ',&size,&input) && !input);
    UInt32 other=0;size=sizeof other;Address output={'dOut','glob',0};
    assert(!AudioObjectGetPropertyData(1,&output,0,NULL,&size,&other) && other==device);
    Address unknown={'xxxx','glob',0};size=sizeof other;
    assert(AudioObjectGetPropertyData(device,&unknown,0,NULL,&size,&other));
    AudioComponentDescription description={.componentType=kAudioUnitType_Output,.componentSubType='ahal',.componentManufacturer=kAudioUnitManufacturer_Apple};
    AudioComponent component=AudioComponentFindNext(NULL,&description);assert(component);
    AudioComponentInstance unit=NULL;assert(!AudioComponentInstanceNew(component,&unit));
    assert(!AudioUnitSetProperty(unit,2000,kAudioUnitScope_Global,0,&device,sizeof device));
    other=device+1;
    assert(AudioUnitSetProperty(unit,2000,kAudioUnitScope_Global,0,&other,sizeof other)==kAudioUnitErr_InvalidPropertyValue);
    size=sizeof other;other=0;
    assert(!AudioUnitGetProperty(unit,2000,kAudioUnitScope_Global,0,&other,&size) && other==device);
    assert(!AudioComponentInstanceDispose(unit));
    puts("session-only audio: shared device identity, no input, unknown property error, RemoteIO selection: PASS");
} }
