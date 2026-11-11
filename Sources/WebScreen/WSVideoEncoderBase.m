#import "WSVideoEncoderBase.h"

@implementation WSVideoEncoderBase

- (NSInteger)releaseEncoder { return [self stopEncoder]; }
- (NSInteger)stopEncoder { return 0; }

- (void)setCallback:(nullable RTCVideoEncoderCallback)callback {}
- (NSInteger)startEncodeWithSettings:(RTCVideoEncoderSettings *)settings numberOfCores:(int)numberOfCores { return -1; }
- (NSInteger)encode:(RTCVideoFrame *)frame
    codecSpecificInfo:(nullable id<RTCCodecSpecificInfo>)info
           frameTypes:(NSArray<NSNumber *> *)frameTypes { return -1; }
- (int)setBitrate:(uint32_t)bitrateKbit framerate:(uint32_t)framerate { return 0; }
- (NSString *)implementationName { return @"WebScreen"; }
- (nullable RTCVideoEncoderQpThresholds *)scalingSettings { return nil; }
- (NSInteger)resolutionAlignment { return 1; }
- (BOOL)applyAlignmentToAllSimulcastLayers { return NO; }
- (BOOL)supportsNativeHandle { return YES; }

@end
