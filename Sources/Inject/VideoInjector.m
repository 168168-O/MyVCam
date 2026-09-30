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
//  Every read, replace, and release of _latest runs under _lock.
//
//  LAYERING: do not import MediaReader.h, SampleBufferBuilder.h, or
//  MyVCamManager.h.
//
//  Later reference (not ported): DiCoy AVFoundation hooks.
//  Ethan mediaserverd injection stays deferred.
//

#import "VideoInjector.h"
#import <os/lock.h>

NS_ASSUME_NONNULL_BEGIN

NSString * const MyVCamVideoInjectorErrorDomain = @"MyVCamVideoInjectorErrorDomain";

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
