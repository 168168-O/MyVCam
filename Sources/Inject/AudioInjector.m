//
//  AudioInjector.m
//  MyVCam
//
//  Decodes one audio track to 16-bit interleaved PCM shaped like the camera
//  microphone, keeps it in memory, and serves replacement sample buffers.
//
//  Threading:
//  - copySampleBufferMatchingOrigin: runs on the capture delegate queue.
//    It never touches AVFoundation. It only reads _pcm under _lock, copies
//    out one buffer's worth of bytes, and builds the CoreMedia objects.
//  - prepareWithASBD:... runs on com.myvcam.audio.prepare. AVAssetReader is
//    created and drained there, never on the capture queue.
//  - _lock guards the ivars below. It is not held across AVFoundation calls
//    and not held while CMSampleBufferCreateReady runs.
//
//  A generation counter invalidates an in-flight decode when the source
//  changes. A stale result is discarded instead of replacing newer PCM.
//

#import "AudioInjector.h"

#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>
#import <stdlib.h>
#import <string.h>

static const char kMyVCamAudioPrefix[] = "[MyVCam Audio]";
// ~2 minutes of 48 kHz stereo 16-bit. Longer tracks are cut here, then looped.
static const NSUInteger kMyVCamAudioMaxBytes = 24u * 1024u * 1024u;
// Below this the file is treated as having no usable audio.
static const NSUInteger kMyVCamAudioMinFrames = 2048;

#pragma mark - Format helpers

static size_t MyVCamAudioBytesPerFrame(const AudioStreamBasicDescription *asbd) {
    if (asbd == NULL) {
        return 0;
    }
    if (asbd->mBytesPerFrame != 0) {
        return (size_t)asbd->mBytesPerFrame;
    }
    size_t sampleBytes = (size_t)(asbd->mBitsPerChannel / 8u);
    return sampleBytes * (size_t)asbd->mChannelsPerFrame;
}

static BOOL MyVCamAudioFormatIsReplacable(const AudioStreamBasicDescription *asbd) {
    if (asbd == NULL) {
        return NO;
    }
    if (asbd->mFormatID != kAudioFormatLinearPCM) {
        return NO;
    }
    if ((asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0) {
        return NO;
    }
    if ((asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0) {
        return NO;
    }
    if ((asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) {
        return NO;
    }
    if (asbd->mBitsPerChannel != 16 && asbd->mBitsPerChannel != 32) {
        return NO;
    }
    if (asbd->mChannelsPerFrame != 1 && asbd->mChannelsPerFrame != 2) {
        return NO;
    }
    if (!(asbd->mSampleRate > 8000.0 && asbd->mSampleRate < 192000.0)) {
        return NO;
    }
    return YES;
}

static BOOL MyVCamAudioFormatMatches(const AudioStreamBasicDescription *a,
                                     const AudioStreamBasicDescription *b) {
    if (a == NULL || b == NULL) {
        return NO;
    }
    // The receiver always uses the origin's format description, so only the
    // byte layout the decoder was asked for has to agree.
    return a->mSampleRate == b->mSampleRate &&
           a->mChannelsPerFrame == b->mChannelsPerFrame &&
           a->mBitsPerChannel == b->mBitsPerChannel &&
           a->mBytesPerFrame == b->mBytesPerFrame;
}

/// File path, size, and mtime. Re-picking the same name with new content must
/// invalidate the decoded PCM.
static NSString *MyVCamAudioFingerprint(NSURL *url) {
    if (url == nil || url.path.length == 0) {
        return nil;
    }
    NSDictionary *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:NULL];
    if (attributes == nil) {
        return nil;
    }
    unsigned long long size = [attributes fileSize];
    NSTimeInterval modified = [attributes.fileModificationDate timeIntervalSince1970];
    return [NSString stringWithFormat:@"%@|%llu|%.0f", url.path, size, modified];
}

static CMTime MyVCamAudioPresentationTime(CMSampleBufferRef origin) {
    CMTime time = CMSampleBufferGetOutputPresentationTimeStamp(origin);
    if (CMTIME_IS_NUMERIC(time)) {
        return time;
    }
    return CMSampleBufferGetPresentationTimeStamp(origin);
}

static CMTime MyVCamAudioDuration(CMSampleBufferRef origin) {
    CMTime duration = CMSampleBufferGetOutputDuration(origin);
    if (CMTIME_IS_NUMERIC(duration) && CMTimeCompare(duration, kCMTimeZero) > 0) {
        return duration;
    }
    duration = CMSampleBufferGetDuration(origin);
    if (CMTIME_IS_NUMERIC(duration) && CMTimeCompare(duration, kCMTimeZero) > 0) {
        return duration;
    }
    return kCMTimeInvalid;
}

#pragma mark - AudioInjector

@implementation AudioInjector {
    os_unfair_lock _lock;
    dispatch_queue_t _prepareQueue;

    // Source selection.
    NSURL *_sidecarURL;
    NSURL *_videoURL;
    NSString *_fingerprint;
    NSUInteger _generation;

    // Decoded PCM. All reads and writes happen under _lock.
    NSData *_pcm;
    AudioStreamBasicDescription _asbd;
    size_t _bytesPerFrame;
    NSUInteger _cursorBytes;
    BOOL _ready;
    // Format currently being decoded, and the generation that failed, so a
    // file without an audio track is not re-decoded on every callback.
    NSUInteger _preparingGeneration;
    NSUInteger _failedGeneration;

    // Diagnostics, written only from the prepare queue.
    NSString *_sourcePath;
    BOOL _loggedReplace;
    BOOL _loggedPassThrough;
    BOOL _loggedFormatSkip;
    BOOL _loggedNoTrack;
}

+ (instancetype)sharedInjector {
    static AudioInjector *injector = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        injector = [[AudioInjector alloc] init];
    });
    return injector;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _lock = OS_UNFAIR_LOCK_INIT;
    _prepareQueue = dispatch_queue_create("com.myvcam.audio.prepare", DISPATCH_QUEUE_SERIAL);
    _asbd = (AudioStreamBasicDescription){0};
    return self;
}

- (void)dealloc {
    _pcm = nil;
}

#pragma mark - Public

- (void)setSidecarURL:(NSURL *)sidecarURL videoURL:(NSURL *)videoURL {
    NSURL *sidecarExists = nil;
    if (sidecarURL != nil &&
        [[NSFileManager defaultManager] fileExistsAtPath:sidecarURL.path]) {
        sidecarExists = sidecarURL;
    }
    NSURL *resolved = sidecarExists != nil ? sidecarExists : videoURL;
    NSString *fingerprint = MyVCamAudioFingerprint(resolved);
    if (fingerprint == nil) {
        [self reset];
        return;
    }

    os_unfair_lock_lock(&_lock);
    BOOL unchanged = _fingerprint != nil && [_fingerprint isEqualToString:fingerprint];
    if (!unchanged) {
        _sidecarURL = sidecarExists;
        _videoURL = videoURL;
        _fingerprint = fingerprint;
        _generation += 1;
        _pcm = nil;
        _bytesPerFrame = 0;
        _cursorBytes = 0;
        _ready = NO;
        _preparingGeneration = 0;
        _failedGeneration = 0;
        _asbd = (AudioStreamBasicDescription){0};
    }
    os_unfair_lock_unlock(&_lock);

    if (!unchanged) {
        NSLog(@"%s source set path=%s sidecar=%d",
              kMyVCamAudioPrefix,
              resolved.path.UTF8String ?: "",
              sidecarExists != nil ? 1 : 0);
    }
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    _sidecarURL = nil;
    _videoURL = nil;
    _fingerprint = nil;
    _generation += 1;
    _pcm = nil;
    _bytesPerFrame = 0;
    _cursorBytes = 0;
    _ready = NO;
    _preparingGeneration = 0;
    _failedGeneration = 0;
    _asbd = (AudioStreamBasicDescription){0};
    os_unfair_lock_unlock(&_lock);
}

- (CMSampleBufferRef)copySampleBufferMatchingOrigin:(CMSampleBufferRef)origin {
    if (origin == NULL || !CMSampleBufferIsValid(origin)) {
        return NULL;
    }
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(origin);
    if (format == NULL || CMFormatDescriptionGetMediaType(format) != kCMMediaType_Audio) {
        return NULL;
    }
    const AudioStreamBasicDescription *originASBD =
        CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)format);
    if (!MyVCamAudioFormatIsReplacable(originASBD)) {
        if (!_loggedFormatSkip) {
            _loggedFormatSkip = YES;
            NSLog(@"%s microphone format not replacable bits=%u channels=%u flags=0x%x; passing through",
                  kMyVCamAudioPrefix,
                  originASBD != NULL ? originASBD->mBitsPerChannel : 0,
                  originASBD != NULL ? originASBD->mChannelsPerFrame : 0,
                  originASBD != NULL ? originASBD->mFormatFlags : 0);
        }
        return NULL;
    }

    CMItemCount originSamples = CMSampleBufferGetNumSamples(origin);
    if (originSamples <= 0) {
        return NULL;
    }

    AudioStreamBasicDescription target = *originASBD;
    dispatch_queue_t prepareQueue = _prepareQueue;
    NSURL *sidecar = nil;
    NSURL *video = nil;
    NSUInteger generation = 0;
    BOOL shouldPrepare = NO;
    BOOL ready = NO;
    NSData *pcm = nil;
    size_t bytesPerFrame = 0;
    NSUInteger cursor = 0;
    NSString *sourcePath = nil;

    os_unfair_lock_lock(&_lock);
    if (_fingerprint == nil) {
        os_unfair_lock_unlock(&_lock);
        return NULL;
    }
    if (_ready && MyVCamAudioFormatMatches(&_asbd, originASBD)) {
        ready = YES;
        pcm = _pcm;
        bytesPerFrame = _bytesPerFrame;
        cursor = _cursorBytes;
        generation = _generation;
        sourcePath = _sourcePath;
    } else if (_preparingGeneration != _generation && _failedGeneration != _generation) {
        _preparingGeneration = _generation;
        generation = _generation;
        sidecar = _sidecarURL;
        video = _videoURL;
        shouldPrepare = YES;
    }
    os_unfair_lock_unlock(&_lock);

    if (shouldPrepare) {
        dispatch_async(prepareQueue, ^{
            [self prepareWithASBD:target
                       generation:generation
                          sidecar:sidecar
                            video:video];
        });
        return NULL;
    }
    if (!ready || pcm.length == 0 || bytesPerFrame == 0) {
        return NULL;
    }

    NSUInteger byteSize = (NSUInteger)originSamples * bytesPerFrame;
    if (byteSize == 0 || pcm.length < byteSize) {
        return NULL;
    }

    uint8_t *copy = malloc(byteSize);
    if (copy == NULL) {
        return NULL;
    }
    const uint8_t *source = (const uint8_t *)pcm.bytes;
    NSUInteger length = pcm.length;
    NSUInteger start = length > 0 ? (cursor % length) : 0;
    NSUInteger first = MIN(byteSize, length - start);
    memcpy(copy, source + start, first);
    if (first < byteSize) {
        memcpy(copy + first, source, byteSize - first);
    }

    os_unfair_lock_lock(&_lock);
    if (_generation == generation && _ready) {
        NSUInteger next = cursor + byteSize;
        _cursorBytes = length > 0 ? (next % length) : 0;
    }
    os_unfair_lock_unlock(&_lock);

    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         copy,
                                                         byteSize,
                                                         kCFAllocatorMalloc,
                                                         NULL,
                                                         0,
                                                         byteSize,
                                                         0,
                                                         &block);
    if (status != noErr || block == NULL) {
        free(copy);
        return NULL;
    }

    CMTime presentation = MyVCamAudioPresentationTime(origin);
    if (!CMTIME_IS_NUMERIC(presentation)) {
        CFRelease(block);
        return NULL;
    }
    CMTime duration = MyVCamAudioDuration(origin);
    if (!CMTIME_IS_NUMERIC(duration) || CMTimeCompare(duration, kCMTimeZero) <= 0) {
        duration = CMTimeMake((int64_t)originSamples, (int32_t)target.mSampleRate);
    }
    CMSampleTimingInfo timing = {
        .duration = duration,
        .presentationTimeStamp = presentation,
        .decodeTimeStamp = kCMTimeInvalid,
    };

    CMSampleBufferRef replacement = NULL;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                       block,
                                       format,
                                       originSamples,
                                       1,
                                       &timing,
                                       0,
                                       NULL,
                                       &replacement);
    CFRelease(block);
    if (status != noErr || replacement == NULL) {
        return NULL;
    }

    if (!_loggedReplace) {
        _loggedReplace = YES;
        NSLog(@"%s replacing microphone samples=%ld rate=%.0f channels=%u source=%s",
              kMyVCamAudioPrefix,
              (long)originSamples,
              target.mSampleRate,
              target.mChannelsPerFrame,
              sourcePath.UTF8String ?: "");
    }
    return replacement;
}

#pragma mark - Decode

- (void)prepareWithASBD:(AudioStreamBasicDescription)asbd
             generation:(NSUInteger)generation
                sidecar:(NSURL *)sidecar
                  video:(NSURL *)video {
    NSURL *url = sidecar != nil ? sidecar : video;
    @autoreleasepool {
        @try {
            [self decodeURL:url asbd:asbd generation:generation];
        } @catch (NSException *exception) {
            NSLog(@"%s decode exception %@ path=%s",
                  kMyVCamAudioPrefix,
                  exception,
                  url.path.UTF8String ?: "");
            [self finishWithData:nil
                            asbd:asbd
                      generation:generation
                            path:url.path
                          reason:"exception"];
        }
    }
}

- (void)decodeURL:(NSURL *)url
             asbd:(AudioStreamBasicDescription)asbd
       generation:(NSUInteger)generation {
    if (url == nil) {
        [self finishWithData:nil
                        asbd:asbd
                  generation:generation
                        path:nil
                      reason:"no source url"];
        return;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (tracks.count == 0) {
        if (!_loggedNoTrack) {
            _loggedNoTrack = YES;
            NSLog(@"%s no audio track path=%s", kMyVCamAudioPrefix, url.path.UTF8String ?: "");
        }
        [self finishWithData:nil
                        asbd:asbd
                  generation:generation
                        path:url.path
                      reason:"no audio track"];
        return;
    }

    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(asbd.mSampleRate),
        AVNumberOfChannelsKey: @(asbd.mChannelsPerFrame),
        AVLinearPCMBitDepthKey: @(asbd.mBitsPerChannel),
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    };

    NSError *readerError = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
    if (reader == nil) {
        [self finishWithData:nil
                        asbd:asbd
                  generation:generation
                        path:url.path
                      reason:readerError.localizedDescription.UTF8String ?: "reader"];
        return;
    }

    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks.firstObject
                                        outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (output == nil || ![reader canAddOutput:output]) {
        [reader cancelReading];
        [self finishWithData:nil
                        asbd:asbd
                  generation:generation
                        path:url.path
                      reason:"track output refused"];
        return;
    }
    [reader addOutput:output];
    if (![reader startReading]) {
        [self finishWithData:nil
                        asbd:asbd
                  generation:generation
                        path:url.path
                      reason:reader.error.localizedDescription.UTF8String ?: "startReading"];
        return;
    }

    NSMutableData *pcm = [NSMutableData data];
    while (reader.status == AVAssetReaderStatusReading && pcm.length < kMyVCamAudioMaxBytes) {
        CMSampleBufferRef sample = [output copyNextSampleBuffer];
        if (sample == NULL) {
            break;
        }
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        if (block != NULL) {
            size_t length = CMBlockBufferGetDataLength(block);
            if (length > 0 && pcm.length + length <= kMyVCamAudioMaxBytes) {
                NSUInteger oldLength = pcm.length;
                [pcm setLength:oldLength + length];
                OSStatus copyStatus = CMBlockBufferCopyDataBytes(block,
                                                                0,
                                                                length,
                                                                (uint8_t *)pcm.mutableBytes + oldLength);
                if (copyStatus != noErr) {
                    [pcm setLength:oldLength];
                }
            }
        }
        CFRelease(sample);
    }
    [reader cancelReading];

    size_t bytesPerFrame = MyVCamAudioBytesPerFrame(&asbd);
    NSUInteger minimum = (NSUInteger)kMyVCamAudioMinFrames * bytesPerFrame;
    if (bytesPerFrame == 0 || pcm.length < minimum) {
        [self finishWithData:nil
                        asbd:asbd
                  generation:generation
                        path:url.path
                      reason:"track too short"];
        return;
    }
    NSUInteger usable = pcm.length - (pcm.length % bytesPerFrame);
    if (usable != pcm.length) {
        [pcm setLength:usable];
    }
    [self finishWithData:pcm asbd:asbd generation:generation path:url.path reason:NULL];
}

- (void)finishWithData:(NSData *)data
                  asbd:(AudioStreamBasicDescription)asbd
            generation:(NSUInteger)generation
                  path:(NSString *)path
                reason:(const char *)reason {
    BOOL applied = NO;
    size_t bytesPerFrame = MyVCamAudioBytesPerFrame(&asbd);
    os_unfair_lock_lock(&_lock);
    BOOL current = (_generation == generation);
    if (current && data.length > 0 && bytesPerFrame > 0) {
        _pcm = data;
        _asbd = asbd;
        _bytesPerFrame = bytesPerFrame;
        _cursorBytes = 0;
        _ready = YES;
        _sourcePath = path;
        _failedGeneration = 0;
        applied = YES;
    } else if (current && !_ready) {
        _failedGeneration = generation;
    }
    if (current && _preparingGeneration == generation) {
        _preparingGeneration = 0;
    }
    os_unfair_lock_unlock(&_lock);

    if (!current) {
        return;
    }
    if (applied) {
        NSLog(@"%s decoded path=%s bytes=%lu bytes_per_frame=%zu rate=%.0f channels=%u",
              kMyVCamAudioPrefix,
              path.UTF8String ?: "",
              (unsigned long)data.length,
              bytesPerFrame,
              asbd.mSampleRate,
              asbd.mChannelsPerFrame);
    } else {
        NSLog(@"%s decode skipped path=%s reason=%s",
              kMyVCamAudioPrefix,
              path.UTF8String ?: "",
              reason != NULL ? reason : "unknown");
    }
}

@end
