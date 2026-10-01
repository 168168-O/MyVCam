//
//  SampleBufferBuilder.m
//  MyVCam
//
//  Stage 2.2 conversion. CMVideoFormatDescriptionCreateForImageBuffer followed
//  by CMSampleBufferCreateForImageBuffer. No file I/O and no capture hooks.
//
//  LAYERING: do not import MediaReader.h, MyVCamManager.h, or VideoInjector.h.
//

#import "SampleBufferBuilder.h"

NS_ASSUME_NONNULL_BEGIN

NSString * const MyVCamSampleBufferBuilderErrorDomain = @"MyVCamSampleBufferBuilderErrorDomain";

static const int32_t kMyVCamFallbackFramesPerSecond = 30;

static NSError *MyVCamBuilderError(MyVCamSampleBufferBuilderErrorCode code, NSString *description, OSStatus status) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = description;
    if (status != noErr) {
        info[@"OSStatus"] = @(status);
    }
    return [NSError errorWithDomain:MyVCamSampleBufferBuilderErrorDomain code:code userInfo:info];
}

static CMTime MyVCamDurationOrFallback(CMTime duration) {
    if (CMTIME_IS_NUMERIC(duration) && CMTimeCompare(duration, kCMTimeZero) > 0) {
        return duration;
    }
    return CMTimeMake(1, kMyVCamFallbackFramesPerSecond);
}

@implementation SampleBufferBuilder

- (CMSampleBufferRef _Nullable)sampleBufferWithPixelBuffer:(CVPixelBufferRef _Nullable)pixelBuffer
                                          presentationTime:(CMTime)presentationTime
                                                  duration:(CMTime)duration
                                                     error:(NSError * _Nullable * _Nullable)error {
    if (pixelBuffer == NULL) {
        if (error != NULL) {
            *error = MyVCamBuilderError(MyVCamSampleBufferBuilderErrorCodeInvalidPixelBuffer,
                                        @"SampleBufferBuilder requires a CVPixelBuffer.",
                                        noErr);
        }
        return NULL;
    }
    if (!CMTIME_IS_NUMERIC(presentationTime)) {
        if (error != NULL) {
            *error = MyVCamBuilderError(MyVCamSampleBufferBuilderErrorCodeInvalidTiming,
                                        @"SampleBufferBuilder requires a numeric presentation time.",
                                        noErr);
        }
        return NULL;
    }

    CMVideoFormatDescriptionRef formatDescription = NULL;
    OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                          pixelBuffer,
                                                                          &formatDescription);
    if (formatStatus != noErr || formatDescription == NULL) {
        if (formatDescription != NULL) {
            CFRelease(formatDescription);
        }
        if (error != NULL) {
            *error = MyVCamBuilderError(MyVCamSampleBufferBuilderErrorCodeBuildFailed,
                                        @"Could not create a video format description for the pixel buffer.",
                                        formatStatus);
        }
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .duration = MyVCamDurationOrFallback(duration),
        .presentationTimeStamp = presentationTime,
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus sampleStatus = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                                                pixelBuffer,
                                                                YES,
                                                                NULL,
                                                                NULL,
                                                                formatDescription,
                                                                &timing,
                                                                &sampleBuffer);
    CFRelease(formatDescription);
    if (sampleStatus != noErr || sampleBuffer == NULL) {
        if (sampleBuffer != NULL) {
            CFRelease(sampleBuffer);
        }
        if (error != NULL) {
            *error = MyVCamBuilderError(MyVCamSampleBufferBuilderErrorCodeBuildFailed,
                                        @"Could not create a CMSampleBuffer for the pixel buffer.",
                                        sampleStatus);
        }
        return NULL;
    }

    // Callers that read the sample-attachment array without a NULL check need
    // the array to exist. The element is a mutable dictionary when CoreMedia
    // created it; any other type is left alone.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        CFTypeRef value = CFArrayGetValueAtIndex(attachments, 0);
        if (value != NULL && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
            CFDictionarySetValue((CFMutableDictionaryRef)value,
                                 kCMSampleAttachmentKey_DisplayImmediately,
                                 kCFBooleanTrue);
        }
    }

    if (error != NULL) {
        *error = nil;
    }
    return sampleBuffer;
}

@end

NS_ASSUME_NONNULL_END
