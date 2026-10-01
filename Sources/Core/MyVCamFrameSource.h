//
//  MyVCamFrameSource.h
//  MyVCam
//
//  Protocol only. No concrete reader lives here.
//
//  Responsibility: the read side of the pipeline. A conforming type vends
//  CVPixelBuffer frames and the media times that belong to those frames.
//  It does not build CMSampleBuffer values and it does not inject them.
//
//  Legal output of this boundary: CVPixelBuffer (plus timing metadata).
//  NULL from -copyNextPixelBuffer is end of media only when -lastError is nil.
//  A non-nil -lastError means that NULL was a failure.
//  SampleBufferBuilder is the next type, and only MyVCamManager may call it.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@protocol MyVCamFrameSource <NSObject>

/// Prepare the source. A conformer may open media here.
- (BOOL)prepareWithError:(NSError * _Nullable * _Nullable)error;

/// Next video frame, or NULL when no buffer is available.
/// Non-NULL returns are owned by the caller (CF_RETURNS_RETAINED).
/// NULL means not prepared, end of media, or a source-specific failure.
/// NULL is not an empty successful frame.
- (CVPixelBufferRef _Nullable)copyNextPixelBuffer CF_RETURNS_RETAINED;

/// Presentation time of the buffer last returned by -copyNextPixelBuffer.
/// kCMTimeInvalid when no frame has been produced.
- (CMTime)presentationTimeOfLastFrame;

/// Duration of the buffer last returned by -copyNextPixelBuffer.
/// kCMTimeInvalid when no frame has been produced.
- (CMTime)durationOfLastFrame;

/// Why the latest -copyNextPixelBuffer returned NULL.
/// Nil means end of media, or that no read has failed yet.
/// Non-nil means not prepared, a decode failure, or a cancelled reader.
/// Orchestration must use this instead of downcasting to a concrete reader.
- (nullable NSError *)lastError;

/// Drop prepared state. Safe to call more than once. Does not inject.
- (void)reset;

@optional

/// Same open as -prepareWithError:. When the open is published, *epochOut is
/// that publication. 0 means nothing was published. A caller that does not
/// keep the publication calls -invalidatePublishedEpoch: so a late open cannot
/// stay running. Sources that do not implement this pair use -prepareWithError:
/// and -reset only.
- (BOOL)prepareWithError:(NSError * _Nullable * _Nullable)error
          publishedEpoch:(uint64_t * _Nullable)epochOut;

/// Drops the publication identified by epoch if it is still the current one.
/// A newer prepare or reset makes this a no-op. epoch 0 does nothing.
- (void)invalidatePublishedEpoch:(uint64_t)epoch;

@end

NS_ASSUME_NONNULL_END
