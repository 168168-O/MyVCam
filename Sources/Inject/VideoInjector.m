//
//  VideoInjector.m
//  MyVCam
//
//  Latest-buffer sink. No Substrate hooks, no AVFoundation swizzles, and no
//  mediaserverd / BWNodeOutput path.
//
//  prepareWithError: sets _prepared under the lock and returns YES. That is
//  not camera injection. injectSampleBuffer:error: rejects a call that is
//  not prepared, rejects a NULL buffer once prepared, and otherwise CFRetains
//  the buffer as _latest. Replacing _latest CFReleases the previous buffer
//  first. stop and dealloc CFRelease _latest. The caller's original retain
//  is not released here.
//
//  copyLatestSampleBufferMatchingOrigin: CFRetains _latest under _lock, then
//  builds a new image sample buffer outside the lock. The new buffer uses
//  the latest image buffer and the origin sample's timing. The stored
//  buffer and the origin buffer are not mutated. Create failure returns NULL.
//
//  Every read, replace, and release of _latest runs under _lock.
//
//  LAYERING: do not import MediaReader.h, SampleBufferBuilder.h, or
//  MyVCamManager.h. The restamp sequence below is the same CoreMedia pair
//  SampleBufferBuilder uses, written here so this file does not import it.
//
//  Later reference (not ported): DiCoy AVFoundation hooks.
//  Ethan mediaserverd injection stays deferred.
//

#import "VideoInjector.h"
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>

NS_ASSUME_NONNULL_BEGIN

NSString * const MyVCamVideoInjectorErrorDomain = @"MyVCamVideoInjectorErrorDomain";

static const int32_t kMyVCamInjectorFallbackFramesPerSecond = 30;

static CMTime MyVCamInjectorDurationOrFallback(CMTime duration) {
    if (CMTIME_IS_NUMERIC(duration) && CMTimeCompare(duration, kCMTimeZero) > 0) {
        return duration;
    }
    return CMTimeMake(1, kMyVCamInjectorFallbackFramesPerSecond);
}

static CMTime MyVCamInjectorPresentationTime(CMSampleBufferRef sampleBuffer) {
    CMTime presentationTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
    if (CMTIME_IS_NUMERIC(presentationTime)) {
        return presentationTime;
    }
    return CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
}

static CMTime MyVCamInjectorDuration(CMSampleBufferRef sampleBuffer) {
    CMTime duration = CMSampleBufferGetOutputDuration(sampleBuffer);
    if (CMTIME_IS_NUMERIC(duration) && CMTimeCompare(duration, kCMTimeZero) > 0) {
        return duration;
    }
    return MyVCamInjectorDurationOrFallback(CMSampleBufferGetDuration(sampleBuffer));
}

/// New image sample buffer (+1). Pixels from `latest`, timing from `origin`.
/// NULL when either buffer cannot supply what the create call needs.
static CMSampleBufferRef _Nullable MyVCamInjectorCreateMatchingOrigin(CMSampleBufferRef latest,
                                                                       CMSampleBufferRef origin) CF_RETURNS_RETAINED {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(latest);
    if (pixelBuffer == NULL) {
        return NULL;
    }

    CMTime presentationTime = MyVCamInjectorPresentationTime(origin);
    if (!CMTIME_IS_NUMERIC(presentationTime)) {
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
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .duration = MyVCamInjectorDuration(origin),
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
        return NULL;
    }
    return sampleBuffer;
}

@implementation VideoInjector {
    os_unfair_lock _lock;
    BOOL _prepared;
    CMSampleBufferRef _Nullable _latest;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _lock = OS_UNFAIR_LOCK_INIT;
    _prepared = NO;
    _latest = NULL;
    return self;
}

- (void)dealloc {
    os_unfair_lock_lock(&_lock);
    if (_latest != NULL) {
        CFRelease(_latest);
        _latest = NULL;
    }
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)prepareWithError:(NSError * _Nullable * _Nullable)error {
    os_unfair_lock_lock(&_lock);
    _prepared = YES;
    os_unfair_lock_unlock(&_lock);
    if (error != NULL) {
        *error = nil;
    }
    return YES;
}

- (BOOL)injectSampleBuffer:(CMSampleBufferRef _Nullable)sampleBuffer
                     error:(NSError * _Nullable * _Nullable)error {
    os_unfair_lock_lock(&_lock);
    if (!_prepared) {
        os_unfair_lock_unlock(&_lock);
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamVideoInjectorErrorCodeNotPrepared
                              description:@"VideoInjector is not prepared. Call prepareWithError: before injectSampleBuffer:error:."];
        }
        return NO;
    }

    if (sampleBuffer == NULL) {
        os_unfair_lock_unlock(&_lock);
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamVideoInjectorErrorCodeInvalidSampleBuffer
                              description:@"injectSampleBuffer:error: requires a non-NULL CMSampleBuffer."];
        }
        return NO;
    }

    // Own a retain separate from the caller's borrowed buffer. Release the
    // previous latest before the pointer is replaced so a repeat of the same
    // buffer cannot drop the new retain.
    CFRetain(sampleBuffer);
    if (_latest != NULL) {
        CFRelease(_latest);
    }
    _latest = sampleBuffer;
    os_unfair_lock_unlock(&_lock);

    if (error != NULL) {
        *error = nil;
    }
    return YES;
}

- (void)stop {
    os_unfair_lock_lock(&_lock);
    if (_latest != NULL) {
        CFRelease(_latest);
        _latest = NULL;
    }
    _prepared = NO;
    os_unfair_lock_unlock(&_lock);
}

- (CMSampleBufferRef _Nullable)copyLatestSampleBufferMatchingOrigin:(CMSampleBufferRef)origin {
    if (origin == NULL) {
        return NULL;
    }

    os_unfair_lock_lock(&_lock);
    CMSampleBufferRef latest = _latest;
    if (latest != NULL) {
        CFRetain(latest);
    }
    os_unfair_lock_unlock(&_lock);

    if (latest == NULL) {
        return NULL;
    }

    CMSampleBufferRef replacement = MyVCamInjectorCreateMatchingOrigin(latest, origin);
    CFRelease(latest);
    return replacement;
}

- (NSError *)errorWithCode:(MyVCamVideoInjectorErrorCode)code
               description:(NSString *)description {
    return [NSError errorWithDomain:MyVCamVideoInjectorErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey: description
    }];
}

@end

NS_ASSUME_NONNULL_END
