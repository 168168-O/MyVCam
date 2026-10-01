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
//  C1-C: startRunning calls the original implementation, then records that a
//  session is up.
//  stopRunning records the stop and stops the manager asynchronously; it
//  does not touch MediaReader on the session thread. The first 30 delegate
//  callbacks are pure passthrough. The next turn on com.myvcam.enable
//  attaches and starts the feed, unless
//  /var/mobile/Documents/MyVCam/disable exists. Delete that file and reopen
//  Camera to re-enable. The manager still owns the 30 fps loop.
//
//  MyVCamTweak.plist matches com.apple.camera only. The dylib is arm64 only.
//

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/lock.h>
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
/// Successful delegate callbacks before the feed or a replacement is allowed.
static const uint32_t kMyVCamPassthroughBeforeReplace = 30;
#define kMyVCamHandoffCount 8
static const int64_t kMyVCamMatchIntervalNanoseconds = (int64_t)(NSEC_PER_SEC / 30);
static BOOL gC1BLoggedPassThrough = NO;
static BOOL gC1BLoggedReplace = NO;
static BOOL gCaptureSessionRunning = NO;
static uint64_t gSessionGeneration = 0;
static MyVCamPhase gPhase = MyVCamPhaseWarmup;
static uint32_t gPassthroughCount = 0;
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
static __thread int gMyVCamInDelegateHook;
static __thread int gMyVCamInStart;
static __thread int gMyVCamInStop;

static void MyVCamC1B_MatchTick(uint64_t generation);
static void MyVCamC1C_SessionDidStart(uint64_t generation);

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

static void MyVCamC1C_SessionDidStart(uint64_t generation) {
    // Runs on com.myvcam.enable, off the capture delegate queue and off
    // -startRunning. A missing file returns NO and does not arm the timer.
    if (!MyVCamC1C_GenerationIsCurrent(generation)) {
        return;
    }

    MyVCamManager *manager = [MyVCamManager sharedManager];
    NSString *path = [NSString stringWithUTF8String:MyVCamManagerTestVideoPathUTF8];
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
        NSLog(@"%s feed not started path=%s error=%@", kMyVCamC1CPrefix, MyVCamManagerTestVideoPathUTF8, error);
        return;
    }
    NSLog(@"%s feed started path=%s", kMyVCamC1CPrefix, MyVCamManagerTestVideoPathUTF8);
    dispatch_async(gMatchQueue, ^{
        MyVCamC1B_MatchTick(generation);
    });
}

static void MyVCamC1C_NoteSessionStarted(void) {
    os_unfair_lock_lock(&gLock);
    gCaptureSessionRunning = YES;
    gSessionGeneration += 1;
    gPhase = MyVCamPhaseWarmup;
    gPassthroughCount = 0;
    os_unfair_lock_unlock(&gLock);
}

static void MyVCamC1C_NoteSessionStopped(void) {
    os_unfair_lock_lock(&gLock);
    gCaptureSessionRunning = NO;
    gSessionGeneration += 1;
    gPhase = MyVCamPhaseWarmup;
    gPassthroughCount = 0;
    os_unfair_lock_unlock(&gLock);
    // The session thread must not enter MediaReader. Enable-queue serialization
    // keeps this stop from overlapping startWithError:.
    dispatch_async(gEnableQueue, ^{
        [[MyVCamManager sharedManager] stop];
        NSLog(@"%s capture session stopped the feed", kMyVCamC1CPrefix);
    });
}

static void MyVCamC1C_ScheduleEnable(uint64_t generation) {
    dispatch_async(gEnableQueue, ^{
        if (access(kMyVCamDisablePath, F_OK) == 0) {
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

        os_unfair_lock_lock(&gLock);
        BOOL current = gCaptureSessionRunning && gSessionGeneration == generation && gPhase == MyVCamPhaseWarmup;
        if (current) {
            gPhase = MyVCamPhaseLive;
        }
        os_unfair_lock_unlock(&gLock);
        if (!current) {
            return;
        }
        NSLog(@"%s passthrough warmup finished (%u callbacks)", kMyVCamC1CPrefix, kMyVCamPassthroughBeforeReplace);
        MyVCamC1C_SessionDidStart(generation);
    });
}

static void MyVCamC1C_NotePassthrough(void) {
    uint64_t generation = 0;
    BOOL schedule = NO;
    os_unfair_lock_lock(&gLock);
    if (gCaptureSessionRunning && gPhase == MyVCamPhaseWarmup) {
        gPassthroughCount += 1;
        if (gPassthroughCount == kMyVCamPassthroughBeforeReplace) {
            generation = gSessionGeneration;
            schedule = YES;
        }
    }
    os_unfair_lock_unlock(&gLock);
    if (schedule) {
        MyVCamC1C_ScheduleEnable(generation);
    }
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
        if (running && phase == MyVCamPhaseWarmup) {
            MyVCamC1C_NotePassthrough();
        }
        return;
    }

    CMSampleBufferRef published = MyVCamC1B_CopyPublished(generation);
    if (published == NULL) {
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
    // startRunning; the running flag has to be set after that returns.
    if (gMyVCamInStart) {
        %orig;
        return;
    }
    gMyVCamInStart = 1;
    @try {
        %orig;
        MyVCamC1C_NoteSessionStarted();
    } @finally {
        gMyVCamInStart = 0;
    }
}

- (void)stopRunning {
    if (gMyVCamInStop) {
        %orig;
        return;
    }
    gMyVCamInStop = 1;
    @try {
        MyVCamC1C_NoteSessionStopped();
        %orig;
    } @finally {
        gMyVCamInStop = 0;
    }
}

%end

%ctor {
    MyVCamC1A_InitState();
    dispatch_async(dispatch_get_main_queue(), ^{
        %init;
        NSLog(@"%s hooks installed", kMyVCamC1APrefix);
    });
}
