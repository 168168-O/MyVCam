//
//  SampleBufferBuilder.h
//  MyVCam
//
//  Stage 2.2 — CVPixelBuffer → CMSampleBuffer.
//
//  Responsibility: wrap one pixel buffer in a CMSampleBuffer using the
//  presentation time and duration supplied by the caller. This type does not
//  open files, does not implement MyVCamFrameSource, and does not inject.
//
//  LAYERING: do not import MediaReader, MyVCamManager, or VideoInjector.
//
//  Reference (idea only, not vendored): DiCoy buildSampleBufferMatchingBuffer
//  and Murk _create_buffer both end at CMVideoFormatDescriptionCreateForImageBuffer
//  plus a sample-buffer create for that image. This method does not take an
//  origin camera buffer, does not copy attachments, and does not convert
//  pixel formats. The selector is MyVCam's, not theirs.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const MyVCamSampleBufferBuilderErrorDomain;

typedef NS_ENUM(NSInteger, MyVCamSampleBufferBuilderErrorCode) {
    /// Kept from Stage 2.1. The builder no longer returns this.
    MyVCamSampleBufferBuilderErrorCodeNotImplemented = 1,
    /// pixelBuffer was NULL.
    MyVCamSampleBufferBuilderErrorCodeInvalidPixelBuffer = 2,
    /// presentationTime was not a numeric CMTime.
    MyVCamSampleBufferBuilderErrorCodeInvalidTiming = 3,
    /// CoreMedia refused to create the format description or the sample buffer.
    MyVCamSampleBufferBuilderErrorCodeBuildFailed = 4,
};

@interface SampleBufferBuilder : NSObject

/// Builds one image sample buffer. Caller owns the result (CF_RETURNS_RETAINED).
/// NULL is failure. A non-positive or non-numeric duration is replaced with
/// 1/30 second. decodeTimeStamp is kCMTimeInvalid.
/// The sample-attachment array is created and marked display-immediately.
/// Does not retain extra ownership of pixelBuffer beyond what CoreMedia takes.
/// Does not copy attachments from a camera buffer.
- (CMSampleBufferRef _Nullable)sampleBufferWithPixelBuffer:(CVPixelBufferRef _Nullable)pixelBuffer
                                          presentationTime:(CMTime)presentationTime
                                                  duration:(CMTime)duration
                                                     error:(NSError * _Nullable * _Nullable)error
    CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
