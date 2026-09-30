//
//  MyVCamFrame.h
//  MyVCam
//
//  Stage 2.1 — optional thin carrier for one CVPixelBuffer plus its times.
//
//  Responsibility: keep a pixel buffer alive as an object so Core can hold a
//  frame without teaching MediaReader about CMSampleBuffer or injection.
//  SampleBufferBuilder does not accept this type. Its input remains
//  CVPixelBuffer. Callers that need a sample buffer read -pixelBuffer and
//  pass that pointer themselves.
//
//  This wrapper is not a reader and not an injector.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface MyVCamFrame : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// Retains pixelBuffer. Returns nil when pixelBuffer is NULL.
- (nullable instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                            presentationTime:(CMTime)presentationTime
                                    duration:(CMTime)duration NS_DESIGNATED_INITIALIZER;

+ (nullable instancetype)frameWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                             presentationTime:(CMTime)presentationTime
                                     duration:(CMTime)duration;

/// Non-owning. Valid until the frame is deallocated.
@property (nonatomic, readonly) CVPixelBufferRef pixelBuffer;

@property (nonatomic, readonly) CMTime presentationTime;
@property (nonatomic, readonly) CMTime duration;

@end

NS_ASSUME_NONNULL_END
