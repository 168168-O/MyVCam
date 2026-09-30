//
//  MyVCamFrameSource.h
//  MyVCam
//
//  Protocol only. No concrete reader lives here.
//  Stage 2.2 did not change these selectors.
//
//  Responsibility: the read side of the pipeline. A conforming type vends
//  CVPixelBuffer frames and the media times that belong to those frames.
//  It does not build CMSampleBuffer values and it does not inject them.
//
//  Legal output of this boundary: CVPixelBuffer (plus timing metadata).
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

/// Drop prepared state. Safe to call more than once. Does not inject.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
