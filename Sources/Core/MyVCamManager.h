//
//  MyVCamManager.h
//  MyVCam
//
//  Stage 2.2 — orchestrates the local-file chain only.
//
//  Responsibility: own the pipeline objects and the order they are used.
//  This is the only type that sits across the frame source, the sample-buffer
//  builder, and the injector.
//
//  Stage 2.2 order (injection is not called):
//    id<MyVCamFrameSource>  →  CVPixelBuffer
//    SampleBufferBuilder    →  CMSampleBuffer
//
//  LAYERING
//  - The concrete reader (MediaReader) implements MyVCamFrameSource.
//    It must not call SampleBufferBuilder or VideoInjector.
//  - SampleBufferBuilder only converts CVPixelBuffer → CMSampleBuffer.
//  - VideoInjector only injects. It is still a stub and this type does not
//    call it.
//  - mediaserverd / BWNodeOutput is not a path on this type.
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
    MyVCamManagerErrorCodeNotImplemented = 1,
    /// attachMediaFileURL: was not called, or the source was detached.
    MyVCamManagerErrorCodeNoMedia = 2,
    /// The frame source refused to prepare. userInfo may include the source error.
    MyVCamManagerErrorCodePrepareFailed = 3,
    /// copyNextSampleBufferWithError: was called before a successful start.
    MyVCamManagerErrorCodeNotRunning = 4,
};

@interface MyVCamManager : NSObject

+ (instancetype)sharedManager;

/// Concrete MyVCamFrameSource. Nil until -attachMediaFileURL: stores a MediaReader.
@property (nonatomic, strong, readonly, nullable) id<MyVCamFrameSource> frameSource;

/// CVPixelBuffer → CMSampleBuffer. Used by -copyNextSampleBufferWithError:.
@property (nonatomic, strong, readonly) SampleBufferBuilder *sampleBufferBuilder;

/// Still a Stage 2.1 stub. Not called by start, stop, or copyNextSampleBufferWithError:.
@property (nonatomic, strong, readonly) VideoInjector *videoInjector;

/// Last URL passed to -attachMediaFileURL:, if any.
@property (nonatomic, copy, readonly, nullable) NSURL *mediaFileURL;

/// YES after -startWithError: succeeds, until -stop, detach, or a new attach.
@property (nonatomic, readonly, getter=isReading) BOOL reading;

/// Stores a MediaReader for fileURL as the frame source.
/// Does not open the file. A nil URL clears the source.
/// Replaces any reader already attached and clears the reading flag.
- (void)attachMediaFileURL:(nullable NSURL *)fileURL;

/// Drops the frame source and the stored URL. Resets the reader if one exists.
/// Does not call VideoInjector.
- (void)detachMediaFile;

/// Prepares the attached MediaReader. Does not decode a frame and does not inject.
/// A second successful call prepares again from the start of the file.
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;

/// Resets the frame source and clears the reading flag. Does not call VideoInjector.
- (void)stop;

/// Pulls one CVPixelBuffer and builds one CMSampleBuffer.
/// Caller owns the result (CF_RETURNS_RETAINED).
/// NULL and a nil error means the video track has ended.
/// NULL and a non-nil error is the frame source's -lastError, or a builder error.
/// Does not call VideoInjector.
- (CMSampleBufferRef _Nullable)copyNextSampleBufferWithError:(NSError * _Nullable * _Nullable)error
    CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
