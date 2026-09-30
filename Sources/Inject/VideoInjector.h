//
//  VideoInjector.h
//  MyVCam
//
//  Latest-buffer sink. There are still no hooks.
//
//  Responsibility: remember whether the injector has been armed, and keep
//  one retained CMSampleBuffer — the latest one accepted. prepareWithError:
//  only sets that local flag. YES from prepare is not a camera, a capture
//  session, or mediaserverd. injectSampleBuffer:error: CFRetains a non-NULL
//  buffer once armed and stores it as _latest. stop CFReleases that buffer
//  and clears the flag. dealloc CFReleases it if stop did not.
//
//  The caller borrows the pointer it passes in. The injector owns only the
//  reference it CFRetains. This phase does not install hooks, swizzle
//  capture classes, or talk to mediaserverd.
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
    /// Kept (= 1) for ABI. The inject success path does not return this code.
    /// prepare does not return this.
    MyVCamVideoInjectorErrorCodeNotImplemented = 1,
    /// injectSampleBuffer:error: received a NULL buffer after the injector was armed.
    MyVCamVideoInjectorErrorCodeInvalidSampleBuffer = 2,
    /// injectSampleBuffer:error: ran before prepareWithError:, or after stop.
    MyVCamVideoInjectorErrorCodeNotPrepared = 3,
};

@interface VideoInjector : NSObject

/// Arms local state and returns YES. Does not install a hook or open a session.
/// A second call while already armed returns YES again. The error out-parameter
/// is cleared. YES means the local flag is set, not that a frame was stored.
- (BOOL)prepareWithError:(NSError * _Nullable * _Nullable)error;

/// Borrows sampleBuffer. The injector CFRetains only on the success path below.
/// Not prepared (including after stop) → NO, NotPrepared, even if the buffer is NULL.
/// Prepared and NULL → NO, InvalidSampleBuffer.
/// Prepared and non-NULL → CFRetain, CFRelease the previous _latest first when
/// replacing it, store the new buffer, clear the error, return YES.
/// The caller still owns and must release the borrowed original.
- (BOOL)injectSampleBuffer:(CMSampleBufferRef _Nullable)sampleBuffer
                     error:(NSError * _Nullable * _Nullable)error;

/// Under the injector lock, CFReleases _latest when it is set, clears it, and
/// clears the armed flag. Safe to call more than once.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
