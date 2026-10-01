//
//  MyVCamManager.h
//  MyVCam
//
//  C1-C — local-file chain plus the feed that keeps VideoInjector's latest
//  buffer current.
//
//  Responsibility: own the pipeline objects, the order they are used, and
//  the timer that repeatedly injects. This is the only type that sits across
//  the frame source, the sample-buffer builder, and the injector.
//
//  Order:
//    id<MyVCamFrameSource>  →  CVPixelBuffer
//    SampleBufferBuilder    →  CMSampleBuffer
//    -copyNextSampleBufferWithError: stops here. It does not call VideoInjector.
//    -injectNextSampleBufferWithError: borrows that buffer to VideoInjector,
//    then CFReleases it.
//    The C1-C feed calls injectNext on com.myvcam.feed. The capture delegate
//    queue is not that queue. Tweak.x attaches, starts, and stops. It does
//    that on com.myvcam.enable after startRunning returns, not inside
//    startRunning and not after a delegate-callback count.
//
//  LAYERING
//  - The concrete reader (MediaReader) implements MyVCamFrameSource.
//    It must not call SampleBufferBuilder or VideoInjector.
//  - SampleBufferBuilder only converts CVPixelBuffer → CMSampleBuffer.
//  - VideoInjector only stores and reads the latest buffer. It does not
//    import the reader, the builder, or this type. This type calls prepare,
//    inject, and stop. It does not report inject success when the injector
//    returns NO.
//  - mediaserverd / BWNodeOutput is not a path on this type.
//  - This type's state lock is the outer lock. It is not held across
//    MediaReader or other AVFoundation calls. The reader and the injector
//    take their own locks and must not call back into this type.
//  - Do not dispatch_sync onto com.myvcam.feed while holding the state lock.
//    The feed timer is cancelled from other queues without waiting for it.
//
//  Reference (structure only): DiCoyTweakManager owns a local reader. The
//  methods below are MyVCam's and do not include screen mirror or IPC.
//

#import <Foundation/Foundation.h>
#import "MyVCamFrameSource.h"
#import "SampleBufferBuilder.h"
#import "VideoInjector.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const MyVCamManagerErrorDomain;

/// UTF-8 bytes of the fixed C1-C test video:
/// `/var/mobile/Documents/MyVCam/test.mp4`
/// Not packaged. The tweak may open this path or a mirror of it.
/// A missing file makes -startWithError: return NO and does not arm the feed.
extern const char MyVCamManagerTestVideoPathUTF8[];

typedef NS_ENUM(NSInteger, MyVCamManagerErrorCode) {
    /// Kept from Stage 2.1. startWithError: no longer returns this.
    /// injectNextSampleBufferWithError: does not return this either.
    /// Injector NotImplemented stays a failure and is wrapped as InjectFailed.
    MyVCamManagerErrorCodeNotImplemented = 1,
    /// attachMediaFileURL: was not called, or the source was detached.
    MyVCamManagerErrorCodeNoMedia = 2,
    /// The frame source or VideoInjector refused to prepare.
    /// userInfo may include that failure as NSUnderlyingErrorKey.
    MyVCamManagerErrorCodePrepareFailed = 3,
    /// copyNextSampleBufferWithError: or injectNextSampleBufferWithError:
    /// was called before a successful start.
    MyVCamManagerErrorCodeNotRunning = 4,
    /// injectNextSampleBufferWithError: only. The producer returned NULL
    /// with a nil error, which is end of the video track.
    /// copyNextSampleBufferWithError: keeps that case as NULL and a nil error.
    MyVCamManagerErrorCodeEndOfMedia = 5,
    /// injectNextSampleBufferWithError: VideoInjector returned NO.
    /// userInfo includes the injector error as NSUnderlyingErrorKey.
    /// This code is a failure, including when the underlying code is
    /// MyVCamVideoInjectorErrorCodeNotImplemented.
    MyVCamManagerErrorCodeInjectFailed = 6,
};

@interface MyVCamManager : NSObject

+ (instancetype)sharedManager;

/// Concrete MyVCamFrameSource. Nil until -attachMediaFileURL: stores a MediaReader.
@property (nonatomic, strong, readonly, nullable) id<MyVCamFrameSource> frameSource;

/// CVPixelBuffer → CMSampleBuffer. Used by -copyNextSampleBufferWithError:
/// and by -injectNextSampleBufferWithError:.
@property (nonatomic, strong, readonly) SampleBufferBuilder *sampleBufferBuilder;

/// Latest-buffer sink. -startWithError: calls -prepareWithError: after the
/// frame source prepares. -injectNextSampleBufferWithError: borrows one
/// sample buffer. -stop, -detachMediaFile, and -attachMediaFileURL: stop it.
/// The C1-C feed is the caller that keeps replacing the stored buffer.
@property (nonatomic, strong, readonly) VideoInjector *videoInjector;

/// Last URL passed to -attachMediaFileURL:, if any.
@property (nonatomic, copy, readonly, nullable) NSURL *mediaFileURL;

/// YES after -startWithError: succeeds, until -stop, detach, a new attach,
/// or the feed stops itself on an error.
@property (nonatomic, readonly, getter=isReading) BOOL reading;

/// Stores a MediaReader for fileURL as the frame source.
/// Does not open the file. A nil URL clears the source.
/// Replaces any reader already attached, cancels the feed timer, stops
/// VideoInjector, and clears the reading flag.
- (void)attachMediaFileURL:(nullable NSURL *)fileURL;

/// Drops the frame source and the stored URL. Cancels the feed timer,
/// resets the reader if one exists, and stops VideoInjector.
- (void)detachMediaFile;

/// Prepares the attached MediaReader, then prepares VideoInjector, then arms
/// the feed timer. Does not decode a frame on this thread.
/// A second successful call prepares again from the start of the file and
/// replaces the timer.
/// Reader prepare failure stops the injector, cancels any feed, and returns
/// PrepareFailed. A missing file fails here and does not crash.
/// Injector prepare failure sets reading to NO, resets the source, stops the
/// injector, cancels any feed, and returns PrepareFailed. The underlying
/// error is preserved.
///
/// On success the serial queue `com.myvcam.feed` calls
/// -injectNextSampleBufferWithError: on a fixed 30 fps timer (1/30 s, 1 ms
/// leeway), including once as soon as the timer is resumed. The interval does
/// not follow the file's nominal frame rate. Decode and inject stay on that
/// queue, not on the capture delegate queue.
/// End of the track loops when a frame was delivered since the last open:
/// the frame source is prepared again from the start of the file.
/// VideoInjector keeps its latest buffer across that rewind. The first loop
/// after a start is logged. A second end with no frame since the last open,
/// or any other feed error, cancels the timer and stops. A reader error of
/// TryAgain (NULL sample while AVAssetReader is still Reading) is not end
/// of media and does not stop the timer.
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;

/// Cancels the feed timer, resets the frame source, stops VideoInjector,
/// and clears the reading flag. An in-flight tick cannot arm another timer.
- (void)stop;

/// Pulls one CVPixelBuffer and builds one CMSampleBuffer.
/// Caller owns the result (CF_RETURNS_RETAINED).
/// NULL and a nil error means the video track has ended.
/// NULL and a non-nil error is the frame source's -lastError, or a builder error.
/// Does not call VideoInjector.
- (CMSampleBufferRef _Nullable)copyNextSampleBufferWithError:(NSError * _Nullable * _Nullable)error
    CF_RETURNS_RETAINED;

/// Produces one sample buffer the same way -copyNextSampleBufferWithError: does,
/// borrows it to VideoInjector, then CFReleases it once on both success and failure.
/// YES only when -injectSampleBuffer:error: returns YES.
/// End of media is NO with EndOfMedia. Producer failures are returned as-is.
/// The C1-C feed calls this from `com.myvcam.feed`. A direct call still pulls
/// one frame and shares the state lock with the feed.
/// Decode runs without the state lock. The inject retain is committed while
/// the lock is held so stop cannot free _latest in the middle of that retain.
/// Do not call this method while already holding the state lock.
- (BOOL)injectNextSampleBufferWithError:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
