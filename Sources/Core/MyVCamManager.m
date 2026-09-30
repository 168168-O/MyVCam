//
//  MyVCamManager.m
//  MyVCam
//
//  Phase B wires MediaReader → SampleBufferBuilder, and wires
//  injectNextSampleBufferWithError: to VideoInjector.
//  copyNextSampleBufferWithError: stays a pure producer.
//
//  The state lock is the outer lock. copyNextSampleBufferLockedWithError:
//  assumes it is already held. The public copy method takes the lock, so
//  calling it from a method that already holds the lock deadlocks.
//  MediaReader and VideoInjector take their own locks and do not call back.
//
//  Phase A injectSampleBuffer:error: still returns NO. This file does not
//  turn that NO into YES.
//
//  Reference (structure only): DiCoyTweakManager owns the local reader.
//  Ethan mediaserverd injection is not part of this type.
//

#import "MyVCamManager.h"
#import "MediaReader.h"
#import <os/lock.h>

NS_ASSUME_NONNULL_BEGIN

NSString * const MyVCamManagerErrorDomain = @"MyVCamManagerErrorDomain";

@interface MyVCamManager ()
@property (nonatomic, strong, readwrite, nullable) id<MyVCamFrameSource> frameSource;
@property (nonatomic, copy, readwrite, nullable) NSURL *mediaFileURL;
- (void)detachLocked;
- (CMSampleBufferRef _Nullable)copyNextSampleBufferLockedWithError:(NSError * _Nullable * _Nullable)error
    CF_RETURNS_RETAINED;
@end

static NSError *MyVCamManagerError(MyVCamManagerErrorCode code, NSString *description, NSError * _Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = description;
    if (underlying != nil) {
        info[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:MyVCamManagerErrorDomain code:code userInfo:info];
}

@implementation MyVCamManager {
    os_unfair_lock _stateLock;
    BOOL _reading;
}

+ (instancetype)sharedManager {
    static MyVCamManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _stateLock = OS_UNFAIR_LOCK_INIT;
    _sampleBufferBuilder = [[SampleBufferBuilder alloc] init];
    _videoInjector = [[VideoInjector alloc] init];
    return self;
}

- (BOOL)isReading {
    os_unfair_lock_lock(&_stateLock);
    BOOL reading = _reading;
    os_unfair_lock_unlock(&_stateLock);
    return reading;
}

- (void)attachMediaFileURL:(nullable NSURL *)fileURL {
    os_unfair_lock_lock(&_stateLock);
    if (fileURL == nil) {
        [self detachLocked];
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    [self.frameSource reset];
    _reading = NO;
    [self.videoInjector stop];
    self.mediaFileURL = fileURL;
    self.frameSource = [[MediaReader alloc] initWithFileURL:fileURL];
    os_unfair_lock_unlock(&_stateLock);
}

- (void)detachMediaFile {
    os_unfair_lock_lock(&_stateLock);
    [self detachLocked];
    os_unfair_lock_unlock(&_stateLock);
}

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error {
    os_unfair_lock_lock(&_stateLock);
    id<MyVCamFrameSource> source = self.frameSource;
    if (source == nil || self.mediaFileURL == nil) {
        _reading = NO;
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNoMedia,
                                        @"Attach a local media file URL before starting.",
                                        nil);
        }
        os_unfair_lock_unlock(&_stateLock);
        return NO;
    }

    NSError *prepareError = nil;
    BOOL prepared = [source prepareWithError:&prepareError];
    if (!prepared) {
        _reading = NO;
        [self.videoInjector stop];
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodePrepareFailed,
                                        @"MediaReader did not open the file.",
                                        prepareError);
        }
        os_unfair_lock_unlock(&_stateLock);
        return NO;
    }

    NSError *injectorError = nil;
    BOOL injectorPrepared = [self.videoInjector prepareWithError:&injectorError];
    if (!injectorPrepared) {
        _reading = NO;
        [source reset];
        [self.videoInjector stop];
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodePrepareFailed,
                                        @"VideoInjector did not prepare.",
                                        injectorError);
        }
        os_unfair_lock_unlock(&_stateLock);
        return NO;
    }

    _reading = YES;
    if (error != NULL) {
        *error = nil;
    }
    os_unfair_lock_unlock(&_stateLock);
    return YES;
}

- (void)stop {
    os_unfair_lock_lock(&_stateLock);
    _reading = NO;
    [self.frameSource reset];
    [self.videoInjector stop];
    os_unfair_lock_unlock(&_stateLock);
}

- (CMSampleBufferRef _Nullable)copyNextSampleBufferWithError:(NSError * _Nullable * _Nullable)error {
    os_unfair_lock_lock(&_stateLock);
    CMSampleBufferRef sampleBuffer = [self copyNextSampleBufferLockedWithError:error];
    os_unfair_lock_unlock(&_stateLock);
    return sampleBuffer;
}

- (BOOL)injectNextSampleBufferWithError:(NSError * _Nullable * _Nullable)error {
    os_unfair_lock_lock(&_stateLock);
    NSError *produceError = nil;
    CMSampleBufferRef sampleBuffer = [self copyNextSampleBufferLockedWithError:&produceError];
    if (sampleBuffer == NULL) {
        if (error != NULL) {
            if (produceError == nil) {
                *error = MyVCamManagerError(MyVCamManagerErrorCodeEndOfMedia,
                                            @"The video track has ended.",
                                            nil);
            } else {
                *error = produceError;
            }
        }
        os_unfair_lock_unlock(&_stateLock);
        return NO;
    }

    NSError *injectError = nil;
    BOOL injected = [self.videoInjector injectSampleBuffer:sampleBuffer error:&injectError];
    // Producer retain. The injector borrowed the pointer and did not release it.
    CFRelease(sampleBuffer);

    if (!injected) {
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeInjectFailed,
                                        @"VideoInjector did not accept the sample buffer.",
                                        injectError);
        }
        os_unfair_lock_unlock(&_stateLock);
        return NO;
    }

    if (error != NULL) {
        *error = nil;
    }
    os_unfair_lock_unlock(&_stateLock);
    return YES;
}

// Caller holds _stateLock. Must not take _stateLock and must not call
// -copyNextSampleBufferWithError: (os_unfair_lock is not recursive).
- (CMSampleBufferRef _Nullable)copyNextSampleBufferLockedWithError:(NSError * _Nullable * _Nullable)error {
    if (!_reading) {
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNotRunning,
                                        @"Start the manager before copying sample buffers.",
                                        nil);
        }
        return NULL;
    }

    id<MyVCamFrameSource> source = self.frameSource;
    if (source == nil) {
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNoMedia,
                                        @"No frame source is attached.",
                                        nil);
        }
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = [source copyNextPixelBuffer];
    if (pixelBuffer == NULL) {
        // Protocol contract: nil lastError is end of media. Do not downcast.
        if (error != NULL) {
            *error = [source lastError];
        }
        return NULL;
    }

    CMTime presentationTime = [source presentationTimeOfLastFrame];
    CMTime duration = [source durationOfLastFrame];
    NSError *buildError = nil;
    CMSampleBufferRef sampleBuffer = [self.sampleBufferBuilder sampleBufferWithPixelBuffer:pixelBuffer
                                                                           presentationTime:presentationTime
                                                                                   duration:duration
                                                                                      error:&buildError];
    CVPixelBufferRelease(pixelBuffer);
    if (sampleBuffer == NULL && error != NULL) {
        *error = buildError;
    } else if (sampleBuffer != NULL && error != NULL) {
        *error = nil;
    }
    return sampleBuffer;
}

- (void)detachLocked {
    [self.frameSource reset];
    _reading = NO;
    [self.videoInjector stop];
    self.mediaFileURL = nil;
    self.frameSource = nil;
}

@end

NS_ASSUME_NONNULL_END
