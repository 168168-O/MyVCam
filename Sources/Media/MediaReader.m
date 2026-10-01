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
#import <limits.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>
#import <time.h>
#import <unistd.h>

static const char kMyVCamDiagPrefix[] = "[MyVCam 0.2.9]";

static void MyVCamMediaReaderLogOpen(NSURL *sourceURL,
                                     NSURL *assetURL,
                                     BOOL openOK,
                                     int openErrno,
                                     BOOL copied,
                                     NSError * _Nullable readerError) {
    NSString *sourcePath = sourceURL.path ?: @"";
    NSString *assetPath = assetURL.path ?: @"";
    NSError *fileError = nil;
    NSDictionary *attrs = nil;
    if (assetPath.length > 0) {
        attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:assetPath error:&fileError];
    }
    unsigned long long size = attrs != nil ? [attrs fileSize] : 0;
    NSError *reported = readerError ?: fileError;
    NSLog(@"%s MediaReader open success=%d path=%s asset=%s copied=%d exists=%d size=%llu open_errno=%d error_domain=%@ error_code=%ld",
          kMyVCamDiagPrefix,
          openOK ? 1 : 0,
          sourcePath.UTF8String ?: "",
          assetPath.UTF8String ?: "",
          copied ? 1 : 0,
          attrs != nil ? 1 : 0,
          size,
          openErrno,
          reported.domain ?: @"-",
          (long)(reported != nil ? reported.code : 0));
}

/// AVAssetReader and VideoToolbox reopen the URL outside this process.
/// Dopamine's jbroot extension covers Camera's open(), not that service.
/// A file outside the container is copied, from the fd already opened, into
/// Library/MyVCam/playback.mp4. Same size and mtime skips the copy.
static BOOL MyVCamPathIsInsideHome(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    NSString *home = NSHomeDirectory();
    if (home.length == 0) {
        return NO;
    }
    NSString *prefix = [home hasSuffix:@"/"] ? home : [home stringByAppendingString:@"/"];
    if ([path hasPrefix:prefix] || [path isEqualToString:home]) {
        return YES;
    }
    if ([home hasPrefix:@"/private/"]) {
        NSString *shortHome = [home substringFromIndex:8];
        NSString *shortPrefix = [shortHome hasSuffix:@"/"] ? shortHome : [shortHome stringByAppendingString:@"/"];
        return shortHome.length > 1 && ([path hasPrefix:shortPrefix] || [path isEqualToString:shortHome]);
    }
    NSString *privateHome = [@"/private" stringByAppendingString:home];
    NSString *privatePrefix = [privateHome stringByAppendingString:@"/"];
    return [path hasPrefix:privatePrefix] || [path isEqualToString:privateHome];
}

static BOOL MyVCamDestMatchesSource(const char *destination, const struct stat *sourceInfo) {
    struct stat destInfo;
    if (destination == NULL || sourceInfo == NULL) {
        return NO;
    }
    if (stat(destination, &destInfo) != 0 || !S_ISREG(destInfo.st_mode)) {
        return NO;
    }
    return destInfo.st_size == sourceInfo->st_size && destInfo.st_mtime == sourceInfo->st_mtime;
}

static int MyVCamCopyFDToPath(int sourceFD, const char *destination, const struct stat *sourceInfo) {
    char temporary[PATH_MAX];
    char buffer[1 << 16];
    int output = -1;
    int wrote = 0;
    ssize_t count = 0;

    if (sourceFD < 0 || destination == NULL || sourceInfo == NULL) {
        return EINVAL;
    }
    if (MyVCamDestMatchesSource(destination, sourceInfo)) {
        return 0;
    }
    wrote = snprintf(temporary, sizeof(temporary), "%s.tmp", destination);
    if (wrote <= 0 || (size_t)wrote >= sizeof(temporary)) {
        return ENAMETOOLONG;
    }
    if (lseek(sourceFD, 0, SEEK_SET) < 0) {
        return errno != 0 ? errno : EIO;
    }
    output = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (output < 0) {
        return errno != 0 ? errno : EIO;
    }
    while ((count = read(sourceFD, buffer, sizeof(buffer))) > 0) {
        ssize_t written = 0;
        while (written < count) {
            ssize_t step = write(output, buffer + written, (size_t)(count - written));
            if (step < 0) {
                if (errno == EINTR) {
                    continue;
                }
                int writeErrno = errno != 0 ? errno : EIO;
                close(output);
                unlink(temporary);
                return writeErrno;
            }
            written += step;
        }
    }
    if (count < 0) {
        int readErrno = errno != 0 ? errno : EIO;
        close(output);
        unlink(temporary);
        return readErrno;
    }
    if (fsync(output) != 0) {
        int syncErrno = errno != 0 ? errno : EIO;
        close(output);
        unlink(temporary);
        return syncErrno;
    }
    struct timespec times[2];
    memset(times, 0, sizeof(times));
    times[0].tv_sec = sourceInfo->st_atime;
    times[1].tv_sec = sourceInfo->st_mtime;
    (void)futimens(output, times);
    if (close(output) != 0) {
        unlink(temporary);
        return errno != 0 ? errno : EIO;
    }
    if (rename(temporary, destination) != 0) {
        int renameErrno = errno != 0 ? errno : EIO;
        unlink(temporary);
        return renameErrno;
    }
    (void)chmod(destination, 0644);
    return 0;
}

/// Container URL when source is outside Camera's home. On failure returns
/// the original URL so prepare still attempts the path open() accepted.
static NSURL *MyVCamDecodeURL(NSURL *fileURL, int sourceFD, const struct stat *sourceInfo, BOOL *copiedOut, int *errnoOut) {
    NSString *path = fileURL.path;
    NSString *home = NSHomeDirectory();
    NSString *directory = nil;
    NSString *destination = nil;
    const char *destPath = NULL;
    int copyErrno = 0;

    if (copiedOut != NULL) {
        *copiedOut = NO;
    }
    if (errnoOut != NULL) {
        *errnoOut = 0;
    }
    if (fileURL == nil || MyVCamPathIsInsideHome(path) || sourceFD < 0 || home.length == 0) {
        return fileURL;
    }
    directory = [home stringByAppendingPathComponent:@"Library/MyVCam"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    destination = [directory stringByAppendingPathComponent:@"playback.mp4"];
    destPath = destination.fileSystemRepresentation;
    if (destPath == NULL) {
        return fileURL;
    }
    copyErrno = MyVCamCopyFDToPath(sourceFD, destPath, sourceInfo);
    struct stat destInfo;
    memset(&destInfo, 0, sizeof(destInfo));
    BOOL sizeOK = stat(destPath, &destInfo) == 0 && S_ISREG(destInfo.st_mode) &&
        destInfo.st_size == sourceInfo->st_size;
    if (copyErrno != 0 || !sizeOK) {
        if (errnoOut != NULL) {
            *errnoOut = copyErrno != 0 ? copyErrno : EIO;
        }
        NSLog(@"%s MediaReader container copy failed path=%s errno=%d",
              kMyVCamDiagPrefix,
              destPath,
              copyErrno != 0 ? copyErrno : EIO);
        return fileURL;
    }
    if (copiedOut != NULL) {
        *copiedOut = YES;
    }
    return [NSURL fileURLWithPath:destination isDirectory:NO];
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
    BOOL copied = NO;
    int copyErrno = 0;
    NSURL *assetURL = fileURL;
    if (statOK && S_ISREG(info.st_mode) && info.st_size > 0) {
        assetURL = MyVCamDecodeURL(fileURL, fd, &info, &copied, &copyErrno);
        if (copyErrno != 0) {
            openErrno = copyErrno;
        }
    }
    if (fd >= 0) {
        close(fd);
    }
    if (!statOK || !S_ISREG(info.st_mode) || info.st_size <= 0 || assetURL == nil) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeInvalidURL
                             description:@"Media file does not exist."
                              underlying:nil];
        }
        MyVCamMediaReaderLogOpen(fileURL, assetURL, NO, openErrno, copied, error != NULL ? *error : nil);
        return NO;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:nil];
    NSArray<AVAssetTrack *> *videoTracks = nil;
    if (![self loadVideoTracksForAsset:asset tracks:&videoTracks error:error]) {
        MyVCamMediaReaderLogOpen(fileURL, assetURL, NO, openErrno, copied, error != NULL ? *error : nil);
        return NO;
    }

    AVAssetTrack *track = videoTracks.firstObject;
    if (track == nil) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeNoVideoTrack
                             description:@"The file has no video track."
                              underlying:nil];
        }
        MyVCamMediaReaderLogOpen(fileURL, assetURL, NO, openErrno, copied, error != NULL ? *error : nil);
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

    // IOSurface first. VideoToolbox on iOS 15 refuses that request for some
    // files; the second attempt is CPU BGRA. The preview and the injector
    // copy into their own IOSurface buffers, so the stored frame can be CPU-only.
    NSArray<NSDictionary *> *settingsAttempts = @[
        @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: @YES,
        },
        @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        },
    ];
    NSError *readerError = nil;
    AVAssetReader *reader = nil;
    AVAssetReaderTrackOutput *output = nil;
    for (NSDictionary *settings in settingsAttempts) {
        if (reader != nil) {
            [reader cancelReading];
            reader = nil;
            output = nil;
        }
        reader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
        if (reader == nil) {
            continue;
        }
        output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
        output.alwaysCopiesSampleData = YES;
        // -addOutput: returns void on this SDK and throws if the output is refused.
        if (![reader canAddOutput:output]) {
            readerError = reader.error;
            [reader cancelReading];
            reader = nil;
            output = nil;
            continue;
        }
        [reader addOutput:output];
        if (![reader startReading]) {
            readerError = reader.error;
            [reader cancelReading];
            reader = nil;
            output = nil;
            continue;
        }
        break;
    }
    if (reader == nil || output == nil) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"AVAssetReader failed to start reading."
                              underlying:readerError];
        }
        MyVCamMediaReaderLogOpen(fileURL, assetURL, NO, openErrno, copied, error != NULL ? *error : readerError);
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
    MyVCamMediaReaderLogOpen(fileURL, assetURL, YES, 0, copied, nil);
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
        return NULL;
    }
    if (_reader.status != AVAssetReaderStatusReading) {
        [self recordNonReadingStatusOnReaderQueue];
        return NULL;
    }

    CMSampleBufferRef sampleBuffer = [_output copyNextSampleBuffer];
    if (sampleBuffer == NULL) {
        // NULL while status is still Reading is not the end of the track.
        // Treating it as end of media cancelled the feed before the first
        // frame of a large file, and the viewfinder stayed on the live camera.
        if (_reader.status == AVAssetReaderStatusReading) {
            _lastError = [self errorWithCode:MyVCamMediaReaderErrorCodeTryAgain
                                 description:@"AVAssetReader has no sample yet."
                                  underlying:nil];
            return NULL;
        }
        [self recordNonReadingStatusOnReaderQueue];
        if (_frameIndex == 0) {
            static BOOL loggedFirstMiss = NO;
            if (!loggedFirstMiss) {
                loggedFirstMiss = YES;
                NSLog(@"%s first frame read ok=0 path=%s",
                      kMyVCamDiagPrefix,
                      self.fileURL.path.UTF8String ?: "");
            }
        }
        return NULL;
    }

    CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer == NULL) {
        CFRelease(sampleBuffer);
        _lastError = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"Decoded sample did not contain a pixel buffer."
                              underlying:nil];
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
        NSLog(@"%s first frame read ok=1 path=%s",
              kMyVCamDiagPrefix,
              self.fileURL.path.UTF8String ?: "");
    }
    return retained;
}

@end

NS_ASSUME_NONNULL_END
