//
//  VideoInjector.m
//  MyVCam
//
//  Stage 2.1 stub. No Substrate hooks, no AVFoundation swizzles, no
//  mediaserverd / BWNodeOutput path.
//
//  LAYERING: do not import MediaReader.h, SampleBufferBuilder.h, or
//  MyVCamManager.h.
//
//  Later reference (not ported): DiCoy AVFoundation hooks.
//  Ethan mediaserverd injection stays deferred.
//

#import "VideoInjector.h"

NS_ASSUME_NONNULL_BEGIN

NSString * const MyVCamVideoInjectorErrorDomain = @"MyVCamVideoInjectorErrorDomain";

@implementation VideoInjector

- (BOOL)prepareWithError:(NSError * _Nullable * _Nullable)error {
    if (error != NULL) {
        *error = [self notImplementedError];
    }
    return NO;
}

- (BOOL)injectSampleBuffer:(CMSampleBufferRef _Nullable)sampleBuffer
                     error:(NSError * _Nullable * _Nullable)error {
    (void)sampleBuffer;
    if (error != NULL) {
        *error = [self notImplementedError];
    }
    return NO;
}

- (void)stop {
    // No hook was installed.
}

- (NSError *)notImplementedError {
    return [NSError errorWithDomain:MyVCamVideoInjectorErrorDomain
                                code:MyVCamVideoInjectorErrorCodeNotImplemented
                            userInfo:@{
        NSLocalizedDescriptionKey:
            @"VideoInjector is a Stage 2.1 stub and does not inject sample buffers."
    }];
}

@end

NS_ASSUME_NONNULL_END
