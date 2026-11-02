#import "AppKit.h"
@implementation NSScreen
+ (NSScreen *)mainScreen { static NSScreen *s; static dispatch_once_t once; dispatch_once(&once, ^{s=[self new];}); return s; }
+ (NSArray *)screens { return @[self.mainScreen]; }
// The area the guest's windows get: the screen less the on-screen controls'
// side columns, where they take them.
- (NSRect)frame {
    double width, height;
    return AKScreenGameSize(&width, &height) ? CGRectMake(0, 0, width, height) : UIScreen.mainScreen.bounds;
}
- (NSRect)auxiliaryTopLeftArea { return CGRectZero; }
- (NSRect)auxiliaryTopRightArea { return CGRectZero; }
- (NSRect)convertRectFromBacking:(NSRect)r { CGFloat f=self.backingScaleFactor; return CGRectMake(r.origin.x/f,r.origin.y/f,r.size.width/f,r.size.height/f); }
- (NSRect)convertRectToBacking:(NSRect)r { CGFloat f=self.backingScaleFactor; return CGRectMake(r.origin.x*f,r.origin.y*f,r.size.width*f,r.size.height*f); }
- (NSRect)visibleFrame { return self.frame; }
- (CGFloat)backingScaleFactor { return UIScreen.mainScreen.nativeScale; }
- (NSDictionary *)deviceDescription { return @{@"NSScreenNumber":@1,@"NSDeviceSize":[NSValue valueWithCGSize:self.frame.size],@"NSDeviceResolution":[NSValue valueWithCGSize:CGSizeMake(72,72)],@"NSDeviceBitsPerSample":@8,@"NSDeviceColorSpaceName":@"NSCalibratedRGBColorSpace"}; }
- (NSInteger)maximumFramesPerSecond { return UIScreen.mainScreen.maximumFramesPerSecond; }
// No extended dynamic range is offered to the guest (1.0: standard range only).
- (CGFloat)maximumExtendedDynamicRangeColorComponentValue { return 1.0; }
- (CGFloat)maximumPotentialExtendedDynamicRangeColorComponentValue { return 1.0; }
- (NSTimeInterval)minimumRefreshInterval { return 1.0/UIScreen.mainScreen.maximumFramesPerSecond; }
- (NSTimeInterval)maximumRefreshInterval { return 1.0/60.0; }   // a fixed estimate, not the panel's range
- (NSString *)localizedName { return @"iPad display"; }
@end
