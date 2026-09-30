//
//  VideoInjector.h
//  MyVCam
//
//  Phase A — local arming only. There is still no injection sink.
//
//  Responsibility: remember whether the injector has been armed, then accept
//  a borrowed CMSampleBuffer. prepareWithError: only sets that local flag.
//  YES from prepare is not a camera, a capture session, or mediaserverd.
//  injectSampleBuffer:error: still returns NO. stop clears the flag.
//
//  This phase does not install hooks, swizzle capture classes, or talk to
//  mediaserverd.
//
//  LAYERING: do not import MediaReader, MyVCamFrameSource, MyVCamManager,
//  or SampleBufferBuilder. The injector does not decode video and does not
//  convert CVPixelBuffer values.
//
//  Later reference (not ported in this phase): DiCoy AVFoundation hooks.
//  EthanArbuckle mediaserverd / BWNodeOutput injection is explicitly deferred
//  and is not represented by this interface.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const MyVCamVideoInjectorErrorDomain;

typedef NS_ENUM(NSInteger, MyVCamVideoInjectorErrorCode) {
    /// Kept (= 1). Returned when inject is armed and the buffer is non-NULL.
    /// Phase A has no sink, so that path still fails. prepare does not return this.
    MyVCamVideoInjectorErrorCodeNotImplemented = 1,
    /// injectSampleBuffer:error: received a NULL buffer after the injector was armed.
    MyVCamVideoInjectorErrorCodeInvalidSampleBuffer = 2,
    /// injectSampleBuffer:error: ran before prepareWithError:, or after stop.
    MyVCamVideoInjectorErrorCodeNotPrepared = 3,
};

@interface VideoInjector : NSObject

/// Arms local state and returns YES. Does not install a hook or open a session.
/// A second call while already armed returns YES again. The error out-parameter
/// is cleared. YES means the local flag is set, not that a frame was injected.
- (BOOL)prepareWithError:(NSError * _Nullable * _Nullable)error;

/// Borrows sampleBuffer and does not CFRetain or CFRelease it.
/// Not prepared (including after stop) → NO, NotPrepared, even if the buffer is NULL.
/// Armed and NULL → NO, InvalidSampleBuffer.
/// Armed and non-NULL → NO, NotImplemented. There is no sink, so this is not success.
- (BOOL)injectSampleBuffer:(CMSampleBufferRef _Nullable)sampleBuffer
                     error:(NSError * _Nullable * _Nullable)error;

/// Clears the armed flag. Does nothing else. Safe to call more than once.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
