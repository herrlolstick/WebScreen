#import <Foundation/Foundation.h>
#import <WebRTC/RTCVideoEncoder.h>

NS_ASSUME_NONNULL_BEGIN

/// Base class for a WebRTC encoder written in Swift.
///
/// `RTCVideoEncoder` requires `-releaseEncoder`, which Swift imports as `release()` – a
/// name NSObject already owns, so a Swift class can't satisfy the protocol on its own.
/// This class forwards it to `-stopEncoder`; Swift subclasses override everything else.
@interface WSVideoEncoderBase : NSObject <RTCVideoEncoder>
- (NSInteger)stopEncoder;
@end

NS_ASSUME_NONNULL_END
