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
//  The state lock is the outer lock. It is not held across MediaReader or
//  AVFoundation calls. os_unfair_lock aborts if the same thread locks it
//  again, and Camera's startRunning path re-enters if a lock is held while
//  AVFoundation runs. Frame-source calls can take com.myvcam.reader; do not
//  call them while holding _stateLock.
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
- (void)releaseSource:(nullable id<MyVCamFrameSource>)source
             injector:(nullable VideoInjector *)injector;
- (BOOL)prepareFrameSource:(id<MyVCamFrameSource>)source
                     error:(NSError * _Nullable * _Nullable)error
                     epoch:(uint64_t *)epoch;
- (void)invalidateEpoch:(uint64_t)epoch onSource:(nullable id<MyVCamFrameSource>)source;
- (CMSampleBufferRef _Nullable)sampleBufferFromSource:(id<MyVCamFrameSource>)source
                                              builder:(SampleBufferBuilder *)builder
                                                error:(NSError * _Nullable * _Nullable)error
    CF_RETURNS_RETAINED;
- (void)installFeedTimerForGeneration:(uint64_t)generation;
- (void)feedTickForGeneration:(uint64_t)generation;
- (void)handleFeedEndOfMediaForGeneration:(uint64_t)generation;
- (void)stopFeedIfGeneration:(uint64_t)generation;
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
    BOOL _pauseFeed;
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
    _pauseFeed = NO;
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

- (void)releaseSource:(nullable id<MyVCamFrameSource>)source
             injector:(nullable VideoInjector *)injector {
    // Reader reset and injector stop take their own locks and can call back
    // into AVFoundation. The state lock is not held here.
    [source reset];
    [injector stop];
}

- (BOOL)prepareFrameSource:(id<MyVCamFrameSource>)source
                     error:(NSError * _Nullable * _Nullable)error
                     epoch:(uint64_t *)epoch {
    if (epoch != NULL) {
        *epoch = 0;
    }
    if ([source respondsToSelector:@selector(prepareWithError:publishedEpoch:)]) {
        return [source prepareWithError:error publishedEpoch:epoch];
    }
    return [source prepareWithError:error];
}

- (void)invalidateEpoch:(uint64_t)epoch onSource:(nullable id<MyVCamFrameSource>)source {
    if (epoch == 0 || source == nil) {
        return;
    }
    if ([source respondsToSelector:@selector(invalidatePublishedEpoch:)]) {
        [source invalidatePublishedEpoch:epoch];
    }
}

- (void)attachMediaFileURL:(nullable NSURL *)fileURL {
    os_unfair_lock_lock(&_stateLock);
    id<MyVCamFrameSource> retired = self.frameSource;
    VideoInjector *injector = self.videoInjector;
    if (fileURL == nil) {
        [self detachLocked];
        os_unfair_lock_unlock(&_stateLock);
        [self releaseSource:retired injector:injector];
        return;
    }
    [self cancelFeedTimerLocked];
    _reading = NO;
    _pauseFeed = NO;
    self.mediaFileURL = fileURL;
    self.frameSource = [[MediaReader alloc] initWithFileURL:fileURL];
    os_unfair_lock_unlock(&_stateLock);
    [self releaseSource:retired injector:injector];
}

- (void)detachMediaFile {
    os_unfair_lock_lock(&_stateLock);
    id<MyVCamFrameSource> retired = self.frameSource;
    VideoInjector *injector = self.videoInjector;
    [self detachLocked];
    os_unfair_lock_unlock(&_stateLock);
    [self releaseSource:retired injector:injector];
}

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error {
    os_unfair_lock_lock(&_stateLock);
    id<MyVCamFrameSource> source = self.frameSource;
    VideoInjector *injector = self.videoInjector;
    if (source == nil || self.mediaFileURL == nil) {
        _reading = NO;
        _pauseFeed = NO;
        [self cancelFeedTimerLocked];
        os_unfair_lock_unlock(&_stateLock);
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNoMedia,
                                        @"Attach a local media file URL before starting.",
                                        nil);
        }
        return NO;
    }

    // Drop any timer from a previous start before the slow prepare. cancel
    // bumps the generation this attempt captures.
    [self cancelFeedTimerLocked];
    _reading = NO;
    _pauseFeed = NO;
    uint64_t generation = _feedGeneration;
    os_unfair_lock_unlock(&_stateLock);

    NSError *prepareError = nil;
    uint64_t epoch = 0;
    BOOL prepared = [self prepareFrameSource:source error:&prepareError epoch:&epoch];

    os_unfair_lock_lock(&_stateLock);
    BOOL ownsAttempt = _feedGeneration == generation && self.frameSource == source;
    os_unfair_lock_unlock(&_stateLock);
    if (!ownsAttempt) {
        [self invalidateEpoch:epoch onSource:source];
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNotRunning,
                                        @"The feed stopped before its timer was armed.",
                                        nil);
        }
        return NO;
    }
    if (!prepared) {
        // This attempt still owns the injector. Drop any previous frame so the
        // delegate hook pass-throughs instead of substituting a stale buffer.
        // stop only releases _latest; it does not call AVFoundation.
        os_unfair_lock_lock(&_stateLock);
        if (_feedGeneration == generation && self.frameSource == source) {
            [injector stop];
        }
        os_unfair_lock_unlock(&_stateLock);
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodePrepareFailed,
                                        @"MediaReader did not open the file.",
                                        prepareError);
        }
        return NO;
    }

    NSError *injectorError = nil;
    BOOL injectorPrepared = [injector prepareWithError:&injectorError];
    os_unfair_lock_lock(&_stateLock);
    ownsAttempt = _feedGeneration == generation && self.frameSource == source;
    os_unfair_lock_unlock(&_stateLock);
    if (!ownsAttempt) {
        // A newer start or stop owns the injector. Do not stop it from here.
        [self invalidateEpoch:epoch onSource:source];
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNotRunning,
                                        @"The feed stopped before its timer was armed.",
                                        nil);
        }
        return NO;
    }
    if (!injectorPrepared) {
        [self invalidateEpoch:epoch onSource:source];
        os_unfair_lock_lock(&_stateLock);
        if (_feedGeneration == generation && self.frameSource == source) {
            [injector stop];
        }
        os_unfair_lock_unlock(&_stateLock);
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodePrepareFailed,
                                        @"VideoInjector did not prepare.",
                                        injectorError);
        }
        return NO;
    }

    os_unfair_lock_lock(&_stateLock);
    if (_feedGeneration != generation || self.frameSource != source) {
        os_unfair_lock_unlock(&_stateLock);
        [self invalidateEpoch:epoch onSource:source];
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNotRunning,
                                        @"The feed stopped before its timer was armed.",
                                        nil);
        }
        return NO;
    }
    _reading = YES;
    _pauseFeed = NO;
    _fedFrameSinceRewind = NO;
    _loggedFeedLoop = NO;
    if (error != NULL) {
        *error = nil;
    }
    os_unfair_lock_unlock(&_stateLock);

    [self installFeedTimerForGeneration:generation];

    // stop can win after the prepare lock is released. Do not report success
    // when that happened or when the timer could not be armed.
    os_unfair_lock_lock(&_stateLock);
    BOOL armed = _reading && _feedGeneration == generation && _feedTimer != nil && self.frameSource == source;
    os_unfair_lock_unlock(&_stateLock);
    if (!armed) {
        os_unfair_lock_lock(&_stateLock);
        BOOL stillOwns = _feedGeneration == generation && self.frameSource == source;
        if (stillOwns) {
            _reading = NO;
            [self cancelFeedTimerLocked];
            [injector stop];
        }
        os_unfair_lock_unlock(&_stateLock);
        [self invalidateEpoch:epoch onSource:source];
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
    id<MyVCamFrameSource> source = self.frameSource;
    VideoInjector *injector = self.videoInjector;
    [self stopLocked];
    os_unfair_lock_unlock(&_stateLock);
    [self releaseSource:source injector:injector];
}

- (CMSampleBufferRef _Nullable)sampleBufferFromSource:(id<MyVCamFrameSource>)source
                                              builder:(SampleBufferBuilder *)builder
                                                error:(NSError * _Nullable * _Nullable)error {
    if (source == nil || builder == nil) {
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
    CMSampleBufferRef sampleBuffer = [builder sampleBufferWithPixelBuffer:pixelBuffer
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

- (CMSampleBufferRef _Nullable)copyNextSampleBufferWithError:(NSError * _Nullable * _Nullable)error {
    os_unfair_lock_lock(&_stateLock);
    BOOL reading = _reading;
    id<MyVCamFrameSource> source = self.frameSource;
    SampleBufferBuilder *builder = self.sampleBufferBuilder;
    os_unfair_lock_unlock(&_stateLock);
    if (!reading) {
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNotRunning,
                                        @"Start the manager before copying sample buffers.",
                                        nil);
        }
        return NULL;
    }
    return [self sampleBufferFromSource:source builder:builder error:error];
}

- (BOOL)injectNextSampleBufferWithError:(NSError * _Nullable * _Nullable)error {
    os_unfair_lock_lock(&_stateLock);
    if (!_reading || _pauseFeed) {
        os_unfair_lock_unlock(&_stateLock);
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNotRunning,
                                        @"Start the manager before copying sample buffers.",
                                        nil);
        }
        return NO;
    }
    uint64_t generation = _feedGeneration;
    id<MyVCamFrameSource> source = self.frameSource;
    SampleBufferBuilder *builder = self.sampleBufferBuilder;
    VideoInjector *injector = self.videoInjector;
    os_unfair_lock_unlock(&_stateLock);

    NSError *produceError = nil;
    CMSampleBufferRef sampleBuffer = [self sampleBufferFromSource:source builder:builder error:&produceError];

    os_unfair_lock_lock(&_stateLock);
    BOOL current = _reading && !_pauseFeed && _feedGeneration == generation && self.frameSource == source;
    if (!current) {
        os_unfair_lock_unlock(&_stateLock);
        if (sampleBuffer != NULL) {
            CFRelease(sampleBuffer);
        }
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNotRunning,
                                        @"Start the manager before copying sample buffers.",
                                        nil);
        }
        return NO;
    }
    if (sampleBuffer == NULL) {
        os_unfair_lock_unlock(&_stateLock);
        if (error != NULL) {
            if (produceError == nil) {
                *error = MyVCamManagerError(MyVCamManagerErrorCodeEndOfMedia,
                                            @"The video track has ended.",
                                            nil);
            } else {
                *error = produceError;
            }
        }
        return NO;
    }

    // Commit under the state lock. inject only retains; stop cannot clear
    // _latest between the check and the retain. Decode stays outside the lock.
    NSError *injectError = nil;
    BOOL injected = [injector injectSampleBuffer:sampleBuffer error:&injectError];
    CFRelease(sampleBuffer);
    os_unfair_lock_unlock(&_stateLock);

    if (!injected) {
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeInjectFailed,
                                        @"VideoInjector did not accept the sample buffer.",
                                        injectError);
        }
        return NO;
    }
    if (error != NULL) {
        *error = nil;
    }
    return YES;
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

// Caller holds _stateLock. Does not call the frame source or the injector.
- (void)stopLocked {
    _reading = NO;
    _pauseFeed = NO;
    [self cancelFeedTimerLocked];
}

- (void)stopFeedIfGeneration:(uint64_t)generation {
    os_unfair_lock_lock(&_stateLock);
    if (_feedGeneration != generation) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    id<MyVCamFrameSource> source = self.frameSource;
    VideoInjector *injector = self.videoInjector;
    [self stopLocked];
    os_unfair_lock_unlock(&_stateLock);
    [self releaseSource:source injector:injector];
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
    BOOL active = _reading && !_pauseFeed && _feedGeneration == generation;
    os_unfair_lock_unlock(&_stateLock);
    if (!active) {
        return;
    }

    NSError *error = nil;
    if ([self injectNextSampleBufferWithError:&error]) {
        os_unfair_lock_lock(&_stateLock);
        if (_reading && _feedGeneration == generation) {
            _fedFrameSinceRewind = YES;
        }
        os_unfair_lock_unlock(&_stateLock);
        return;
    }

    os_unfair_lock_lock(&_stateLock);
    BOOL stale = !_reading || _pauseFeed || _feedGeneration != generation;
    os_unfair_lock_unlock(&_stateLock);
    if (stale || MyVCamManagerErrorIs(error, MyVCamManagerErrorCodeNotRunning)) {
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
// Prepare runs without _stateLock. Ticks are paused so they do not decode
// against a reader that is being reopened.
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
    _pauseFeed = YES;
    BOOL shouldLog = !_loggedFeedLoop;
    _loggedFeedLoop = YES;
    id<MyVCamFrameSource> source = self.frameSource;
    os_unfair_lock_unlock(&_stateLock);

    NSError *prepareError = nil;
    uint64_t epoch = 0;
    BOOL prepared = source != nil && [self prepareFrameSource:source error:&prepareError epoch:&epoch];

    os_unfair_lock_lock(&_stateLock);
    BOOL still = _reading && _feedGeneration == generation && self.frameSource == source;
    if (still && prepared) {
        _pauseFeed = NO;
    }
    os_unfair_lock_unlock(&_stateLock);

    if (!still) {
        [self invalidateEpoch:epoch onSource:source];
        return;
    }
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
