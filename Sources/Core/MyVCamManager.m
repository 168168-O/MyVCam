//
//  MyVCamManager.m
//  MyVCam
//
//  Stage 2.2 wires MediaReader → SampleBufferBuilder.
//  VideoInjector is constructed and never called.
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
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodePrepareFailed,
                                        @"MediaReader did not open the file.",
                                        prepareError);
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
    os_unfair_lock_unlock(&_stateLock);
}

- (CMSampleBufferRef _Nullable)copyNextSampleBufferWithError:(NSError * _Nullable * _Nullable)error {
    os_unfair_lock_lock(&_stateLock);
    if (!_reading) {
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNotRunning,
                                        @"Start the manager before copying sample buffers.",
                                        nil);
        }
        os_unfair_lock_unlock(&_stateLock);
        return NULL;
    }

    id<MyVCamFrameSource> source = self.frameSource;
    if (source == nil) {
        if (error != NULL) {
            *error = MyVCamManagerError(MyVCamManagerErrorCodeNoMedia,
                                        @"No frame source is attached.",
                                        nil);
        }
        os_unfair_lock_unlock(&_stateLock);
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = [source copyNextPixelBuffer];
    if (pixelBuffer == NULL) {
        NSError *readerError = nil;
        if ([source isKindOfClass:[MediaReader class]]) {
            readerError = ((MediaReader *)source).lastError;
        }
        if (error != NULL) {
            *error = readerError;
        }
        os_unfair_lock_unlock(&_stateLock);
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
    os_unfair_lock_unlock(&_stateLock);
    return sampleBuffer;
}

- (void)detachLocked {
    [self.frameSource reset];
    _reading = NO;
    self.mediaFileURL = nil;
    self.frameSource = nil;
}

@end

NS_ASSUME_NONNULL_END
