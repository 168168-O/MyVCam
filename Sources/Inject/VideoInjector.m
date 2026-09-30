//
//  VideoInjector.m
//  MyVCam
//
//  Phase A local arming. No Substrate hooks, no AVFoundation swizzles, no
//  mediaserverd / BWNodeOutput path, and no sample-buffer sink.
//
//  prepareWithError: sets _prepared under the lock and returns YES. That is
//  not camera injection. injectSampleBuffer:error: reads the flag, rejects a
//  NULL buffer, and otherwise returns NotImplemented. The buffer is borrowed.
//  stop clears the flag and may be called again.
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
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _lock = OS_UNFAIR_LOCK_INIT;
    _prepared = NO;
    return self;
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
    BOOL prepared = _prepared;
    os_unfair_lock_unlock(&_lock);

    if (!prepared) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamVideoInjectorErrorCodeNotPrepared
                              description:@"VideoInjector is not prepared. Call prepareWithError: before injectSampleBuffer:error:."];
        }
        return NO;
    }

    if (sampleBuffer == NULL) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamVideoInjectorErrorCodeInvalidSampleBuffer
                              description:@"injectSampleBuffer:error: requires a non-NULL CMSampleBuffer."];
        }
        return NO;
    }

    // Borrowed pointer. Do not CFRetain or CFRelease. No sink exists yet.
    if (error != NULL) {
        *error = [self errorWithCode:MyVCamVideoInjectorErrorCodeNotImplemented
                          description:@"VideoInjector is armed locally and has no injection sink. The sample buffer was not delivered."];
    }
    return NO;
}

- (void)stop {
    os_unfair_lock_lock(&_lock);
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
