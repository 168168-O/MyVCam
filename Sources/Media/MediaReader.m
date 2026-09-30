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
//  LAYERING: this file must not import SampleBufferBuilder.h or VideoInjector.h.
//
//  Adapted from the shape of DiCoy _setupVideoReaderForPath: (local file,
//  first video track, BGRA track output). alwaysCopiesSampleData is YES here
//  because the returned CVPixelBuffer must stay valid after the reader sample
//  buffer is released and after the next frame is decoded.
//

#import "MediaReader.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

NS_ASSUME_NONNULL_BEGIN

NSString * const MyVCamMediaReaderErrorDomain = @"MyVCamMediaReaderErrorDomain";

@interface MediaReader ()
- (BOOL)prepareLockedWithError:(NSError * _Nullable * _Nullable)error;
- (CVPixelBufferRef _Nullable)copyNextPixelBufferLocked;
- (void)teardownLocked;
- (NSError *)errorWithCode:(MyVCamMediaReaderErrorCode)code
               description:(NSString *)description
                underlying:(nullable NSError *)underlying;
@end

@implementation MediaReader {
    AVURLAsset *_asset;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
    os_unfair_lock _lock;
    CMTime _presentationTime;
    CMTime _duration;
    CMTime _nominalFrameDuration;
    int32_t _frameIndex;
    BOOL _prepared;
}

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _fileURL = [fileURL copy];
    _lock = OS_UNFAIR_LOCK_INIT;
    _presentationTime = kCMTimeInvalid;
    _duration = kCMTimeInvalid;
    _nominalFrameDuration = CMTimeMake(1, 30);
    return self;
}

- (void)dealloc {
    os_unfair_lock_lock(&_lock);
    [_reader cancelReading];
    _reader = nil;
    _output = nil;
    _asset = nil;
    os_unfair_lock_unlock(&_lock);
}

- (NSError *)lastError {
    os_unfair_lock_lock(&_lock);
    NSError *error = _lastError;
    os_unfair_lock_unlock(&_lock);
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
    os_unfair_lock_lock(&_lock);
    [self teardownLocked];
    NSError *localError = nil;
    BOOL opened = [self prepareLockedWithError:&localError];
    if (!opened) {
        [self teardownLocked];
        _lastError = localError;
        if (error != NULL) {
            *error = localError;
        }
    } else {
        _prepared = YES;
        _lastError = nil;
        if (error != NULL) {
            *error = nil;
        }
    }
    os_unfair_lock_unlock(&_lock);
    return opened;
}

- (CVPixelBufferRef _Nullable)copyNextPixelBuffer {
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef pixelBuffer = [self copyNextPixelBufferLocked];
    os_unfair_lock_unlock(&_lock);
    return pixelBuffer;
}

- (CMTime)presentationTimeOfLastFrame {
    os_unfair_lock_lock(&_lock);
    CMTime time = _presentationTime;
    os_unfair_lock_unlock(&_lock);
    return time;
}

- (CMTime)durationOfLastFrame {
    os_unfair_lock_lock(&_lock);
    CMTime time = _duration;
    os_unfair_lock_unlock(&_lock);
    return time;
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    [self teardownLocked];
    _lastError = nil;
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Locked

- (void)teardownLocked {
    [_reader cancelReading];
    _reader = nil;
    _output = nil;
    _asset = nil;
    _prepared = NO;
    _presentationTime = kCMTimeInvalid;
    _duration = kCMTimeInvalid;
    _nominalFrameDuration = CMTimeMake(1, 30);
    _frameIndex = 0;
}

- (BOOL)prepareLockedWithError:(NSError * _Nullable * _Nullable)error {
    NSURL *fileURL = self.fileURL;
    if (fileURL == nil || !fileURL.isFileURL || fileURL.path.length == 0) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeInvalidURL
                             description:@"MediaReader requires a local file URL."
                              underlying:nil];
        }
        return NO;
    }
    BOOL isDirectory = NO;
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:fileURL.path
                                                            isDirectory:&isDirectory];
    if (!fileExists || isDirectory) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeInvalidURL
                             description:@"Media file does not exist."
                              underlying:nil];
        }
        return NO;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:nil];
    [asset loadValuesSynchronouslyForKeys:@[@"tracks"]];
    NSError *tracksError = nil;
    AVKeyValueStatus tracksStatus = [asset statusOfValueForKey:@"tracks" error:&tracksError];
    if (tracksStatus != AVKeyValueStatusLoaded) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"Could not load tracks for the media file."
                              underlying:tracksError];
        }
        return NO;
    }

    AVAssetTrack *track = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
#pragma clang diagnostic pop
    if (track == nil) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeNoVideoTrack
                             description:@"The file has no video track."
                              underlying:nil];
        }
        return NO;
    }

    float framesPerSecond = track.nominalFrameRate;
    if (framesPerSecond > 1.0f) {
        _nominalFrameDuration = CMTimeMakeWithSeconds(1.0 / (Float64)framesPerSecond, 600);
    } else {
        _nominalFrameDuration = CMTimeMake(1, 30);
    }

    NSError *readerError = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
    if (reader == nil) {
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"AVAssetReader could not be created."
                              underlying:readerError];
        }
        return NO;
    }

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    AVAssetReaderTrackOutput *output =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = YES;
    if (![reader addOutput:output]) {
        [reader cancelReading];
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"Could not add the video track output to AVAssetReader."
                              underlying:nil];
        }
        return NO;
    }
    if (![reader startReading]) {
        NSError *startError = reader.error;
        [reader cancelReading];
        if (error != NULL) {
            *error = [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                             description:@"AVAssetReader failed to start reading."
                              underlying:startError];
        }
        return NO;
    }

    _asset = asset;
    _reader = reader;
    _output = output;
    _presentationTime = kCMTimeInvalid;
    _duration = kCMTimeInvalid;
    _frameIndex = 0;
    return YES;
}

- (CVPixelBufferRef _Nullable)copyNextPixelBufferLocked {
    if (!_prepared || _reader == nil || _output == nil) {
        return NULL;
    }
    if (_reader.status != AVAssetReaderStatusReading) {
        if (_reader.status == AVAssetReaderStatusFailed && _lastError == nil) {
            _lastError = _reader.error ?: [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                                                  description:@"AVAssetReader failed while decoding."
                                                   underlying:nil];
        }
        return NULL;
    }

    CMSampleBufferRef sampleBuffer = [_output copyNextSampleBuffer];
    if (sampleBuffer == NULL) {
        if (_reader.status == AVAssetReaderStatusFailed) {
            _lastError = _reader.error ?: [self errorWithCode:MyVCamMediaReaderErrorCodeReaderFailed
                                                  description:@"AVAssetReader failed while decoding."
                                                   underlying:nil];
        } else {
            _lastError = nil;
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
    return retained;
}

@end

NS_ASSUME_NONNULL_END
