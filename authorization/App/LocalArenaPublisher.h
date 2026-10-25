#pragma once
#import <Foundation/Foundation.h>
#include "NativeCodeMemory.h"

// NO means definitely not submitted. Once submitted, missing/invalid replies
// imply uncertainty. Completion may run on any queue, exactly once or late.
typedef BOOL (^TKArenaTransport)(NSData *, void (^)(NSData *));
@interface TKLocalArenaPublisher : NSObject
- (instancetype)initWithTransport:(TKArenaTransport)transport;
// Single use per process owner. Main-thread waits pump the host run loop;
// invoke native launch from a run-loop callout, not inside a main-queue block.
- (NCPreparation)prepare:(void *)address size:(size_t)size timeout:(NSTimeInterval)timeout;
- (NCPreparation)prepare:(void *)address size:(size_t)size second:(void *)second
                    secondSize:(size_t)secondSize timeout:(NSTimeInterval)timeout;
@end
