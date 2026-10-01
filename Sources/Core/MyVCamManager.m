//
//  MyVCamManager.m
//  MyVCam
//
//  Wires MediaReader → SampleBufferBuilder, and wires
//  injectNextSampleBufferWithError: to VideoInjector.
//  copyNextSampleBufferWithError: stays a pure producer.
//
//  C1-C adds a feed timer on the serial queue com.myvcam.feed. startWithError:
//  arms it after a successful prepare. Each tick calls injectNext. stop,
//  detach, attach, and a failed start cancel it. The capture delegate queue
//  is not this queue and this file does not hook it.
//
//  The state lock is the outer lock. copyNextSampleBufferLockedWithError:
//  assumes it is already held. The public copy method takes the lock, so
//  calling it from a method that already holds the lock deadlocks.
//  MediaReader and VideoInjector take their own locks and do not call back.
//
//  The feed timer is cancelled without waiting. Do not dispatch_sync onto
//  _feedQueue while holding _stateLock: a tick that needs the lock would
//  deadlock with that wait.
//
//  A NO from VideoInjector stays a NO. This file does not turn that into YES.
//
//  Reference (structure only): DiCoyTweakManager owns the local reader.
//  Ethan mediaserverd injection is not part of this type.
//

#import "MyVCamManager.h"
#import "MediaReader.h"
#import <os/lock.h>

NS_ASSUME_NONNULL_BEGIN

NSString * const MyVCamManagerErrorDomain = @"MyVCamManagerErrorDomain";

const char MyVCamManagerTestVideoPathUTF8[] = "/var/mobile/Documents/MyVCam/test.mp4";

static const char kMyVCamC1CPrefix[] = "[MyVCam C1-C]";
static const char kMyVCamFeedQueueLabel[] = "com.myvcam.feed";
static const int32_t kMyVCamFeedFramesPerSecond = 30;
static const uint64_t kMyVCamFeedIntervalNanoseconds = NSEC_PER_SEC / (uint64_t)kMyVCamFeedFramesPerSecond;
static const uint64_t kMyVCamFeedLeewayNanoseconds = 1 * NSEC_PER_MSEC;

@interface MyVCamManager ()
@property (nonatomic, strong, readwrite, nullable) id<MyVCamFrameSource> frameSource;
@property (nonatomic, copy, readwrite, nullable) NSURL *mediaFileURL;
- (void)detachLocked;
- (void)stopLocked;
- (void)cancelFeedTimerLocked;
- (void)installFeedTimerForGeneration:(uint64_t)generation;
- (void)feedTickForGeneration:(uint64_t)generation;
- (void)handleFeedEndOfMediaForGeneration:(uint64_t)generation;
- (void)stopFeedIfGeneration:(uint64_t)generation;
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

static BOOL MyVCamManagerErrorIs(NSError * _Nullable error, MyVCamManagerErrorCode code) {
    return error != nil &&
        [error.domain isEqualToString:MyVCamManagerErrorDomain] &&
        error.code == code;
}

@implementation MyVCamManager {
    os_unfair_lock _stateLock;
    BOOL _reading;
    dispatch_queue_t _feedQueue;
    dispatch_source_t _feedTimer;
    uint64_t _feedGeneration;
    BOOL _fedFrameSinceRewind;
    BOOL _loggedFeedLoop;
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
    _feedQueue = dispatch_queue_create(kMyVCamFeedQueueLabel, DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc {
    os_unfair_lock_lock(&_stateLock);
    dispatch_source_t timer = _feedTimer;
    _feedTimer = nil;
    _feedGeneration += 1;
    _reading = NO;
    os_unfair_lock_unlock(&_stateLock);
    if (timer != nil) {
        dispatch_source_cancel(timer);
    }
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
    [self cancelFeedTimerLocked];
    _reading = NO;
    [self.frameSource reset];
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
        [self cancelFeedTimerLocked];
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
        [self cancelFeedTimerLocked];
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
        [self cancelFeedTimerLocked];
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

    // Drop any timer from a previous start before publishing the generation
    // the new timer will capture. cancel bumps the generation.
    [self cancelFeedTimerLocked];
    _reading = YES;
    _fedFrameSinceRewind = NO;
    _loggedFeedLoop = NO;
    uint64_t generation = _feedGeneration;
    if (error != NULL) {
        *error = nil;
    }
    os_unfair_lock_unlock(&_stateLock);

    [self installFeedTimerForGeneration:generation];

    // stop can win after the prepare lock is released. Do not report success
    // when that happened or when the timer could not be armed.
    os_unfair_lock_lock(&_stateLock);
    BOOL armed = _reading && _feedGeneration == generation && _feedTimer != nil;
    os_unfair_lock_unlock(&_stateLock);
    if (!armed) {
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNotRunning,
                                        @"The feed stopped before its timer was armed.",
                                        nil);
        }
        return NO;
    }
    return YES;
}

- (void)stop {
    os_unfair_lock_lock(&_stateLock);
    [self stopLocked];
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
    [self stopLocked];
    self.mediaFileURL = nil;
    self.frameSource = nil;
}

// Caller holds _stateLock. Bumps the generation so a tick that already
// captured the old value cannot rewind or install another timer.
// dispatch_source_cancel does not wait for the handler, so it is safe to
// call while this lock is held. The handler takes the same lock.
- (void)cancelFeedTimerLocked {
    _feedGeneration += 1;
    dispatch_source_t timer = _feedTimer;
    _feedTimer = nil;
    if (timer != nil) {
        dispatch_source_cancel(timer);
    }
}

// Caller holds _stateLock.
- (void)stopLocked {
    _reading = NO;
    [self cancelFeedTimerLocked];
    [self.frameSource reset];
    [self.videoInjector stop];
}

- (void)stopFeedIfGeneration:(uint64_t)generation {
    os_unfair_lock_lock(&_stateLock);
    if (_feedGeneration != generation) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    [self stopLocked];
    os_unfair_lock_unlock(&_stateLock);
}

- (void)installFeedTimerForGeneration:(uint64_t)generation {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _feedQueue);
    if (timer == NULL) {
        NSLog(@"%s feed stopped: could not create timer", kMyVCamC1CPrefix);
        [self stopFeedIfGeneration:generation];
        return;
    }

    dispatch_source_set_timer(timer,
                              DISPATCH_TIME_NOW,
                              kMyVCamFeedIntervalNanoseconds,
                              kMyVCamFeedLeewayNanoseconds);
    __weak MyVCamManager *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        MyVCamManager *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf feedTickForGeneration:generation];
    });

    os_unfair_lock_lock(&_stateLock);
    if (!_reading || _feedGeneration != generation) {
        os_unfair_lock_unlock(&_stateLock);
        // A suspended source is not released until it is resumed.
        dispatch_resume(timer);
        dispatch_source_cancel(timer);
        return;
    }
    _feedTimer = timer;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_resume(timer);
    NSLog(@"%s feed timer started at %d fps", kMyVCamC1CPrefix, kMyVCamFeedFramesPerSecond);
}

// Runs on com.myvcam.feed. Does not run on the capture delegate queue.
- (void)feedTickForGeneration:(uint64_t)generation {
    os_unfair_lock_lock(&_stateLock);
    BOOL active = _reading && _feedGeneration == generation;
    os_unfair_lock_unlock(&_stateLock);
    if (!active) {
        return;
    }

    NSError *error = nil;
    if ([self injectNextSampleBufferWithError:&error]) {
        os_unfair_lock_lock(&_stateLock);
        if (_feedGeneration == generation) {
            _fedFrameSinceRewind = YES;
        }
        os_unfair_lock_unlock(&_stateLock);
        return;
    }

    if (MyVCamManagerErrorIs(error, MyVCamManagerErrorCodeNotRunning)) {
        return;
    }
    if (MyVCamManagerErrorIs(error, MyVCamManagerErrorCodeEndOfMedia)) {
        [self handleFeedEndOfMediaForGeneration:generation];
        return;
    }

    NSLog(@"%s feed stopped: %@", kMyVCamC1CPrefix, error);
    [self stopFeedIfGeneration:generation];
}

// End of file loops back to the start of the same file. The injector is
// left armed so the last stored frame stays available to the delegate hook
// until the next tick replaces it. A file that ends again before producing
// a frame stops the feed instead of reopening on every tick.
- (void)handleFeedEndOfMediaForGeneration:(uint64_t)generation {
    os_unfair_lock_lock(&_stateLock);
    if (!_reading || _feedGeneration != generation) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    if (!_fedFrameSinceRewind) {
        os_unfair_lock_unlock(&_stateLock);
        NSLog(@"%s feed stopped: media produced no frames", kMyVCamC1CPrefix);
        [self stopFeedIfGeneration:generation];
        return;
    }

    _fedFrameSinceRewind = NO;
    BOOL shouldLog = !_loggedFeedLoop;
    _loggedFeedLoop = YES;
    id<MyVCamFrameSource> source = self.frameSource;
    NSError *prepareError = nil;
    BOOL prepared = source != nil && [source prepareWithError:&prepareError];
    os_unfair_lock_unlock(&_stateLock);
    if (!prepared) {
        NSLog(@"%s feed stopped: could not loop (%@)", kMyVCamC1CPrefix, prepareError);
        [self stopFeedIfGeneration:generation];
        return;
    }
    if (shouldLog) {
        NSLog(@"%s end of media, looping", kMyVCamC1CPrefix);
    }
}

@end

NS_ASSUME_NONNULL_END
