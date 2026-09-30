//
//  MyVCamFrame.m
//  MyVCam
//
//  Stage 2.1 thin carrier. Retains a CVPixelBuffer and stores two CMTime
//  values. Does not decode, build a CMSampleBuffer, or inject.
//

#import "MyVCamFrame.h"

NS_ASSUME_NONNULL_BEGIN

@implementation MyVCamFrame {
    CVPixelBufferRef _pixelBuffer;
    CMTime _presentationTime;
    CMTime _duration;
}

- (nullable instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                            presentationTime:(CMTime)presentationTime
                                    duration:(CMTime)duration {
    if (pixelBuffer == NULL) {
        return nil;
    }
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _pixelBuffer = CVPixelBufferRetain(pixelBuffer);
    _presentationTime = presentationTime;
    _duration = duration;
    return self;
}

+ (nullable instancetype)frameWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                             presentationTime:(CMTime)presentationTime
                                     duration:(CMTime)duration {
    return [[self alloc] initWithPixelBuffer:pixelBuffer
                             presentationTime:presentationTime
                                     duration:duration];
}

- (CVPixelBufferRef)pixelBuffer {
    return _pixelBuffer;
}

- (CMTime)presentationTime {
    return _presentationTime;
}

- (CMTime)duration {
    return _duration;
}

- (void)dealloc {
    if (_pixelBuffer != NULL) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
}

@end

NS_ASSUME_NONNULL_END
