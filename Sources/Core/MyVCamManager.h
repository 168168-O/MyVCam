//
//  MyVCamManager.h
//  MyVCam
//
//  Phase B — local-file chain, wired through to a borrowed inject call.
//
//  Responsibility: own the pipeline objects and the order they are used.
//  This is the only type that sits across the frame source, the sample-buffer
//  builder, and the injector.
//
//  Phase B order:
//    id<MyVCamFrameSource>  →  CVPixelBuffer
//    SampleBufferBuilder    →  CMSampleBuffer
//    -copyNextSampleBufferWithError: stops here. It does not call VideoInjector.
//    -injectNextSampleBufferWithError: borrows that buffer to VideoInjector,
//    then CFReleases it. Phase A has no sink, so inject still fails.
//
//  LAYERING
//  - The concrete reader (MediaReader) implements MyVCamFrameSource.
//    It must not call SampleBufferBuilder or VideoInjector.
//  - SampleBufferBuilder only converts CVPixelBuffer → CMSampleBuffer.
//  - VideoInjector only injects. Phase A arms it locally and still returns
//    NO from injectSampleBuffer:error:. This type calls prepare, inject, and
//    stop. It does not report inject success when the injector returns NO.
//  - mediaserverd / BWNodeOutput is not a path on this type.
//  - This type's state lock is the outer lock. The reader and the injector
//    take their own locks and must not call back into this type.
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

/// Phase A local arm. -startWithError: calls -prepareWithError: after the
/// frame source prepares. -injectNextSampleBufferWithError: borrows one
/// sample buffer. -stop, -detachMediaFile, and -attachMediaFileURL: call -stop.
/// There is still no injection sink. -injectSampleBuffer:error: still returns NO.
@property (nonatomic, strong, readonly) VideoInjector *videoInjector;

/// Last URL passed to -attachMediaFileURL:, if any.
@property (nonatomic, copy, readonly, nullable) NSURL *mediaFileURL;

/// YES after -startWithError: succeeds, until -stop, detach, or a new attach.
@property (nonatomic, readonly, getter=isReading) BOOL reading;

/// Stores a MediaReader for fileURL as the frame source.
/// Does not open the file. A nil URL clears the source.
/// Replaces any reader already attached, stops VideoInjector, and clears the reading flag.
- (void)attachMediaFileURL:(nullable NSURL *)fileURL;

/// Drops the frame source and the stored URL. Resets the reader if one exists.
/// Stops VideoInjector.
- (void)detachMediaFile;

/// Prepares the attached MediaReader, then prepares VideoInjector.
/// Does not decode a frame and does not inject one.
/// A second successful call prepares again from the start of the file.
/// Reader prepare failure stops the injector and returns PrepareFailed.
/// Injector prepare failure sets reading to NO, resets the source, stops the
/// injector, and returns PrepareFailed. The underlying error is preserved.
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;

/// Resets the frame source, stops VideoInjector, and clears the reading flag.
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
/// YES only when -injectSampleBuffer:error: returns YES. Phase A has no sink,
/// so that call returns NotImplemented and this method returns NO with InjectFailed.
/// End of media is NO with EndOfMedia. Producer failures are returned as-is.
/// Uses the private locked producer. Calling the public copy method under the
/// state lock would deadlock.
- (BOOL)injectNextSampleBufferWithError:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
