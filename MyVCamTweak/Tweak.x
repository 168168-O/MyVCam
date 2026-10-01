//
//  Tweak.x
//  MyVCam
//
//  C1-A: hook AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:,
//  then hook that delegate class's
//  -captureOutput:didOutputSampleBuffer:fromConnection: once.
//  The hook is installed only when the method encoding is the void instance
//  method Camera uses (object, CMSampleBuffer pointer, object). A NULL
//  original IMP is never called. Hook installation is deferred to the main
//  queue so ElleKit does not hook while dyld is still loading Camera.
//  setSampleBufferDelegate calls the original setter before the delegate hook,
//  and MSHookMessageEx is not called while gLock is held.
//
//  C1-B: until a replacement has been built off the capture queue, the hook
//  calls the original IMP with the camera sample and does not message
//  VideoInjector, does not inspect the sample, and does not CFRelease it.
//  After warmup, com.myvcam.match calls
//  copyLatestSampleBufferMatchingOrigin: and publishes the result. The
//  capture callback only restamps that finished buffer. Audio stays on the
//  camera sample. The last eight deliveries stay retained.
//
//  C1-C: startRunning calls the original implementation, then, if the session
//  is running, records that a session is up. The next turn on
//  com.myvcam.enable attaches and starts the feed, unless a disable file is
//  present or neither test.mp4 spelling is readable. Camera's sandbox cannot
//  read /var/mobile/Documents. myvcam-mirror copies that file to
//  /var/jb/var/mobile/Library/MyVCam/test.mp4, which the check-in extension
//  allows. Delete the disable file and reopen Camera to re-enable. The
//  manager still owns the 30 fps loop. A nested stopRunning inside
//  startRunning does not clear that flag: Camera calls stop from inside
//  start, and counting that as a real stop left the feed off while the
//  session stayed up.
//  The feed is not gated on delegate callbacks. Camera's viewfinder is an
//  AVCaptureVideoPreviewLayer, which never calls the video-data-output
//  delegate. The display layer is the next sibling above that preview, not
//  a sublayer of it. A sublayer is covered by the live preview surface.
//  Each enqueued frame is a new IOSurface-backed 32BGRA sample.
//
//  MyVCamTweak.plist matches com.apple.camera only. The dylib is arm64 only.
//

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <errno.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <substrate.h>
#import <unistd.h>
#import "MyVCamManager.h"
#import "VideoInjector.h"

typedef void (*MyVCamC1ACaptureOutputIMP)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *);

typedef struct {
    Class cls;
    IMP imp;
} MyVCamC1AOriginal;

typedef enum {
    MyVCamPhaseWarmup = 0,
    MyVCamPhaseLive = 1,
    MyVCamPhaseDisabled = 2,
} MyVCamPhase;

static MyVCamC1AOriginal *gOriginals = NULL;
static unsigned gOriginalCount = 0;
static unsigned gOriginalCapacity = 0;
static NSMutableSet *gHookedClasses;
static NSMutableSet *gLoggedClasses;
static NSMutableSet *gMissingClasses;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static const char kMyVCamC1APrefix[] = "[MyVCam C1-A]";
static const char kMyVCamC1BPrefix[] = "[MyVCam C1-B]";
static const char kMyVCamC1CPrefix[] = "[MyVCam C1-C]";
static const char kMyVCamDisablePath[] = "/var/mobile/Documents/MyVCam/disable";
// Dopamine's process check-in grants read of /var/jb, not of Documents.
// myvcam-mirror writes these. Camera can access() them.
static const char kMyVCamMirrorVideoPath[] = "/var/jb/var/mobile/Library/MyVCam/test.mp4";
static const char kMyVCamMirrorDisablePath[] = "/var/jb/var/mobile/Library/MyVCam/disable";
static NSString * const kMyVCamPreviewOverlayName = @"MyVCam.preview";
#define kMyVCamHandoffCount 8
static const int64_t kMyVCamMatchIntervalNanoseconds = (int64_t)(NSEC_PER_SEC / 30);
static BOOL gC1BLoggedPassThrough = NO;
static BOOL gC1BLoggedReplace = NO;
static BOOL gCaptureSessionRunning = NO;
static uint64_t gSessionGeneration = 0;
static MyVCamPhase gPhase = MyVCamPhaseWarmup;
static CMSampleBufferRef gHandoff[kMyVCamHandoffCount] = {0};
static CMSampleBufferRef gPublished = NULL;
static uint64_t gPublishedGeneration = 0;
static CMSampleBufferRef gOrigin = NULL;
static uint64_t gOriginGeneration = 0;
static size_t gOriginWidth = 0;
static size_t gOriginHeight = 0;
static OSType gOriginFormat = 0;
static dispatch_queue_t gEnableQueue;
static dispatch_queue_t gMatchQueue;
static NSHashTable *gPreviewLayers;
static dispatch_source_t gPreviewTimer;
static BOOL gPreviewLogged = NO;
static BOOL gPreviewEnqueueFailedLogged = NO;
static BOOL gPreviewMissingLogged = NO;
static __thread int gMyVCamInDelegateHook;
static int gMyVCamStartDepth = 0;
static __thread int gMyVCamInStop;

static void MyVCamC1B_MatchTick(uint64_t generation);
static void MyVCamC1C_SessionDidStart(uint64_t generation);
static void MyVCamC1C_ScheduleEnable(uint64_t generation);
static void MyVCamC1C_EnableOnQueue(uint64_t generation, int attempt);
static void MyVCamPreview_Start(void);
static void MyVCamPreview_Stop(void);

static void MyVCamC1A_InitState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gHookedClasses = [[NSMutableSet alloc] init];
        gLoggedClasses = [[NSMutableSet alloc] init];
        gMissingClasses = [[NSMutableSet alloc] init];
        gEnableQueue = dispatch_queue_create("com.myvcam.enable", DISPATCH_QUEUE_SERIAL);
        gMatchQueue = dispatch_queue_create("com.myvcam.match", DISPATCH_QUEUE_SERIAL);
    });
}

static BOOL MyVCamC1A_StoreOriginal(Class cls, IMP imp) {
    if (cls == Nil || imp == NULL) {
        return NO;
    }
    if (gOriginalCount == gOriginalCapacity) {
        unsigned capacity = gOriginalCapacity == 0 ? 4 : gOriginalCapacity * 2;
        MyVCamC1AOriginal *grown = realloc(gOriginals, (size_t)capacity * sizeof(MyVCamC1AOriginal));
        if (grown == NULL) {
            return NO;
        }
        gOriginals = grown;
        gOriginalCapacity = capacity;
    }
    gOriginals[gOriginalCount].cls = cls;
    gOriginals[gOriginalCount].imp = imp;
    gOriginalCount++;
    return YES;
}

static IMP MyVCamC1A_FindOriginal(Class start) {
    for (Class walk = start; walk != Nil; walk = class_getSuperclass(walk)) {
        for (unsigned index = 0; index < gOriginalCount; index++) {
            if (gOriginals[index].cls == walk) {
                return gOriginals[index].imp;
            }
        }
    }
    return NULL;
}

static Class MyVCamC1A_ImplementingClass(Class start, SEL selector) {
    for (Class walk = start; walk != Nil; walk = class_getSuperclass(walk)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(walk, &count);
        BOOL found = NO;
        for (unsigned int index = 0; index < count; index++) {
            if (method_getName(methods[index]) == selector) {
                found = YES;
                break;
            }
        }
        free(methods);
        if (found) {
            return walk;
        }
    }
    return Nil;
}

static BOOL MyVCamC1A_ArgumentStartsWith(Method method, unsigned int index, char expected) {
    char type[8];
    memset(type, 0, sizeof(type));
    method_getArgumentType(method, index, type, sizeof(type));
    return type[0] == expected;
}

static BOOL MyVCamC1A_EncodingCanCall(Method method) {
    if (method == NULL) {
        return NO;
    }
    // self, _cmd, output, sampleBuffer, connection.
    if (method_getNumberOfArguments(method) != 5) {
        return NO;
    }
    const char *encoding = method_getTypeEncoding(method);
    if (encoding == NULL || encoding[0] != 'v') {
        return NO;
    }
    // output and connection are objects. The sample is a pointer
    // (^{opaqueCMSampleBuffer=}) or, rarely, an object.
    if (!MyVCamC1A_ArgumentStartsWith(method, 2, '@')) {
        return NO;
    }
    if (!MyVCamC1A_ArgumentStartsWith(method, 3, '^') && !MyVCamC1A_ArgumentStartsWith(method, 3, '@')) {
        return NO;
    }
    if (!MyVCamC1A_ArgumentStartsWith(method, 4, '@')) {
        return NO;
    }
    return YES;
}

static void MyVCamC1B_LogPathOnce(BOOL replaced) {
    BOOL shouldLog = NO;
    os_unfair_lock_lock(&gLock);
    if (replaced) {
        if (!gC1BLoggedReplace) {
            gC1BLoggedReplace = YES;
            shouldLog = YES;
        }
    } else if (!gC1BLoggedPassThrough) {
        gC1BLoggedPassThrough = YES;
        shouldLog = YES;
    }
    os_unfair_lock_unlock(&gLock);
    if (!shouldLog) {
        return;
    }
    if (replaced) {
        NSLog(@"%s replaced sampleBuffer with VideoInjector latest", kMyVCamC1BPrefix);
    } else {
        NSLog(@"%s pass-through original sampleBuffer", kMyVCamC1BPrefix);
    }
}

static BOOL MyVCamC1B_OriginIsVideoImage(CMSampleBufferRef sampleBuffer) {
    if (sampleBuffer == NULL || !CMSampleBufferIsValid(sampleBuffer)) {
        return NO;
    }
    if (CMSampleBufferGetImageBuffer(sampleBuffer) == NULL) {
        return NO;
    }
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (format == NULL) {
        return NO;
    }
    return CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video;
}

/// Takes ownership of `owned` (+1 or NULL). Retires the delivery from eight
/// callbacks ago. The camera buffer is never stored here.
static void MyVCamC1B_StoreHandoff(CMSampleBufferRef owned) {
    CMSampleBufferRef retired = NULL;
    os_unfair_lock_lock(&gLock);
    retired = gHandoff[kMyVCamHandoffCount - 1];
    for (int index = kMyVCamHandoffCount - 1; index > 0; index--) {
        gHandoff[index] = gHandoff[index - 1];
    }
    gHandoff[0] = owned;
    os_unfair_lock_unlock(&gLock);
    if (retired != NULL) {
        CFRelease(retired);
    }
}

static void MyVCamC1B_StashOrigin(CMSampleBufferRef owned,
                                  uint64_t generation,
                                  size_t width,
                                  size_t height,
                                  OSType format) {
    CMSampleBufferRef retired = NULL;
    BOOL accepted = NO;
    os_unfair_lock_lock(&gLock);
    if (gCaptureSessionRunning && gSessionGeneration == generation) {
        retired = gOrigin;
        gOrigin = owned;
        gOriginGeneration = generation;
        gOriginWidth = width;
        gOriginHeight = height;
        gOriginFormat = format;
        accepted = YES;
    }
    os_unfair_lock_unlock(&gLock);
    if (!accepted && owned != NULL) {
        CFRelease(owned);
    }
    if (retired != NULL) {
        CFRelease(retired);
    }
}

static CMSampleBufferRef MyVCamC1B_CopyOrigin(uint64_t generation) {
    CMSampleBufferRef origin = NULL;
    os_unfair_lock_lock(&gLock);
    if (gCaptureSessionRunning && gSessionGeneration == generation &&
        gOrigin != NULL && gOriginGeneration == generation) {
        origin = gOrigin;
        CFRetain(origin);
    }
    os_unfair_lock_unlock(&gLock);
    return origin;
}

static void MyVCamC1B_DropOriginIfGeneration(uint64_t generation) {
    CMSampleBufferRef retired = NULL;
    os_unfair_lock_lock(&gLock);
    if (gOriginGeneration == generation) {
        retired = gOrigin;
        gOrigin = NULL;
        gOriginGeneration = 0;
        gOriginWidth = 0;
        gOriginHeight = 0;
        gOriginFormat = 0;
    }
    os_unfair_lock_unlock(&gLock);
    if (retired != NULL) {
        CFRelease(retired);
    }
}

static void MyVCamC1B_Publish(CMSampleBufferRef owned, uint64_t generation) {
    CMSampleBufferRef retired = NULL;
    BOOL accepted = NO;
    os_unfair_lock_lock(&gLock);
    if (gCaptureSessionRunning && gSessionGeneration == generation) {
        // In-flight callbacks hold their own retain from CopyPublished.
        // The delivery ring is only for buffers passed into the original IMP.
        retired = gPublished;
        gPublished = owned;
        gPublishedGeneration = generation;
        accepted = YES;
    }
    os_unfair_lock_unlock(&gLock);
    if (!accepted && owned != NULL) {
        CFRelease(owned);
    }
    if (retired != NULL) {
        CFRelease(retired);
    }
}

static CMSampleBufferRef MyVCamC1B_CopyPublished(uint64_t generation) {
    CMSampleBufferRef published = NULL;
    os_unfair_lock_lock(&gLock);
    if (gCaptureSessionRunning && gSessionGeneration == generation &&
        gPublished != NULL && gPublishedGeneration == generation) {
        published = gPublished;
        CFRetain(published);
    }
    os_unfair_lock_unlock(&gLock);
    return published;
}

static void MyVCamC1B_DropPublishedIfGeneration(uint64_t generation) {
    CMSampleBufferRef dropped = NULL;
    os_unfair_lock_lock(&gLock);
    if (gPublishedGeneration == generation) {
        dropped = gPublished;
        gPublished = NULL;
        gPublishedGeneration = 0;
    }
    os_unfair_lock_unlock(&gLock);
    if (dropped != NULL) {
        CFRelease(dropped);
    }
}

static BOOL MyVCamC1C_GenerationIsCurrent(uint64_t generation) {
    os_unfair_lock_lock(&gLock);
    BOOL current = gCaptureSessionRunning && gSessionGeneration == generation;
    os_unfair_lock_unlock(&gLock);
    return current;
}

static CMSampleBufferRef MyVCamC1B_Restamp(CMSampleBufferRef source, CMSampleBufferRef origin) {
    if (source == NULL || origin == NULL) {
        return NULL;
    }
    CMTime presentation = CMSampleBufferGetOutputPresentationTimeStamp(origin);
    if (!CMTIME_IS_NUMERIC(presentation)) {
        presentation = CMSampleBufferGetPresentationTimeStamp(origin);
    }
    if (!CMTIME_IS_NUMERIC(presentation)) {
        return NULL;
    }
    CMTime duration = CMSampleBufferGetOutputDuration(origin);
    if (!CMTIME_IS_NUMERIC(duration) || CMTimeCompare(duration, kCMTimeZero) <= 0) {
        duration = CMSampleBufferGetDuration(origin);
    }
    if (!CMTIME_IS_NUMERIC(duration) || CMTimeCompare(duration, kCMTimeZero) <= 0) {
        duration = CMTimeMake(1, 30);
    }
    CMSampleTimingInfo timing = {
        .duration = duration,
        .presentationTimeStamp = presentation,
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef restamped = NULL;
    OSStatus status = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault,
                                                             source,
                                                             1,
                                                             &timing,
                                                             &restamped);
    if (status != noErr || restamped == NULL) {
        if (restamped != NULL) {
            CFRelease(restamped);
        }
        return NULL;
    }
    return restamped;
}

static void MyVCamC1B_NoteVideoOrigin(CMSampleBufferRef sampleBuffer, uint64_t generation) {
    if (!MyVCamC1B_OriginIsVideoImage(sampleBuffer)) {
        return;
    }
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixels == NULL) {
        return;
    }
    size_t width = CVPixelBufferGetWidth(pixels);
    size_t height = CVPixelBufferGetHeight(pixels);
    OSType format = CVPixelBufferGetPixelFormatType(pixels);
    os_unfair_lock_lock(&gLock);
    BOOL same = gCaptureSessionRunning && gSessionGeneration == generation &&
        gOrigin != NULL && gOriginGeneration == generation &&
        gOriginWidth == width && gOriginHeight == height && gOriginFormat == format;
    os_unfair_lock_unlock(&gLock);
    if (same) {
        return;
    }
    // A camera switch changes dimensions. The match queue has to see the new
    // buffer or it will keep building the previous size.
    CFRetain(sampleBuffer);
    MyVCamC1B_StashOrigin(sampleBuffer, generation, width, height, format);
}

static void MyVCamC1B_MatchTick(uint64_t generation) {
    if (!MyVCamC1C_GenerationIsCurrent(generation)) {
        MyVCamC1B_DropOriginIfGeneration(generation);
        MyVCamC1B_DropPublishedIfGeneration(generation);
        return;
    }

    @autoreleasepool {
        CMSampleBufferRef origin = MyVCamC1B_CopyOrigin(generation);
        if (origin != NULL) {
            VideoInjector *injector = [[MyVCamManager sharedManager] videoInjector];
            CMSampleBufferRef replacement = NULL;
            if (injector != nil) {
                @try {
                    replacement = [injector copyLatestSampleBufferMatchingOrigin:origin];
                } @catch (NSException *exception) {
                    replacement = NULL;
                    NSLog(@"%s replacement skipped: %@", kMyVCamC1BPrefix, exception);
                }
            }
            CFRelease(origin);
            if (replacement != NULL) {
                MyVCamC1B_Publish(replacement, generation);
            }
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kMyVCamMatchIntervalNanoseconds), gMatchQueue, ^{
        MyVCamC1B_MatchTick(generation);
    });
}

static BOOL MyVCamC1C_DisableFilePresent(void) {
    // F_OK on the Documents path is EPERM inside Camera even when the file
    // exists. The mirror marker is the one this process can see.
    if (access(kMyVCamDisablePath, F_OK) == 0) {
        return YES;
    }
    if (access(kMyVCamMirrorDisablePath, F_OK) == 0) {
        return YES;
    }
    return NO;
}

/// Documents path, its `/private` spelling, then the rootless mirror.
/// `/var` is `/private/var`. The Documents constant stays in the binary.
/// Camera's sandbox denies Documents, so the mirror is the path that opens.
static const char *MyVCamC1C_ReadableVideoPath(int *outErrno) {
    static char aliasPath[160];
    const char *primary = MyVCamManagerTestVideoPathUTF8;
    const char *candidates[3];
    int count = 0;
    int savedErrno = 0;

    if (primary != NULL) {
        candidates[count++] = primary;
    }
    int wrote = snprintf(aliasPath, sizeof(aliasPath), "/private%s", primary != NULL ? primary : "");
    if (wrote > 0 && (size_t)wrote < sizeof(aliasPath)) {
        candidates[count++] = aliasPath;
    }
    candidates[count++] = kMyVCamMirrorVideoPath;

    for (int index = 0; index < count; index++) {
        if (candidates[index] != NULL && access(candidates[index], R_OK) == 0) {
            if (outErrno != NULL) {
                *outErrno = 0;
            }
            return candidates[index];
        }
        if (errno != 0) {
            savedErrno = errno;
        }
    }
    if (outErrno != NULL) {
        *outErrno = savedErrno;
    }
    return NULL;
}

static void MyVCamC1C_SessionDidStart(uint64_t generation) {
    // Runs on com.myvcam.enable, off the capture delegate queue and off
    // -startRunning. A missing file returns NO and does not arm the timer.
    if (!MyVCamC1C_GenerationIsCurrent(generation)) {
        return;
    }

    int videoErrno = 0;
    const char *readable = MyVCamC1C_ReadableVideoPath(&videoErrno);
    if (readable == NULL) {
        NSLog(@"%s feed not started: test video not readable path=%s mirror=%s errno=%d",
              kMyVCamC1CPrefix,
              MyVCamManagerTestVideoPathUTF8,
              kMyVCamMirrorVideoPath,
              videoErrno);
        return;
    }
    MyVCamManager *manager = [MyVCamManager sharedManager];
    NSString *path = [NSString stringWithUTF8String:readable];
    if (path.length == 0) {
        NSLog(@"%s feed not started: test video path is empty", kMyVCamC1CPrefix);
        return;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:path isDirectory:NO];
    [manager attachMediaFileURL:fileURL];
    NSError *error = nil;
    BOOL started = [manager startWithError:&error];
    if (!MyVCamC1C_GenerationIsCurrent(generation)) {
        [manager stop];
        NSLog(@"%s feed not started: capture session ended during prepare", kMyVCamC1CPrefix);
        return;
    }
    if (!started) {
        NSLog(@"%s feed not started path=%s error=%@", kMyVCamC1CPrefix, readable, error);
        return;
    }
    os_unfair_lock_lock(&gLock);
    if (gCaptureSessionRunning && gSessionGeneration == generation) {
        gPhase = MyVCamPhaseLive;
    }
    os_unfair_lock_unlock(&gLock);
    NSLog(@"%s feed started path=%s", kMyVCamC1CPrefix, readable);
    dispatch_async(gMatchQueue, ^{
        MyVCamC1B_MatchTick(generation);
    });
    MyVCamPreview_Start();
}

static void MyVCamC1C_NoteSessionStarted(void) {
    uint64_t generation = 0;
    os_unfair_lock_lock(&gLock);
    // A second startRunning while this session is already recorded must not
    // bump the generation. Camera calls start again while the session is up;
    // resetting here threw away the pending enable before it could run.
    if (gCaptureSessionRunning) {
        os_unfair_lock_unlock(&gLock);
        return;
    }
    gCaptureSessionRunning = YES;
    gSessionGeneration += 1;
    gPhase = MyVCamPhaseWarmup;
    generation = gSessionGeneration;
    os_unfair_lock_unlock(&gLock);
    MyVCamC1C_ScheduleEnable(generation);
}

static void MyVCamC1C_NoteSessionStopped(void) {
    os_unfair_lock_lock(&gLock);
    gCaptureSessionRunning = NO;
    gSessionGeneration += 1;
    gPhase = MyVCamPhaseWarmup;
    os_unfair_lock_unlock(&gLock);
    // The session thread must not enter MediaReader. Enable-queue serialization
    // keeps this stop from overlapping startWithError:.
    dispatch_async(gEnableQueue, ^{
        [[MyVCamManager sharedManager] stop];
        NSLog(@"%s capture session stopped the feed", kMyVCamC1CPrefix);
    });
    MyVCamPreview_Stop();
}

static void MyVCamC1C_EnableOnQueue(uint64_t generation, int attempt) {
    // Runs on com.myvcam.enable. Not gated on capture callbacks: the
    // viewfinder does not deliver those, so a callback counter never ends.
    if (!MyVCamC1C_GenerationIsCurrent(generation)) {
        return;
    }
    if (MyVCamC1C_DisableFilePresent()) {
        os_unfair_lock_lock(&gLock);
        if (gCaptureSessionRunning && gSessionGeneration == generation) {
            gPhase = MyVCamPhaseDisabled;
        }
        os_unfair_lock_unlock(&gLock);
        NSLog(@"%s feed not started: disable file %s (delete it and reopen Camera to re-enable)",
              kMyVCamC1CPrefix,
              kMyVCamDisablePath);
        return;
    }

    int videoErrno = 0;
    if (MyVCamC1C_ReadableVideoPath(&videoErrno) == NULL) {
        // The mirror is written by launchd after the file appears. Give it a
        // few seconds on this same session before leaving the preview live.
        if (attempt < 8) {
            if (attempt == 0) {
                NSLog(@"%s feed waiting for test video path=%s mirror=%s errno=%d",
                      kMyVCamC1CPrefix,
                      MyVCamManagerTestVideoPathUTF8,
                      kMyVCamMirrorVideoPath,
                      videoErrno);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 2)), gEnableQueue, ^{
                MyVCamC1C_EnableOnQueue(generation, attempt + 1);
            });
            return;
        }
        NSLog(@"%s feed not started: test video not readable path=%s mirror=%s errno=%d",
              kMyVCamC1CPrefix,
              MyVCamManagerTestVideoPathUTF8,
              kMyVCamMirrorVideoPath,
              videoErrno);
        return;
    }

    os_unfair_lock_lock(&gLock);
    BOOL current = gCaptureSessionRunning && gSessionGeneration == generation && gPhase == MyVCamPhaseWarmup;
    os_unfair_lock_unlock(&gLock);
    if (!current) {
        return;
    }
    NSLog(@"%s passthrough warmup finished (session up)", kMyVCamC1CPrefix);
    MyVCamC1C_SessionDidStart(generation);
}

static void MyVCamC1C_ScheduleEnable(uint64_t generation) {
    // Next turn, off -startRunning.
    dispatch_async(gEnableQueue, ^{
        MyVCamC1C_EnableOnQueue(generation, 0);
    });
}

static void MyVCamC1A_Deliver(id self,
                              SEL _cmd,
                              AVCaptureOutput *output,
                              CMSampleBufferRef sampleBuffer,
                              AVCaptureConnection *connection,
                              IMP original) {
    MyVCamPhase phase = MyVCamPhaseWarmup;
    BOOL running = NO;
    uint64_t generation = 0;
    os_unfair_lock_lock(&gLock);
    phase = gPhase;
    running = gCaptureSessionRunning;
    generation = gSessionGeneration;
    os_unfair_lock_unlock(&gLock);

    // Warmup, a disable file, and a stopped session never touch the sample
    // or the injector. A live session with nothing published yet also skips
    // the injector; it only records a video buffer so the match queue can
    // learn the format.
    if (!running || phase != MyVCamPhaseLive) {
        ((MyVCamC1ACaptureOutputIMP)original)(self, _cmd, output, sampleBuffer, connection);
        return;
    }

    CMSampleBufferRef published = MyVCamC1B_CopyPublished(generation);
    if (published == NULL) {
        MyVCamC1B_LogPathOnce(NO);
        ((MyVCamC1ACaptureOutputIMP)original)(self, _cmd, output, sampleBuffer, connection);
        MyVCamC1B_NoteVideoOrigin(sampleBuffer, generation);
        return;
    }

    if (!MyVCamC1B_OriginIsVideoImage(sampleBuffer)) {
        CFRelease(published);
        ((MyVCamC1ACaptureOutputIMP)original)(self, _cmd, output, sampleBuffer, connection);
        return;
    }

    CMSampleBufferRef restamped = MyVCamC1B_Restamp(published, sampleBuffer);
    CFRelease(published);
    if (restamped == NULL) {
        MyVCamC1B_LogPathOnce(NO);
        ((MyVCamC1ACaptureOutputIMP)original)(self, _cmd, output, sampleBuffer, connection);
        MyVCamC1B_NoteVideoOrigin(sampleBuffer, generation);
        return;
    }

    MyVCamC1B_LogPathOnce(YES);
    ((MyVCamC1ACaptureOutputIMP)original)(self, _cmd, output, restamped, connection);
    MyVCamC1B_StoreHandoff(restamped);
    MyVCamC1B_NoteVideoOrigin(sampleBuffer, generation);
}

static void MyVCamC1A_DidOutput(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    if (self == nil) {
        return;
    }

    IMP original = NULL;
    Class notedClass = Nil;
    BOOL missingOriginal = NO;

    MyVCamC1A_InitState();
    os_unfair_lock_lock(&gLock);
    Class selfClass = object_getClass(self);
    original = MyVCamC1A_FindOriginal(selfClass);
    if (selfClass != Nil && ![gLoggedClasses containsObject:(id)selfClass]) {
        [gLoggedClasses addObject:(id)selfClass];
        notedClass = selfClass;
        missingOriginal = (original == NULL);
    }
    os_unfair_lock_unlock(&gLock);

    if (notedClass != Nil) {
        if (missingOriginal) {
            NSLog(@"%s missing original IMP for class=%@", kMyVCamC1APrefix, NSStringFromClass(notedClass));
        } else {
            NSLog(@"%s captureOutput:didOutputSampleBuffer:fromConnection: fired class=%@", kMyVCamC1APrefix, NSStringFromClass(notedClass));
        }
    }

    if (original == NULL || original == (IMP)MyVCamC1A_DidOutput) {
        return;
    }

    // The original IMP can re-enter this hook on the same thread. Taking
    // gLock twice would abort the process.
    if (gMyVCamInDelegateHook) {
        ((MyVCamC1ACaptureOutputIMP)original)(self, _cmd, output, sampleBuffer, connection);
        return;
    }

    gMyVCamInDelegateHook = 1;
    @try {
        MyVCamC1A_Deliver(self, _cmd, output, sampleBuffer, connection, original);
    } @finally {
        gMyVCamInDelegateHook = 0;
    }
}

static void MyVCamC1A_HookDelegateIfNeeded(id delegate) {
    if (delegate == nil) {
        return;
    }

    MyVCamC1A_InitState();

    SEL selector = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Class delegateClass = object_getClass(delegate);
    Class implClass = MyVCamC1A_ImplementingClass(delegateClass, selector);
    if (implClass == Nil) {
        if (delegateClass == Nil) {
            return;
        }
        os_unfair_lock_lock(&gLock);
        BOOL first = ![gMissingClasses containsObject:(id)delegateClass];
        if (first) {
            [gMissingClasses addObject:(id)delegateClass];
        }
        os_unfair_lock_unlock(&gLock);
        if (first) {
            NSLog(@"%s %@ does not implement captureOutput:didOutputSampleBuffer:fromConnection:", kMyVCamC1APrefix, NSStringFromClass(delegateClass));
        }
        return;
    }

    os_unfair_lock_lock(&gLock);
    if ([gHookedClasses containsObject:(id)implClass]) {
        os_unfair_lock_unlock(&gLock);
        return;
    }
    // Claim before hooking so a second setter cannot install the hook twice.
    [gHookedClasses addObject:(id)implClass];
    os_unfair_lock_unlock(&gLock);

    Method method = class_getInstanceMethod(implClass, selector);
    IMP prior = method != NULL ? method_getImplementation(method) : NULL;
    if (prior == (IMP)MyVCamC1A_DidOutput) {
        return;
    }
    if (!MyVCamC1A_EncodingCanCall(method)) {
        const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
        NSLog(@"%s refused to hook %@ encoding=%s", kMyVCamC1APrefix, NSStringFromClass(implClass), encoding != NULL ? encoding : "");
        return;
    }

    IMP replaced = NULL;
    MSHookMessageEx(implClass, selector, (IMP)MyVCamC1A_DidOutput, &replaced);
    IMP original = replaced != NULL ? replaced : prior;
    if (original == NULL || original == (IMP)MyVCamC1A_DidOutput) {
        NSLog(@"%s failed to hook %@", kMyVCamC1APrefix, NSStringFromClass(implClass));
        return;
    }

    os_unfair_lock_lock(&gLock);
    BOOL stored = MyVCamC1A_StoreOriginal(implClass, original);
    os_unfair_lock_unlock(&gLock);
    if (!stored) {
        // The hook is already installed. Putting the original IMP back avoids
        // a callback that cannot find it and drops Camera's frames.
        if (method != NULL) {
            method_setImplementation(method, original);
        }
        NSLog(@"%s failed to hook %@", kMyVCamC1APrefix, NSStringFromClass(implClass));
        return;
    }
    NSLog(@"%s hooked captureOutput:didOutputSampleBuffer:fromConnection: on %@", kMyVCamC1APrefix, NSStringFromClass(implClass));
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    // Let AVFoundation finish the setter before the class is mutated.
    %orig;
    MyVCamC1A_HookDelegateIfNeeded(sampleBufferDelegate);
}

%end

%hook AVCaptureSession

- (void)startRunning {
    // Original implementation first. Camera calls stopRunning from inside
    // startRunning; that nested stop must not clear the running flag.
    __atomic_add_fetch(&gMyVCamStartDepth, 1, __ATOMIC_SEQ_CST);
    @try {
        %orig;
        if (self.isRunning) {
            MyVCamC1C_NoteSessionStarted();
        }
    } @finally {
        __atomic_sub_fetch(&gMyVCamStartDepth, 1, __ATOMIC_SEQ_CST);
    }
}

- (void)stopRunning {
    if (gMyVCamInStop) {
        %orig;
        return;
    }
    BOOL wasRunning = self.isRunning;
    gMyVCamInStop = 1;
    @try {
        %orig;
        // Nested inside startRunning, or a stop of a session that was not
        // running: the session is still up (or never was). Do not tear down
        // a feed the matching startRunning is about to arm.
        BOOL nestedInStart = __atomic_load_n(&gMyVCamStartDepth, __ATOMIC_SEQ_CST) > 0;
        if (!nestedInStart && wasRunning && !self.isRunning) {
            MyVCamC1C_NoteSessionStopped();
        }
    } @finally {
        gMyVCamInStop = 0;
    }
}

%end

static void MyVCamPreview_Track(AVCaptureVideoPreviewLayer *layer) {
    if (layer == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPreviewLayers == nil) {
            gPreviewLayers = [NSHashTable weakObjectsHashTable];
        }
        [gPreviewLayers addObject:layer];
    });
}

static void MyVCamPreview_ScanLayer(CALayer *layer) {
    if (layer == nil) {
        return;
    }
    if ([layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
        if (gPreviewLayers == nil) {
            gPreviewLayers = [NSHashTable weakObjectsHashTable];
        }
        [gPreviewLayers addObject:layer];
    }
    NSArray<CALayer *> *sublayers = layer.sublayers;
    for (CALayer *sublayer in sublayers) {
        MyVCamPreview_ScanLayer(sublayer);
    }
}

static void MyVCamPreview_ScanWindows(void) {
    // UIApplication.windows is deprecated in the iOS 15 SDK and Theos builds
    // with -Werror. It is still the list Camera's viewfinder is in on
    // iOS 15.3.1 when connectedScenes has not published a window yet.
    // UIWindowScene.windows is walked as well.
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) {
        return;
    }
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<UIWindow *> *legacyWindows = application.windows;
#pragma clang diagnostic pop
    if (legacyWindows.count > 0) {
        [windows addObjectsFromArray:legacyWindows];
    }
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<UIWindow *> *sceneWindows = windowScene.windows;
#pragma clang diagnostic pop
        for (UIWindow *window in sceneWindows) {
            if (![windows containsObject:window]) {
                [windows addObject:window];
            }
        }
    }
    for (UIWindow *window in windows) {
        MyVCamPreview_ScanLayer(window.layer);
    }
}

static AVSampleBufferDisplayLayer *MyVCamPreview_FindOverlay(NSArray<CALayer *> *sublayers) {
    for (CALayer *sublayer in sublayers) {
        if ([sublayer.name isEqualToString:kMyVCamPreviewOverlayName] &&
            [sublayer isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
            return (AVSampleBufferDisplayLayer *)sublayer;
        }
    }
    return nil;
}

/// Sibling immediately above the preview. A sublayer of
/// AVCaptureVideoPreviewLayer is painted under the live preview surface, so
/// zPosition on that sublayer never covers the camera. Same zPosition as the
/// preview keeps later chrome (shutter, focus) above this layer.
static AVSampleBufferDisplayLayer *MyVCamPreview_Overlay(AVCaptureVideoPreviewLayer *preview, BOOL create) {
    CALayer *host = preview.superlayer;
    CGRect frame = preview.frame;
    AVSampleBufferDisplayLayer *overlay = nil;
    if (host != nil) {
        overlay = MyVCamPreview_FindOverlay(host.sublayers);
    }
    if (overlay == nil) {
        overlay = MyVCamPreview_FindOverlay(preview.sublayers);
    }
    BOOL placed = host != nil && !CGRectIsEmpty(frame);
    if (overlay != nil) {
        if (placed) {
            overlay.frame = frame;
            overlay.zPosition = preview.zPosition;
            overlay.hidden = NO;
            overlay.opacity = 1.0;
            NSArray<CALayer *> *sublayers = host.sublayers;
            NSUInteger overlayIndex = [sublayers indexOfObject:overlay];
            NSUInteger previewIndex = [sublayers indexOfObject:preview];
            if (overlay.superlayer != host ||
                overlayIndex == NSNotFound ||
                previewIndex == NSNotFound ||
                overlayIndex < previewIndex) {
                [host insertSublayer:overlay above:preview];
            }
        }
        return overlay;
    }
    if (!create || !placed) {
        return nil;
    }
    overlay = [AVSampleBufferDisplayLayer layer];
    overlay.name = kMyVCamPreviewOverlayName;
    overlay.frame = frame;
    overlay.videoGravity = AVLayerVideoGravityResizeAspectFill;
    overlay.backgroundColor = [UIColor blackColor].CGColor;
    overlay.opaque = YES;
    overlay.masksToBounds = YES;
    overlay.zPosition = preview.zPosition;
    overlay.contentsScale = UIScreen.mainScreen.scale;
    // No controlTimebase. Samples are marked display-immediately. A timebase
    // left at zero drops frames whose presentation time has already moved on,
    // which is what happened after a failed enqueue rebuilt the layer.
    [host insertSublayer:overlay above:preview];
    return overlay;
}

static void MyVCamPreview_RemoveNamedSublayers(CALayer *layer) {
    if (layer == nil) {
        return;
    }
    NSArray<CALayer *> *sublayers = [layer.sublayers copy];
    for (CALayer *sublayer in sublayers) {
        if ([sublayer.name isEqualToString:kMyVCamPreviewOverlayName]) {
            [sublayer removeFromSuperlayer];
        }
    }
}

static void MyVCamPreview_RemoveOverlays(void) {
    for (AVCaptureVideoPreviewLayer *preview in gPreviewLayers.allObjects) {
        MyVCamPreview_RemoveNamedSublayers(preview);
        MyVCamPreview_RemoveNamedSublayers(preview.superlayer);
    }
}

static CVPixelBufferRef MyVCamPreview_CreateIOSurfaceBGRA(size_t width, size_t height) {
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVPixelBufferRef buffer = NULL;
    CVReturn created = CVPixelBufferCreate(kCFAllocatorDefault,
                                            width,
                                            height,
                                            kCVPixelFormatType_32BGRA,
                                            (__bridge CFDictionaryRef)attributes,
                                            &buffer);
    if (created != kCVReturnSuccess || buffer == NULL || CVPixelBufferGetIOSurface(buffer) == NULL) {
        if (buffer != NULL) {
            CVPixelBufferRelease(buffer);
        }
        return NULL;
    }
    return buffer;
}

static BOOL MyVCamPreview_CopyBGRA(CVPixelBufferRef source, CVPixelBufferRef destination) {
    CVReturn sourceLock = CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVReturn destinationLock = CVPixelBufferLockBaseAddress(destination, 0);
    BOOL copied = NO;
    if (sourceLock == kCVReturnSuccess && destinationLock == kCVReturnSuccess) {
        uint8_t *sourceBase = CVPixelBufferGetBaseAddress(source);
        uint8_t *destinationBase = CVPixelBufferGetBaseAddress(destination);
        size_t width = CVPixelBufferGetWidth(destination);
        size_t height = CVPixelBufferGetHeight(destination);
        size_t sourceRow = CVPixelBufferGetBytesPerRow(source);
        size_t destinationRow = CVPixelBufferGetBytesPerRow(destination);
        size_t rowBytes = width * 4u;
        if (sourceBase != NULL && destinationBase != NULL &&
            height > 0 && rowBytes > 0 &&
            rowBytes <= sourceRow && rowBytes <= destinationRow) {
            for (size_t row = 0; row < height; row++) {
                memcpy(destinationBase + (row * destinationRow),
                       sourceBase + (row * sourceRow),
                       rowBytes);
            }
            copied = YES;
        }
    }
    if (destinationLock == kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(destination, 0);
    }
    if (sourceLock == kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    }
    return copied;
}

/// New IOSurface-backed 32BGRA sample (+1). AVSampleBufferDisplayLayer rejects
/// a buffer that is not IOSurface-backed, and AVAssetReader does not promise
/// one. DisplayImmediately so a control timebase is not required.
static CMSampleBufferRef MyVCamPreview_CopyDisplaySample(CMSampleBufferRef source) {
    static int64_t tick = 0;
    if (source == NULL) {
        return NULL;
    }
    CVPixelBufferRef sourcePixels = CMSampleBufferGetImageBuffer(source);
    if (sourcePixels == NULL ||
        CVPixelBufferGetPixelFormatType(sourcePixels) != kCVPixelFormatType_32BGRA) {
        return NULL;
    }
    size_t width = CVPixelBufferGetWidth(sourcePixels);
    size_t height = CVPixelBufferGetHeight(sourcePixels);
    if (width == 0 || height == 0) {
        return NULL;
    }
    CVPixelBufferRef pixels = MyVCamPreview_CreateIOSurfaceBGRA(width, height);
    if (pixels == NULL) {
        return NULL;
    }
    if (!MyVCamPreview_CopyBGRA(sourcePixels, pixels)) {
        CVPixelBufferRelease(pixels);
        return NULL;
    }

    CMVideoFormatDescriptionRef format = NULL;
    OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                          pixels,
                                                                          &format);
    if (formatStatus != noErr || format == NULL) {
        if (format != NULL) {
            CFRelease(format);
        }
        CVPixelBufferRelease(pixels);
        return NULL;
    }

    tick += 1;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMake(tick, 30),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    OSStatus sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                                      pixels,
                                                                      format,
                                                                      &timing,
                                                                      &sample);
    CFRelease(format);
    CVPixelBufferRelease(pixels);
    if (sampleStatus != noErr || sample == NULL) {
        if (sample != NULL) {
            CFRelease(sample);
        }
        return NULL;
    }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        CFTypeRef value = CFArrayGetValueAtIndex(attachments, 0);
        if (value != NULL && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
            CFDictionarySetValue((CFMutableDictionaryRef)value,
                                 kCMSampleAttachmentKey_DisplayImmediately,
                                 kCFBooleanTrue);
        }
    }
    return sample;
}

static BOOL MyVCamPreview_SessionIsLive(void) {
    os_unfair_lock_lock(&gLock);
    BOOL live = gCaptureSessionRunning && gPhase == MyVCamPhaseLive;
    os_unfair_lock_unlock(&gLock);
    return live;
}

static void MyVCamPreview_Tick(void) {
    static uint32_t scanTick = 0;
    scanTick += 1;
    BOOL noLayers = gPreviewLayers == nil || gPreviewLayers.allObjects.count == 0;
    if (noLayers || (scanTick % 15u) == 1u) {
        MyVCamPreview_ScanWindows();
    }
    if (!MyVCamPreview_SessionIsLive()) {
        MyVCamPreview_RemoveOverlays();
        return;
    }
    if (gPreviewLayers == nil || gPreviewLayers.allObjects.count == 0) {
        if (!gPreviewMissingLogged && scanTick > 30u) {
            gPreviewMissingLogged = YES;
            NSLog(@"%s preview layer not in a window", kMyVCamC1CPrefix);
        }
        return;
    }
    VideoInjector *injector = [[MyVCamManager sharedManager] videoInjector];
    CMSampleBufferRef latest = injector != nil ? [injector copyLatestSampleBuffer] : NULL;
    if (latest == NULL) {
        return;
    }
    BOOL enqueued = NO;
    for (AVCaptureVideoPreviewLayer *preview in gPreviewLayers.allObjects) {
        // A session that exists and is stopped is not the viewfinder. A layer
        // whose session property is still nil can already be on screen;
        // Photo mode does that before the property is published.
        if (preview.session != nil && !preview.session.isRunning) {
            continue;
        }
        AVSampleBufferDisplayLayer *overlay = MyVCamPreview_Overlay(preview, YES);
        if (overlay == nil) {
            continue;
        }
        if (!overlay.isReadyForMoreMediaData) {
            continue;
        }
        CMSampleBufferRef stamped = MyVCamPreview_CopyDisplaySample(latest);
        if (stamped == NULL) {
            continue;
        }
        if (overlay.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [overlay flush];
        }
        if (overlay.isReadyForMoreMediaData) {
            [overlay enqueueSampleBuffer:stamped];
        }
        if (overlay.status == AVQueuedSampleBufferRenderingStatusFailed) {
            // Keep the layer. Removing it on the first failure is what left
            // the live preview uncovered. flush and the next tick retry.
            if (!gPreviewEnqueueFailedLogged) {
                gPreviewEnqueueFailedLogged = YES;
                NSLog(@"%s preview enqueue failed: %@", kMyVCamC1CPrefix, overlay.error);
            }
            [overlay flush];
        } else {
            enqueued = YES;
        }
        CFRelease(stamped);
    }
    CFRelease(latest);
    if (enqueued && !gPreviewLogged) {
        gPreviewLogged = YES;
        NSLog(@"%s preview showing imported video", kMyVCamC1CPrefix);
    }
}

static void MyVCamPreview_Start(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPreviewTimer != nil) {
            return;
        }
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                          0,
                                                          0,
                                                          dispatch_get_main_queue());
        if (timer == NULL) {
            NSLog(@"%s preview not started: could not create timer", kMyVCamC1CPrefix);
            return;
        }
        dispatch_source_set_timer(timer,
                                  DISPATCH_TIME_NOW,
                                  (uint64_t)(NSEC_PER_SEC / 30),
                                  (uint64_t)NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            MyVCamPreview_Tick();
        });
        gPreviewTimer = timer;
        dispatch_resume(timer);
    });
}

static void MyVCamPreview_Stop(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPreviewTimer != nil) {
            dispatch_source_cancel(gPreviewTimer);
            gPreviewTimer = nil;
        }
        gPreviewLogged = NO;
        gPreviewEnqueueFailedLogged = NO;
        gPreviewMissingLogged = NO;
        MyVCamPreview_RemoveOverlays();
    });
}

%hook AVCaptureVideoPreviewLayer

+ (instancetype)layerWithSession:(AVCaptureSession *)session {
    AVCaptureVideoPreviewLayer *layer = %orig;
    MyVCamPreview_Track(layer);
    return layer;
}

+ (instancetype)layerWithSessionWithNoConnection:(AVCaptureSession *)session {
    AVCaptureVideoPreviewLayer *layer = %orig;
    MyVCamPreview_Track(layer);
    return layer;
}

- (instancetype)initWithSession:(AVCaptureSession *)session {
    AVCaptureVideoPreviewLayer *layer = %orig;
    MyVCamPreview_Track(layer);
    return layer;
}

- (instancetype)initWithSessionWithNoConnection:(AVCaptureSession *)session {
    AVCaptureVideoPreviewLayer *layer = %orig;
    MyVCamPreview_Track(layer);
    return layer;
}

- (void)setSession:(AVCaptureSession *)session {
    %orig;
    MyVCamPreview_Track((AVCaptureVideoPreviewLayer *)self);
}

- (void)setSessionWithNoConnection:(AVCaptureSession *)session {
    %orig;
    MyVCamPreview_Track((AVCaptureVideoPreviewLayer *)self);
}

%end

%ctor {
    MyVCamC1A_InitState();
    dispatch_async(dispatch_get_main_queue(), ^{
        %init;
        NSLog(@"%s hooks installed", kMyVCamC1APrefix);
    });
}
