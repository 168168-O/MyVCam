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
//  pixels adapted to the origin image buffer (same width, height, and pixel
//  format) and the origin sample's timing. The stored buffer and the origin
//  buffer are not mutated. A non-video origin, or a format this process cannot
//  match safely, returns NULL so the caller keeps the camera buffer.
//
//  Every read, replace, and release of _latest runs under _lock. Pixel
//  conversion does not.
//
//  LAYERING: do not import MediaReader.h, SampleBufferBuilder.h, or
//  MyVCamManager.h. The restamp sequence below is the same CoreMedia pair
//  SampleBufferBuilder uses, written here so this file does not import it.
//
//  Later reference (not ported): DiCoy AVFoundation hooks.
//  Ethan mediaserverd injection stays deferred.
//

#import "VideoInjector.h"
#import <Accelerate/Accelerate.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>
#import <stdlib.h>

NS_ASSUME_NONNULL_BEGIN

NSString * const MyVCamVideoInjectorErrorDomain = @"MyVCamVideoInjectorErrorDomain";

static const int32_t kMyVCamInjectorFallbackFramesPerSecond = 30;
static const char kMyVCamC1BPrefix[] = "[MyVCam C1-B]";

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

static void MyVCamInjectorLogMatchFailureOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"%s replacement skipped: origin video format was not matched", kMyVCamC1BPrefix);
    });
}

static BOOL MyVCamInjectorFormatIsSupported(OSType format, size_t width, size_t height) {
    if (width == 0 || height == 0) {
        return NO;
    }
    switch (format) {
        case kCVPixelFormatType_32BGRA:
            return YES;
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return (width % 2u) == 0u && (height % 2u) == 0u;
        default:
            return NO;
    }
}

static CVPixelBufferRef _Nullable MyVCamInjectorCreatePixelBuffer(size_t width,
                                                                   size_t height,
                                                                   OSType format) CF_RETURNS_RETAINED {
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef buffer = NULL;
    CVReturn created = CVPixelBufferCreate(kCFAllocatorDefault,
                                            width,
                                            height,
                                            format,
                                            (__bridge CFDictionaryRef)attributes,
                                            &buffer);
    if (created != kCVReturnSuccess || buffer == NULL || CVPixelBufferGetIOSurface(buffer) == NULL) {
        // A non-IOSurface buffer is what Camera's preview path faults on.
        if (buffer != NULL) {
            CVPixelBufferRelease(buffer);
        }
        return NULL;
    }
    return buffer;
}

static BOOL MyVCamInjectorBufferHasAttachment(CVPixelBufferRef buffer, CFStringRef key) {
    CFTypeRef value = CVBufferCopyAttachment(buffer, key, NULL);
    if (value == NULL) {
        return NO;
    }
    CFRelease(value);
    return YES;
}

/// Camera rejects or crashes on a buffer whose YCbCr tags do not match the
/// capture buffer it was about to use. Copy the origin tags when they exist.
static void MyVCamInjectorApplyColorAttachments(CVPixelBufferRef origin, CVPixelBufferRef destination, OSType format) {
    CFStringRef keys[] = {
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocationBottomFieldKey,
    };
    for (size_t index = 0; index < sizeof(keys) / sizeof(keys[0]); index++) {
        // CopyAttachment is the iOS 15 replacement for CVBufferGetAttachment.
        CFTypeRef value = CVBufferCopyAttachment(origin, keys[index], NULL);
        if (value != NULL) {
            CVBufferSetAttachment(destination, keys[index], value, kCVAttachmentMode_ShouldPropagate);
            CFRelease(value);
        }
    }
    if (format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        return;
    }
    if (!MyVCamInjectorBufferHasAttachment(destination, kCVImageBufferYCbCrMatrixKey)) {
        CVBufferSetAttachment(destination,
                              kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
    }
    if (!MyVCamInjectorBufferHasAttachment(destination, kCVImageBufferColorPrimariesKey)) {
        CVBufferSetAttachment(destination,
                              kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
    }
    if (!MyVCamInjectorBufferHasAttachment(destination, kCVImageBufferTransferFunctionKey)) {
        CVBufferSetAttachment(destination,
                              kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
    }
}

static vImage_Buffer MyVCamInjectorPlane(CVPixelBufferRef buffer, size_t plane) {
    vImage_Buffer image = {
        .data = CVPixelBufferGetBaseAddressOfPlane(buffer, plane),
        .height = (vImagePixelCount)CVPixelBufferGetHeightOfPlane(buffer, plane),
        .width = (vImagePixelCount)CVPixelBufferGetWidthOfPlane(buffer, plane),
        .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane),
    };
    return image;
}

static vImage_Buffer MyVCamInjectorBGRAView(CVPixelBufferRef buffer) {
    vImage_Buffer image = {
        .data = CVPixelBufferGetBaseAddress(buffer),
        .height = (vImagePixelCount)CVPixelBufferGetHeight(buffer),
        .width = (vImagePixelCount)CVPixelBufferGetWidth(buffer),
        .rowBytes = CVPixelBufferGetBytesPerRow(buffer),
    };
    return image;
}

static BOOL MyVCamInjectorCopyBGRA(const vImage_Buffer *source, CVPixelBufferRef destination) {
    vImage_Buffer dest = MyVCamInjectorBGRAView(destination);
    if (source->data == NULL || dest.data == NULL || dest.width == 0 || dest.height == 0) {
        return NO;
    }
    if (source->width == dest.width && source->height == dest.height && source->rowBytes == dest.rowBytes) {
        memcpy(dest.data, source->data, source->rowBytes * (size_t)source->height);
        return YES;
    }
    if (source->width == dest.width && source->height == dest.height) {
        return vImageCopyBuffer(source, &dest, 4, kvImageNoFlags) == kvImageNoError;
    }
    return vImageScale_ARGB8888(source, &dest, NULL, kvImageNoFlags) == kvImageNoError;
}

static BOOL MyVCamInjectorConvertBGRAToBiplanar(const vImage_Buffer *source,
                                                 CVPixelBufferRef destination,
                                                 BOOL fullRange) {
    if (CVPixelBufferGetPlaneCount(destination) < 2) {
        return NO;
    }
    vImage_Buffer luma = MyVCamInjectorPlane(destination, 0);
    vImage_Buffer chroma = MyVCamInjectorPlane(destination, 1);
    if (source->data == NULL || luma.data == NULL || chroma.data == NULL) {
        return NO;
    }
    // 4:2:0 chroma is half the luma size. A mismatch would write off the end of the plane.
    if (luma.width < 2 || luma.height < 2 || chroma.width * 2 != luma.width || chroma.height * 2 != luma.height) {
        return NO;
    }

    vImage_YpCbCrPixelRange range;
    if (fullRange) {
        // YpMin is 1, matching the full-range range vImage uses for 8-bit 4:2:0.
        range = (vImage_YpCbCrPixelRange){
            .Yp_bias = 0,
            .CbCr_bias = 128,
            .YpRangeMax = 255,
            .CbCrRangeMax = 255,
            .YpMax = 255,
            .YpMin = 1,
            .CbCrMax = 255,
            .CbCrMin = 0,
        };
    } else {
        range = (vImage_YpCbCrPixelRange){
            .Yp_bias = 16,
            .CbCr_bias = 128,
            .YpRangeMax = 235,
            .CbCrRangeMax = 240,
            .YpMax = 235,
            .YpMin = 16,
            .CbCrMax = 240,
            .CbCrMin = 16,
        };
    }

    vImage_ARGBToYpCbCr conversion;
    vImage_Error generated = vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2,
                                                                            &range,
                                                                            &conversion,
                                                                            kvImageARGB8888,
                                                                            kvImage420Yp8_CbCr8,
                                                                            kvImageNoFlags);
    if (generated != kvImageNoError) {
        return NO;
    }

    const vImage_Buffer *converted = source;
    vImage_Buffer scaled = {0};
    BOOL ownsScaled = NO;
    if (source->width != luma.width || source->height != luma.height) {
        vImage_Error allocated = vImageBuffer_Init(&scaled, luma.height, luma.width, 32, kvImageNoFlags);
        if (allocated != kvImageNoError || scaled.data == NULL) {
            return NO;
        }
        ownsScaled = YES;
        if (vImageScale_ARGB8888(source, &scaled, NULL, kvImageNoFlags) != kvImageNoError) {
            free(scaled.data);
            return NO;
        }
        converted = &scaled;
    }

    // Little-endian kvImageARGB8888 is the same byte order as kCVPixelFormatType_32BGRA.
    vImage_Error convertedError = vImageConvert_ARGB8888To420Yp8_CbCr8(converted,
                                                                        &luma,
                                                                        &chroma,
                                                                        &conversion,
                                                                        NULL,
                                                                        kvImageNoFlags);
    if (ownsScaled) {
        free(scaled.data);
    }
    return convertedError == kvImageNoError;
}

/// New IOSurface-backed buffer (+1) whose dimensions and pixel format match origin.
static CVPixelBufferRef _Nullable MyVCamInjectorCopyPixelsMatchingOrigin(CVPixelBufferRef source,
                                                                          CVPixelBufferRef origin) CF_RETURNS_RETAINED {
    if (source == NULL || origin == NULL) {
        return NULL;
    }
    if (CVPixelBufferGetPixelFormatType(source) != kCVPixelFormatType_32BGRA) {
        return NULL;
    }
    OSType format = CVPixelBufferGetPixelFormatType(origin);
    size_t width = CVPixelBufferGetWidth(origin);
    size_t height = CVPixelBufferGetHeight(origin);
    if (!MyVCamInjectorFormatIsSupported(format, width, height)) {
        return NULL;
    }

    CVPixelBufferRef destination = MyVCamInjectorCreatePixelBuffer(width, height, format);
    if (destination == NULL) {
        return NULL;
    }
    MyVCamInjectorApplyColorAttachments(origin, destination, format);

    CVReturn sourceLock = CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVReturn destinationLock = CVPixelBufferLockBaseAddress(destination, 0);
    BOOL filled = NO;
    if (sourceLock == kCVReturnSuccess && destinationLock == kCVReturnSuccess) {
        vImage_Buffer sourceView = MyVCamInjectorBGRAView(source);
        if (format == kCVPixelFormatType_32BGRA) {
            filled = MyVCamInjectorCopyBGRA(&sourceView, destination);
        } else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            filled = MyVCamInjectorConvertBGRAToBiplanar(&sourceView, destination, YES);
        } else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            filled = MyVCamInjectorConvertBGRAToBiplanar(&sourceView, destination, NO);
        }
    }
    if (destinationLock == kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(destination, 0);
    }
    if (sourceLock == kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    }
    if (!filled) {
        CVPixelBufferRelease(destination);
        return NULL;
    }
    return destination;
}

/// New image sample buffer (+1). Caller owns pixelBuffer; this retains it for the sample.
static CMSampleBufferRef _Nullable MyVCamInjectorCreateSample(CVPixelBufferRef pixelBuffer,
                                                               CMTime presentationTime,
                                                               CMTime duration) CF_RETURNS_RETAINED {
    if (pixelBuffer == NULL || !CMTIME_IS_NUMERIC(presentationTime)) {
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
        .duration = MyVCamInjectorDurationOrFallback(duration),
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

    // Capture clients read sample attachments without a NULL check. Creating
    // the array here, and marking the frame display-immediately, matches what
    // a live video data output buffer has.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dictionary = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        if (dictionary != NULL) {
            CFDictionarySetValue(dictionary, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
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
    if (origin == NULL || !CMSampleBufferIsValid(origin)) {
        return NULL;
    }
    CVPixelBufferRef originPixels = CMSampleBufferGetImageBuffer(origin);
    CMFormatDescriptionRef originFormat = CMSampleBufferGetFormatDescription(origin);
    if (originPixels == NULL || originFormat == NULL ||
        CMFormatDescriptionGetMediaType(originFormat) != kCMMediaType_Video) {
        return NULL;
    }

    CMTime presentationTime = MyVCamInjectorPresentationTime(origin);
    if (!CMTIME_IS_NUMERIC(presentationTime)) {
        return NULL;
    }
    CMTime duration = MyVCamInjectorDuration(origin);

    os_unfair_lock_lock(&_lock);
    CMSampleBufferRef latest = _latest;
    if (latest != NULL) {
        CFRetain(latest);
    }
    os_unfair_lock_unlock(&_lock);
    if (latest == NULL) {
        return NULL;
    }

    CVPixelBufferRef sourcePixels = CMSampleBufferGetImageBuffer(latest);
    if (sourcePixels != NULL) {
        CVPixelBufferRetain(sourcePixels);
    }
    CFRelease(latest);
    if (sourcePixels == NULL) {
        MyVCamInjectorLogMatchFailureOnce();
        return NULL;
    }

    CVPixelBufferRef matched = MyVCamInjectorCopyPixelsMatchingOrigin(sourcePixels, originPixels);
    CVPixelBufferRelease(sourcePixels);
    if (matched == NULL) {
        MyVCamInjectorLogMatchFailureOnce();
        return NULL;
    }

    CMSampleBufferRef replacement = MyVCamInjectorCreateSample(matched, presentationTime, duration);
    CVPixelBufferRelease(matched);
    if (replacement == NULL) {
        MyVCamInjectorLogMatchFailureOnce();
    }
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
