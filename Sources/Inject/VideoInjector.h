//
//  VideoInjector.h
//  MyVCam
//
//  Stage 2.1 — injection boundary only.
//
//  Responsibility: accept a CMSampleBuffer and inject it. This stage does
//  not install hooks, swizzle capture classes, or talk to mediaserverd.
//
//  LAYERING: do not import MediaReader, MyVCamFrameSource, MyVCamManager,
//  or SampleBufferBuilder. The injector does not decode video and does not
//  convert CVPixelBuffer values.
//
//  Later reference (not ported in this stage): DiCoy AVFoundation hooks.
//  EthanArbuckle mediaserverd / BWNodeOutput injection is explicitly deferred
//  and is not represented by this interface.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const MyVCamVideoInjectorErrorDomain;

typedef NS_ENUM(NSInteger, MyVCamVideoInjectorErrorCode) {
    /// prepare and inject fail with this code. Stage 2.1 never reports success.
    MyVCamVideoInjectorErrorCodeNotImplemented = 1,
};

@interface VideoInjector : NSObject

/// Stage 2.1 always fails. Does not install hooks or touch a capture session.
- (BOOL)prepareWithError:(NSError * _Nullable * _Nullable)error;

/// Stage 2.1 always fails. Does not enqueue or replace a sample buffer.
- (BOOL)injectSampleBuffer:(CMSampleBufferRef _Nullable)sampleBuffer
                     error:(NSError * _Nullable * _Nullable)error;

/// Stage 2.1 no-op. There is no hook and no session to remove.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
