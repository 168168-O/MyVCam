//
//  MediaReader.m
//  MyVCam
//
//  Stage 2.2 local-file decoder.
//
//  Opens one AVURLAsset and one AVAssetReaderTrackOutput for the first video
//  track, requesting 32BGRA. Each -copyNextPixelBuffer retains the image
//  buffer from the reader's CMSampleBuffer and releases that sample buffer.
//  It does not call CMSampleBufferCreateForImageBuffer.
//
//  Reader ivars are touched only on com.myvcam.reader. copyNextSampleBuffer
//  and cancelReading are never in flight together: the queue drains the copy
//  before the reader pointer is dropped, and cancelReading runs after that
//  queue block returns. The slow track load is not on that queue and does not
//  hold a lock. On the main thread the synchronous tracks API is used so a
//  completion handler cannot deadlock the thread that is waiting for it.
//  Off the main thread the load is started on a concurrent queue and the
//  caller waits on a semaphore, so a serial caller (com.myvcam.feed, during
//  loop) cannot block the queue the completion needs.
//
//  LAYERING: this file must not import SampleBufferBuilder.h or VideoInjector.h.
//
//  Adapted from the shape of DiCoy _setupVideoReaderForPath: (local file,
//  first video track, BGRA track output). alwaysCopiesSampleData is YES here
//  because the returned CVPixelBuffer must stay valid after the reader sample
//  buffer is released and after the next frame is decoded.
//

#import "MediaReader.h"
#import <AVFoundation/AVFoundation.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static const char kMyVCamDiagPrefix[] = "[MyVCam 0.2.12]";

static const char *MyVCamReaderStatusName(BOOL created, AVAssetReaderStatus status) {
    if (!created) {
        return "none";
    }
    switch (status) {
        case AVAssetReaderStatusUnknown:
            return "unknown";
        case AVAssetReaderStatusReading:
            return "reading";
        case AVAssetReaderStatusCompleted:
            return "completed";
        case AVAssetReaderStatusFailed:
            return "failed";
        case AVAssetReaderStatusCancelled:
            return "cancelled";
    }
    return "unknown";
}

static void MyVCamMediaReaderLogOpen(NSURL *fileURL,
                                     BOOL exists,
                                     BOOL assetCreated,
                                     BOOL readerCreated,
                                     AVAssetReaderStatus status,
                                     int openErrno,
                                     NSError * _Nullable readerError) {
    NSString *path = fileURL.path ?: @"";
    NSLog(@"%s MediaReader open path=%s exists=%d asset_create=%d reader_create=%d reader_status=%s open_errno=%d error_domain=%@ error_code=%ld",
          kMyVCamDiagPrefix,
          path.UTF8String ?: "",
          exists ? 1 : 0,
          assetCreated ? 1 : 0,
          readerCreated ? 1 : 0,
          MyVCamReaderStatusName(readerCreated, status),
          openErrno,
          readerError.domain ?: @"-",
          (long)(readerError != nil ? readerError.code : 0));
}

static void MyVCamLogFirstFrame(BOOL success, BOOL pixelBuffer) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"%s first frame success=%d pixelbuffer=%d",
              kMyVCamDiagPrefix,
              success ? 1 : 0,
              pixelBuffer ? 1 : 0);
    });
}

NS_ASSUME_NONNULL_BEGIN

NSString * const MyVCamMediaReaderErrorDomain = @"MyVCamMediaReaderErrorDomain";

static void * const kMyVCamReaderQueueKey = (void *)&kMyVCamReaderQueueKey;

@interface MediaReader ()
- (void)performOnReaderQueue:(dispatch_block_t)block;
- (BOOL)buildReaderForFileURL:(NSURL *)fileURL
                        asset:(AVURLAsset * _Nullable * _Nonnull)assetOut
                       reader:(AVAssetReader * _Nullable * _Nonnull)readerOut
                       output:(AVAssetReaderTrackOutput * _Nullable * _Nonnull)outputOut
              nominalDuration:(CMTime *)nominalOut
                        error:(NSError * _Nullable * _Nullable)error;
- (CVPixelBufferRef _Nullable)copyNextPixelBufferOnReaderQueue;
- (void)recordNonReadingStatusOnReaderQueue;
- (void)clearReaderFieldsOnReaderQueue;
@end

@implementation MediaReader {
    AVURLAsset *_asset;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
    dispatch_queue_t _readerQueue;
    CMTime _presentationTime;
    CMTime _duration;
    CMTime _nominalFrameDuration;
    int32_t _frameIndex;
    uint64_t _prepareGeneration;
    BOOL _prepared;
    NSError *_Nullable _lastError;
}

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _fileURL = [fileURL copy];
    _readerQueue = dispatch_queue_create("com.myvcam.reader", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_readerQueue, kMyVCamReaderQueueKey, kMyVCamReaderQueueKey, NULL);
    _presentationTime = kCMTimeInvalid;
    _duration = kCMTimeInvalid;
    _nominalFrameDuration = CMTimeMake(1, 30);
    return self;
}

- (void)dealloc {
    __block AVAssetReader *retired = nil;
    [self performOnReaderQueue:^{
        retired = _reader;
        [self clearReaderFieldsOnReaderQueue];
    }];
    [retired cancelReading];
}

- (void)performOnReaderQueue:(dispatch_block_t)block {
    if (dispatch_get_specific(kMyVCamReaderQueueKey) == kMyVCamReaderQueueKey) {
        block();
        return;
    }
    dispatch_sync(_readerQueue, block);
}

- (NSError *_Nullable)lastError {
    __block NSError *_Nullable error = nil;
    [self performOnReaderQueue:^{
        error = _lastError;
    }];
    return error;
}

- (NSError *)errorWithCode:(MyVCamMediaReaderErrorCode)code
               description:(NSString *)description
                underlying:(nullable NSError *)underlying {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = description;
    if (underlying != nil) {
        info[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:MyVCamMediaReaderErrorDomain code:code userInfo:info];
}

#pragma mark - MyVCamFrameSource

- (BOOL)prepareWithError:(NSError * _Nullable * _Nullable)error {
    return [self prepareWithError:error publishedEpoch:NULL];
}

- (BOOL)prepareWithError:(NSError * _Nullable * _Nullable)error
          publishedEpoch:(uint64_t * _Nullable)epochOut {
    if (epochOut != NULL) {
        *epochOut = 0;
    }

    __block uint64_t epoch = 0;
    __block AVAssetReader *retired = nil;
    [self performOnReaderQueue:^{
        epoch = ++_prepareGeneration;
        retired = _reader;
        [self clearReaderFieldsOnReaderQueue];
        _lastError = nil;
    }];
    // The queue block has finished, so no copyNextSampleBuffer is using this
    // reader. Cancel outside the queue: cancelReading can re-enter the caller.
    [retired cancelReading];

    AVURLAsset *asset = nil;
    AVAssetReader *reader = nil;
    AVAssetReaderTrackOutput *output = nil;
    CMTime nominal = CMTimeMake(1, 30);
    NSError *localError = nil;
    BOOL opened = NO;
    @try {
        opened = [self buildReaderForFileURL:self.fileURL
                                       asset:&asset
                                      reader:&reader
                                      output:&output
                             nominalDuration:&nominal
                                       error:&localError];
    } @catch (NSException *exception) {
        opened = NO;
        if (reader != nil) {
            [reader cancelReading];
            reader = nil;
        }
        localError = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"AVFoundation raised while opening the media file."
                              underlying:nil];
        NSLog(@"[MyVCam C1-C] reader exception %@", exception);
    }

    __block BOOL published = NO;
    [self performOnReaderQueue:^{
        if (_prepareGeneration != epoch) {
            // reset, invalidate, or a newer prepare owns the object.
            return;
        }
        if (!opened) {
            _lastError = localError;
            return;
        }
        _asset = asset;
        _reader = reader;
        _output = output;
        _nominalFrameDuration = nominal;
        _presentationTime = kCMTimeInvalid;
        _duration = kCMTimeInvalid;
        _frameIndex = 0;
        _prepared = YES;
        _lastError = nil;
        published = YES;
    }];

    if (!published && reader != nil) {
        [reader cancelReading];
    }
    if (!published) {
        if (error != NULL) {
            if (localError != nil) {
                *error = localError;
            } else {
                *error = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                                 description:@"MediaReader prepare was cancelled before the reader was published."
                                  underlying:nil];
            }
        }
        return NO;
    }
    if (epochOut != NULL) {
        *epochOut = epoch;
    }
    if (error != NULL) {
        *error = nil;
    }
    return YES;
}

- (void)invalidatePublishedEpoch:(uint64_t)epoch {
    if (epoch == 0) {
        return;
    }
    __block AVAssetReader *retired = nil;
    [self performOnReaderQueue:^{
        if (_prepareGeneration != epoch) {
            return;
        }
        retired = _reader;
        [self clearReaderFieldsOnReaderQueue];
        _prepareGeneration += 1;
        _lastError = nil;
    }];
    [retired cancelReading];
}

- (CVPixelBufferRef _Nullable)copyNextPixelBuffer {
    __block CVPixelBufferRef pixelBuffer = NULL;
    [self performOnReaderQueue:^{
        pixelBuffer = [self copyNextPixelBufferOnReaderQueue];
    }];
    return pixelBuffer;
}

- (CMTime)presentationTimeOfLastFrame {
    __block CMTime time = kCMTimeInvalid;
    [self performOnReaderQueue:^{
        time = _presentationTime;
    }];
    return time;
}

- (CMTime)durationOfLastFrame {
    __block CMTime time = kCMTimeInvalid;
    [self performOnReaderQueue:^{
        time = _duration;
    }];
    return time;
}

- (void)reset {
    __block AVAssetReader *retired = nil;
    [self performOnReaderQueue:^{
        _prepareGeneration += 1;
        retired = _reader;
        [self clearReaderFieldsOnReaderQueue];
        _lastError = nil;
    }];
    [retired cancelReading];
}

#pragma mark - Reader queue

- (void)clearReaderFieldsOnReaderQueue {
    _reader = nil;
    _output = nil;
    _asset = nil;
    _prepared = NO;
    _presentationTime = kCMTimeInvalid;
    _duration = kCMTimeInvalid;
    _nominalFrameDuration = CMTimeMake(1, 30);
    _frameIndex = 0;
}

- (BOOL)loadVideoTracksForAsset:(AVURLAsset *)asset
                         tracks:(NSArray<AVAssetTrack *> * _Nullable * _Nonnull)tracksOut
                          error:(NSError * _Nullable * _Nullable)error {
    // Waiting on the main thread for loadTracksWithMediaType's completion
    // deadlocks when that completion needs the main thread (Camera calls
    // startRunning there). The synchronous API does the load inline.
    if ([NSThread isMainThread]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
        if (tracksOut != NULL) {
            *tracksOut = tracks;
        }
        return YES;
    }

    // Start the load on a concurrent queue, then wait here. Waiting on
    // com.myvcam.feed during a loop must not block the queue the completion
    // needs. dispatch_async does not run the block on this thread.
    dispatch_semaphore_t tracksLoaded = dispatch_semaphore_create(0);
    __block NSArray<AVAssetTrack *> *videoTracks = nil;
    __block NSError *tracksError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [asset loadTracksWithMediaType:AVMediaTypeVideo
                     completionHandler:^(NSArray<AVAssetTrack *> *_Nullable tracks,
                                         NSError *_Nullable loadError) {
            videoTracks = tracks;
            tracksError = loadError;
            dispatch_semaphore_signal(tracksLoaded);
        }];
    });
    dispatch_semaphore_wait(tracksLoaded, DISPATCH_TIME_FOREVER);
    if (tracksError != nil) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"Could not load tracks for the media file."
                              underlying:tracksError];
        }
        return NO;
    }
    if (tracksOut != NULL) {
        *tracksOut = videoTracks;
    }
    return YES;
}

- (BOOL)buildReaderForFileURL:(NSURL *)fileURL
                        asset:(AVURLAsset * _Nullable * _Nonnull)assetOut
                       reader:(AVAssetReader * _Nullable * _Nonnull)readerOut
                       output:(AVAssetReaderTrackOutput * _Nullable * _Nonnull)outputOut
              nominalDuration:(CMTime *)nominalOut
                        error:(NSError * _Nullable * _Nullable)error {
    if (assetOut != NULL) {
        *assetOut = nil;
    }
    if (readerOut != NULL) {
        *readerOut = nil;
    }
    if (outputOut != NULL) {
        *outputOut = nil;
    }
    if (fileURL == nil || !fileURL.isFileURL || fileURL.path.length == 0) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeInvalidURL
                             description:@"MediaReader requires a local file URL."
                              underlying:nil];
        }
        MyVCamMediaReaderLogOpen(fileURL, NO, NO, NO, AVAssetReaderStatusUnknown, EINVAL, error != NULL ? *error : nil);
        return NO;
    }
    // fileExistsAtPath: is the same class of check as access(): a sandbox
    // denial is reported as "missing". open() is what the feed is allowed
    // to do, including Camera's container and the real jbroot path.
    const char *path = fileURL.path.fileSystemRepresentation;
    int fd = path != NULL ? open(path, O_RDONLY) : -1;
    int openErrno = fd >= 0 ? 0 : errno;
    struct stat info;
    memset(&info, 0, sizeof(info));
    int statOK = fd >= 0 && fstat(fd, &info) == 0;
    if (fd >= 0 && !statOK) {
        openErrno = errno;
    }
    if (fd >= 0) {
        close(fd);
    }
    if (!statOK || !S_ISREG(info.st_mode) || info.st_size <= 0) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeInvalidURL
                             description:@"Media file does not exist."
                              underlying:nil];
        }
        MyVCamMediaReaderLogOpen(fileURL, NO, NO, NO, AVAssetReaderStatusUnknown, openErrno, error != NULL ? *error : nil);
        return NO;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:nil];
    NSArray<AVAssetTrack *> *videoTracks = nil;
    if (![self loadVideoTracksForAsset:asset tracks:&videoTracks error:error]) {
        MyVCamMediaReaderLogOpen(fileURL, YES, YES, NO, AVAssetReaderStatusUnknown, openErrno, error != NULL ? *error : nil);
        return NO;
    }

    AVAssetTrack *track = videoTracks.firstObject;
    if (track == nil) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeNoVideoTrack
                             description:@"The file has no video track."
                              underlying:nil];
        }
        MyVCamMediaReaderLogOpen(fileURL, YES, YES, NO, AVAssetReaderStatusUnknown, openErrno, error != NULL ? *error : nil);
        return NO;
    }

    CMTime nominal = CMTimeMake(1, 30);
    float framesPerSecond = track.nominalFrameRate;
    if (framesPerSecond > 1.0f) {
        nominal = CMTimeMakeWithSeconds(1.0 / (Float64)framesPerSecond, 600);
    }
    if (nominalOut != NULL) {
        *nominalOut = nominal;
    }

    NSError *readerError = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
    if (reader == nil) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"AVAssetReader could not be created."
                              underlying:readerError];
        }
        MyVCamMediaReaderLogOpen(fileURL, YES, YES, NO, AVAssetReaderStatusUnknown, openErrno, error != NULL ? *error : readerError);
        return NO;
    }

    // IOSurface-backed buffers can be wrapped into a sample Camera will accept.
    // A CPU-only buffer is a common first-frame crash once it is substituted.
    // CoreAnimation compatibility is what AVSampleBufferDisplayLayer accepts.
    // A bare IOSurface can enqueue and still not composite over the preview.
    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: @YES,
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    AVAssetReaderTrackOutput *output =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = YES;
    // -addOutput: returns void on this SDK and throws if the output is refused.
    if (![reader canAddOutput:output]) {
        NSError *addError = reader.error;
        AVAssetReaderStatus addStatus = reader.status;
        [reader cancelReading];
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"Could not add the video track output to AVAssetReader."
                              underlying:addError];
        }
        MyVCamMediaReaderLogOpen(fileURL, YES, YES, YES, addStatus, openErrno, error != NULL ? *error : addError);
        return NO;
    }
    [reader addOutput:output];
    if (![reader startReading]) {
        NSError *startError = reader.error;
        AVAssetReaderStatus startStatus = reader.status;
        [reader cancelReading];
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"AVAssetReader failed to start reading."
                              underlying:startError];
        }
        MyVCamMediaReaderLogOpen(fileURL, YES, YES, YES, startStatus, openErrno, error != NULL ? *error : startError);
        return NO;
    }

    if (assetOut != NULL) {
        *assetOut = asset;
    }
    if (readerOut != NULL) {
        *readerOut = reader;
    }
    if (outputOut != NULL) {
        *outputOut = output;
    }
    MyVCamMediaReaderLogOpen(fileURL, YES, YES, YES, reader.status, 0, nil);
    return YES;
}

- (void)recordNonReadingStatusOnReaderQueue {
    AVAssetReaderStatus status = _reader.status;
    if (status == AVAssetReaderStatusCompleted) {
        _lastError = nil;
        return;
    }
    if (status == AVAssetReaderStatusFailed) {
        if (_lastError == nil) {
            _lastError = _reader.error ?: [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                                                  description:@"AVAssetReader failed while decoding."
                                                   underlying:nil];
        }
        return;
    }
    _lastError = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                         description:@"AVAssetReader stopped before the video track ended."
                          underlying:_reader.error];
}

- (CVPixelBufferRef _Nullable)copyNextPixelBufferOnReaderQueue {
    if (!_prepared || _reader == nil || _output == nil) {
        // NULL without an error would look like end of media.
        _lastError = [self errorWithCode:MyVCamMediaReaderErrorCodeNotPrepared
                             description:@"MediaReader is not prepared."
                              underlying:nil];
        MyVCamLogFirstFrame(NO, NO);
        return NULL;
    }
    if (_reader.status != AVAssetReaderStatusReading) {
        [self recordNonReadingStatusOnReaderQueue];
        MyVCamLogFirstFrame(NO, NO);
        return NULL;
    }

    CMSampleBufferRef sampleBuffer = [_output copyNextSampleBuffer];
    if (sampleBuffer == NULL) {
        if (_reader.status == AVAssetReaderStatusReading) {
            _lastError = nil;
        } else {
            [self recordNonReadingStatusOnReaderQueue];
        }
        MyVCamLogFirstFrame(NO, NO);
        return NULL;
    }

    CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer == NULL) {
        CFRelease(sampleBuffer);
        _lastError = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"Decoded sample did not contain a pixel buffer."
                              underlying:nil];
        MyVCamLogFirstFrame(NO, NO);
        return NULL;
    }

    CVPixelBufferRef retained = CVPixelBufferRetain(imageBuffer);
    CMTime presentationTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
    if (!CMTIME_IS_NUMERIC(presentationTime)) {
        presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    }
    CMTime duration = CMSampleBufferGetOutputDuration(sampleBuffer);
    if (!CMTIME_IS_NUMERIC(duration)) {
        duration = CMSampleBufferGetDuration(sampleBuffer);
    }
    if (!CMTIME_IS_NUMERIC(duration) || CMTimeCompare(duration, kCMTimeZero) <= 0) {
        duration = _nominalFrameDuration;
    }
    if (!CMTIME_IS_NUMERIC(presentationTime)) {
        presentationTime = CMTimeMultiply(_nominalFrameDuration, _frameIndex);
    }

    _presentationTime = presentationTime;
    _duration = duration;
    _frameIndex += 1;
    _lastError = nil;
    CFRelease(sampleBuffer);
    if (_frameIndex == 1) {
        MyVCamLogFirstFrame(YES, YES);
    }
    return retained;
}

@end

NS_ASSUME_NONNULL_END
