//
//  VideoInjector.h
//  MyVCam
//
//  Latest-buffer sink. There are still no hooks in this class.
//
//  Responsibility: remember whether the injector has been armed, and keep
//  one retained CMSampleBuffer — the latest one accepted. prepareWithError:
//  only sets that local flag. YES from prepare is not a camera, a capture
//  session, or mediaserverd. injectSampleBuffer:error: CFRetains a non-NULL
//  buffer once armed and stores it as _latest. stop CFReleases that buffer
//  and clears the flag. dealloc CFReleases it if stop did not.
//
//  copyLatestSampleBufferMatchingOrigin: reads that stored buffer. It
//  returns a new caller-owned image sample buffer whose pixels are adapted
//  to the origin image buffer's width, height, and pixel format (32BGRA,
//  420f, or 420v) and whose presentation time and duration come from the
//  origin buffer. It does not mutate either buffer. NULL means the caller
//  should keep the origin buffer. A non-video origin is always NULL.
//
//  The caller borrows the pointer it passes in. The injector owns only the
//  reference it CFRetains. This class does not install hooks, swizzle
//  capture classes, or talk to mediaserverd.
//
//  LAYERING: do not import MediaReader, MyVCamFrameSource, MyVCamManager,
//  or SampleBufferBuilder. The injector does not decode video. The read path
//  duplicates the small CoreMedia create sequence instead of calling
//  SampleBufferBuilder, and scales or converts only when building the buffer
//  returned to the capture delegate.
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

/// Caller owns the result (CF_RETURNS_RETAINED) and must CFRelease it.
/// NULL when origin is NULL or invalid, when origin is not a video image
/// buffer, when no latest buffer is stored, when the origin presentation
/// time is not numeric, when the origin pixel format is not 32BGRA / 420f /
/// 420v, or when a matching sample buffer cannot be built. NULL tells the
/// caller to keep the origin buffer. Audio buffers are not replaced.
/// Does not mutate origin or the stored latest buffer, and does not change
/// prepare / inject / stop.
///
/// The result is a new IOSurface-backed image sample buffer. Its dimensions
/// and pixel format match origin. Its pixels are the latest frame, scaled
/// and converted when the stored frame is 32BGRA of a different size or
/// format. Its presentation time and duration are copied from origin (output
/// time, then presentation time; output duration, then duration). A
/// non-positive or non-numeric duration becomes 1/30 second.
/// decodeTimeStamp is kCMTimeInvalid. The sample-attachment array is created
/// and kCMSampleAttachmentKey_DisplayImmediately is set. Arbitrary origin
/// sample-buffer attachments are not aliased into the result.
/// The injector lock is taken only to CFRetain the stored buffer.
- (CMSampleBufferRef _Nullable)copyLatestSampleBufferMatchingOrigin:(CMSampleBufferRef)origin
    CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
