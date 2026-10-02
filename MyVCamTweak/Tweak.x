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
//  present or no test.mp4 candidate can be opened. Camera's sandbox cannot
//  read /var/mobile/Documents. myvcam-mirror (root, outside Camera) copies
//  that file to /var/jb/var/mobile/Library/MyVCam/test.mp4 and to Camera's
//  own data container. Readability is open(), not access(): Dopamine's
//  extension is issued for the real jbroot path, and access() on the
//  /var/jb symlink is the check that already rejected Documents. The enable
//  queue keeps retrying while this session is current. A preview layer whose
//  session is already running arms the same path if startRunning was missed.
//  Delete the disable file and reopen Camera to re-enable. The manager still
//  owns the 30 fps loop. A nested stopRunning inside startRunning does not
//  clear the running flag.
//  The feed is not gated on delegate callbacks. Camera's viewfinder is an
//  AVCaptureVideoPreviewLayer, which never calls the video-data-output
//  delegate, so the C1-B hook cannot change what Photo mode shows.
//  Photo mode keeps that layer as a sublayer of previewLayerView, inside the
//  preview branch. The shutter and the bars are siblings of that branch.
//  The cover is an opaque UIView in the viewfinder, immediately above the
//  preview branch, hosting an AVSampleBufferDisplayLayer. The display layer
//  itself stays transparent until a frame is accepted, so a cover whose
//  backing layer is that display layer still shows the live image. A second
//  opaque view is inserted above the preview host when that slot is different.
//  While a cover is up, setEnabled: keeps the preview connection off, and
//  addSublayer:, insertSublayer:, replaceSublayer:with:, and setSublayers:
//  leave a non-backing preview layer detached. Prepare failures are retried
//  for the life of the capture session. Each enqueued frame is an
//  IOSurface-backed 32BGRA sample. The process writes one line to
//  /var/jb/var/mobile/Library/MyVCam/runtime.status so Filza can show ctor,
//  feed, slot, and enqueue state without Console. The line includes proc=
//  so a SpringBoard load can be told apart from a Camera load.
//
//  MyVCamTweak.plist matches com.apple.camera, Camera, com.apple.springboard,
//  and SpringBoard. SpringBoard only proves the dylib ran %ctor. Camera
//  hooks are not installed there. The dylib is arm64 only.
//

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurfaceRef.h>
// The iPhoneOS SDK does not provide IOKit/IOReturn.h. IOSurfaceLock returns 0
// on success, which is kIOReturnSuccess.
#ifndef kIOReturnSuccess
#define kIOReturnSuccess 0
#endif
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <time.h>
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
static const char kMyVCamDiagPrefix[] = "[MyVCam 0.2.13]";
static const char kMyVCamDisablePath[] = "/var/mobile/Documents/MyVCam/disable";
// Dopamine issues the sandbox extension for the real jbroot vnode
// (JBROOT_PATH("/var/mobile")), not for the "/var/jb" symlink string.
// myvcam-mirror writes the symlink path and Camera's container. open()
// is the check; access() rejects paths this process can still open.
static const char kMyVCamMirrorVideoPath[] = "/var/jb/var/mobile/Library/MyVCam/test.mp4";
static const char kMyVCamMirrorDisablePath[] = "/var/jb/var/mobile/Library/MyVCam/disable";
static const char kMyVCamMirrorStatusPath[] = "/var/jb/var/mobile/Library/MyVCam/mirror.status";
static const char kMyVCamRuntimeStatusPath[] = "/var/jb/var/mobile/Library/MyVCam/runtime.status";
static const char kMyVCamStatusVersion[] = "0.2.15";
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
static int gPreviewEnqueueStreak = 0;
static char kMyVCamOverlayAssociationKey;
static char kMyVCamOpacityAssociationKey;
static char kMyVCamConnectionAssociationKey;
static char kMyVCamCoverAnchorKey;
static char kMyVCamCoverPreviewKey;
static char kMyVCamCoverContainerKey;
static char kMyVCamCoverHostKey;
static char kMyVCamHostAlphaKey;
static char kMyVCamHiddenAssociationKey;
static NSMutableSet *gPreviewCovers;
static os_unfair_lock gCoverLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable *gCoveredPreviews;
static NSHashTable *gBlockedConnections;
static NSMapTable *gPreviewSuperlayers;
static char kMyVCamBlockedConnectionKey;
static char kMyVCamHostOverlayKey;
static __thread int gMyVCamInCoverLayout;
static __thread int gMyVCamRestoringPreview;
static __thread int gMyVCamForcingLive;
static __thread int gMyVCamInDelegateHook;
static __thread int gMyVCamInConnectionHook;
static __thread int gMyVCamInLayerInsert;
static BOOL gPreviewForceCopy = NO;
static int gMyVCamStartDepth = 0;
static __thread int gMyVCamInStop;

static void MyVCamC1B_MatchTick(uint64_t generation);
static BOOL MyVCamC1C_SessionDidStart(uint64_t generation);
static void MyVCamC1C_ScheduleEnable(uint64_t generation);
static void MyVCamC1C_EnableOnQueue(uint64_t generation, int attempt, int prepareFailures);
static void MyVCamPreview_Start(void);
static void MyVCamPreview_Stop(void);
static BOOL MyVCamPreview_SessionIsLive(void);

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
    NSLog(@"%s sample replaced yes=%d", kMyVCamDiagPrefix, replaced ? 1 : 0);
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

static BOOL MyVCamC1C_CopyLibraryPath(const char *leaf, char *buffer, size_t size) {
    if (buffer == NULL || size == 0 || leaf == NULL) {
        return NO;
    }
    buffer[0] = '\0';
    NSArray<NSString *> *libraries = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
                                                                          NSUserDomainMask,
                                                                          YES);
    NSString *library = libraries.firstObject;
    if (library.length == 0) {
        NSString *home = NSHomeDirectory();
        if (home.length == 0) {
            return NO;
        }
        library = [home stringByAppendingPathComponent:@"Library"];
    }
    NSString *path = [library stringByAppendingPathComponent:[NSString stringWithUTF8String:leaf]];
    return [path getFileSystemRepresentation:buffer maxLength:size];
}

static BOOL MyVCamC1C_CopyRealJBPath(const char *linkPath, const char *suffix, char *buffer, size_t size) {
    char root[PATH_MAX];
    ssize_t length = 0;
    int wrote = 0;

    if (buffer == NULL || size == 0 || linkPath == NULL || suffix == NULL) {
        return NO;
    }
    buffer[0] = '\0';
    length = readlink(linkPath, root, sizeof(root) - 1);
    if (length <= 0 || (size_t)length >= sizeof(root)) {
        return NO;
    }
    root[length] = '\0';
    if (root[0] != '/') {
        return NO;
    }
    wrote = snprintf(buffer, size, "%s%s", root, suffix);
    return wrote > 0 && (size_t)wrote < size;
}

/// Non-empty regular file. access() is not used: inside Camera it returns
/// EPERM for Documents and can do the same for the /var/jb symlink even when
/// open() of the real jbroot path succeeds.
static BOOL MyVCamC1C_OpenRegular(const char *path, int *outErrno) {
    int fd = -1;
    struct stat info;
    int statOK = 0;

    memset(&info, 0, sizeof(info));

    if (path == NULL || path[0] == '\0') {
        return NO;
    }
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        if (outErrno != NULL && errno != 0) {
            *outErrno = errno;
        }
        return NO;
    }
    statOK = fstat(fd, &info) == 0;
    if (!statOK && outErrno != NULL) {
        *outErrno = errno;
    }
    close(fd);
    if (!statOK || !S_ISREG(info.st_mode) || info.st_size <= 0) {
        if (outErrno != NULL && *outErrno == 0) {
            *outErrno = EINVAL;
        }
        return NO;
    }
    if (outErrno != NULL) {
        *outErrno = 0;
    }
    return YES;
}

static void MyVCamC1C_ReadStatus(char *buffer, size_t size) {
    char libraryStatus[PATH_MAX];
    char realStatus[PATH_MAX];
    const char *paths[4];
    int count = 0;

    if (buffer == NULL || size == 0) {
        return;
    }
    buffer[0] = '\0';
    if (MyVCamC1C_CopyLibraryPath("MyVCam/mirror.status", libraryStatus, sizeof(libraryStatus))) {
        paths[count++] = libraryStatus;
    }
    paths[count++] = kMyVCamMirrorStatusPath;
    if (MyVCamC1C_CopyRealJBPath("/var/jb", "/var/mobile/Library/MyVCam/mirror.status", realStatus, sizeof(realStatus)) ||
        MyVCamC1C_CopyRealJBPath("/private/var/jb", "/var/mobile/Library/MyVCam/mirror.status", realStatus, sizeof(realStatus))) {
        paths[count++] = realStatus;
    }
    for (int index = 0; index < count; index++) {
        int fd = open(paths[index], O_RDONLY);
        ssize_t countRead = 0;
        if (fd < 0) {
            continue;
        }
        countRead = read(fd, buffer, size - 1);
        close(fd);
        if (countRead < 0) {
            buffer[0] = '\0';
            continue;
        }
        buffer[countRead] = '\0';
        for (ssize_t cursor = 0; cursor < countRead; cursor++) {
            if (buffer[cursor] == '\n' || buffer[cursor] == '\r') {
                buffer[cursor] = '\0';
                break;
            }
        }
        if (buffer[0] != '\0') {
            return;
        }
    }
}

static void MyVCamC1C_ContainerFromStatus(const char *status, char *buffer, size_t size) {
    const char *marker = NULL;
    size_t length = 0;

    if (buffer == NULL || size == 0) {
        return;
    }
    buffer[0] = '\0';
    if (status == NULL) {
        return;
    }
    marker = strstr(status, "container=");
    if (marker == NULL) {
        return;
    }
    marker += strlen("container=");
    if (marker[0] != '/') {
        return;
    }
    while (marker[length] != '\0' && marker[length] != ' ' && marker[length] != '\n') {
        length++;
    }
    if (length == 0 || length >= size) {
        return;
    }
    memcpy(buffer, marker, length);
    buffer[length] = '\0';
}

static NSArray<UIWindow *> *MyVCamPreview_Windows(void);

static os_unfair_lock gStatusLock = OS_UNFAIR_LOCK_INIT;
static char gStatusPath[256];
static char gStatusError[160];
static char gStatusHost[64];
static char gStatusAbove[64];
static char gStatusContainer[64];
static char gStatusSlot[24];
static char gStatusReason[24];
static char gStatusHierarchy[384];
static char gStatusFrame[48];
static char gStatusWhere[16];
static char gStatusProc[64];
static int gStatusCtor = 0;
static int gStatusInit = 0;
static int gStatusFeedErrno = 0;
static int gStatusPrepare = 0;
static int gStatusWindows = 0;
static int gStatusLayers = 0;
static int gStatusHostLayer = 0;
static int gStatusInWindow = 0;
static int gStatusLiveHidden = 0;
static int gStatusSuperlayer = 0;
static int gStatusConn = -1;
static int gStatusEnqueue = -1;
static int gStatusPxW = 0;
static int gStatusPxH = 0;
static int gStatusWriteErrno = 0;
static int gStatusHostCover = 0;
static unsigned gStatusBlocks = 0;
static unsigned gStatusDetaches = 0;
static time_t gStatusLastWrite = 0;

static void MyVCamStatus_CopyToken(char *dest, size_t size, const char *src) {
    size_t used = 0;

    if (dest == NULL || size == 0) {
        return;
    }
    if (src == NULL || src[0] == '\0') {
        dest[0] = '-';
        if (size > 1) {
            dest[1] = '\0';
        }
        return;
    }
    for (size_t index = 0; src[index] != '\0' && used + 1 < size; index++) {
        unsigned char ch = (unsigned char)src[index];
        int ok = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
                 (ch >= '0' && ch <= '9') || ch == '/' || ch == '.' ||
                 ch == '_' || ch == '-' || ch == '+' || ch == ',' || ch == ':' ||
                 ch == '>';
        dest[used++] = (char)(ok ? ch : '_');
    }
    if (used == 0) {
        dest[0] = '-';
        dest[1] = '\0';
        return;
    }
    dest[used] = '\0';
}

static const char *MyVCamLoad_LastComponent(const char *path) {
    const char *slash = NULL;

    if (path == NULL || path[0] == '\0') {
        return path;
    }
    slash = strrchr(path, '/');
    if (slash == NULL || slash[1] == '\0') {
        return path;
    }
    return slash + 1;
}

// Prefer the Objective-C process name. Fall back to argv0 (getprogname, then
// the executable path) so the first status line still names the process if
// NSProcessInfo is empty. Called once; later flushes keep the token.
static void MyVCamStatus_RememberProcess(void) {
    char token[64];
    char executable[1024];
    const char *chosen = NULL;
    uint32_t size = sizeof(executable);

    token[0] = '\0';
    os_unfair_lock_lock(&gStatusLock);
    if (gStatusProc[0] != '\0') {
        os_unfair_lock_unlock(&gStatusLock);
        return;
    }
    os_unfair_lock_unlock(&gStatusLock);

    @autoreleasepool {
        NSString *name = [[NSProcessInfo processInfo] processName];
        const char *utf8 = name.UTF8String;
        if (utf8 != NULL && utf8[0] != '\0') {
            MyVCamStatus_CopyToken(token, sizeof(token), utf8);
            chosen = token;
        }
    }
    if (chosen == NULL || chosen[0] == '\0') {
        chosen = getprogname();
        if (chosen == NULL || chosen[0] == '\0') {
            executable[0] = '\0';
            if (_NSGetExecutablePath(executable, &size) == 0) {
                chosen = MyVCamLoad_LastComponent(executable);
            }
        }
        MyVCamStatus_CopyToken(token, sizeof(token), chosen);
    }
    os_unfair_lock_lock(&gStatusLock);
    if (gStatusProc[0] == '\0') {
        snprintf(gStatusProc, sizeof(gStatusProc), "%s", token[0] != '\0' ? token : "-");
    }
    os_unfair_lock_unlock(&gStatusLock);
}

static void MyVCamStatus_MkdirParent(const char *filePath) {
    char dir[PATH_MAX];
    char *slash = NULL;
    size_t length = 0;

    if (filePath == NULL) {
        return;
    }
    length = strlen(filePath);
    if (length == 0 || length >= sizeof(dir)) {
        return;
    }
    memcpy(dir, filePath, length + 1);
    slash = strrchr(dir, '/');
    if (slash == NULL || slash == dir) {
        return;
    }
    *slash = '\0';
    if (mkdir(dir, 0755) != 0 && errno != EEXIST) {
        // The parent may already exist, or Camera may not be allowed to create it.
    }
}

static int MyVCamStatus_WriteFile(const char *path, const char *text) {
    int fd = -1;
    size_t length = 0;
    size_t written = 0;

    if (path == NULL || path[0] == '\0' || text == NULL) {
        return EINVAL;
    }
    fd = open(path, O_WRONLY | O_TRUNC);
    if (fd < 0 && errno == ENOENT) {
        MyVCamStatus_MkdirParent(path);
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    }
    if (fd < 0) {
        return errno != 0 ? errno : EIO;
    }
    if (fchmod(fd, 0666) != 0) {
        // A pre-created 0666 file is already writable. A 0755 directory can
        // still reject chmod. The write itself is what Filza needs.
    }
    length = strlen(text);
    while (written < length) {
        ssize_t step = write(fd, text + written, length - written);
        if (step < 0) {
            int err = errno;
            if (err == EINTR) {
                continue;
            }
            close(fd);
            return err != 0 ? err : EIO;
        }
        written += (size_t)step;
    }
    if (close(fd) != 0) {
        return errno != 0 ? errno : EIO;
    }
    return 0;
}

static void MyVCamStatus_Sibling(const char *videoPath, const char *name, char *out, size_t size) {
    const char *slash = NULL;
    int wrote = 0;

    if (out == NULL || size == 0) {
        return;
    }
    out[0] = '\0';
    if (videoPath == NULL || name == NULL) {
        return;
    }
    slash = strrchr(videoPath, '/');
    if (slash == NULL || slash == videoPath) {
        return;
    }
    wrote = snprintf(out, size, "%.*s/%s", (int)(slash - videoPath), videoPath, name);
    if (wrote <= 0 || (size_t)wrote >= size) {
        out[0] = '\0';
    }
}

static void MyVCamStatus_Format(char *line, size_t size) {
    char path[256];
    char error[160];
    char host[64];
    char above[64];
    char container[64];
    char slot[24];
    char reason[24];
    char hierarchy[384];
    char frame[48];
    char where[16];
    char proc[64];
    int ctor = 0;
    int initFlag = 0;
    int feedErrno = 0;
    int prepare = 0;
    int windows = 0;
    int layers = 0;
    int hostLayer = 0;
    int inWindow = 0;
    int liveHidden = 0;
    int superlayer = 0;
    int conn = -1;
    int enqueue = -1;
    int pxW = 0;
    int pxH = 0;
    int writeErrno = 0;
    int hostCover = 0;
    unsigned blocks = 0;
    unsigned detaches = 0;
    int session = 0;
    int phase = 0;
    const char *phaseName = "warmup";

    os_unfair_lock_lock(&gStatusLock);
    ctor = gStatusCtor;
    initFlag = gStatusInit;
    feedErrno = gStatusFeedErrno;
    prepare = gStatusPrepare;
    windows = gStatusWindows;
    layers = gStatusLayers;
    hostLayer = gStatusHostLayer;
    inWindow = gStatusInWindow;
    liveHidden = gStatusLiveHidden;
    superlayer = gStatusSuperlayer;
    conn = gStatusConn;
    enqueue = gStatusEnqueue;
    pxW = gStatusPxW;
    pxH = gStatusPxH;
    writeErrno = gStatusWriteErrno;
    hostCover = gStatusHostCover;
    blocks = gStatusBlocks;
    detaches = gStatusDetaches;
    memcpy(path, gStatusPath, sizeof(path));
    memcpy(error, gStatusError, sizeof(error));
    memcpy(host, gStatusHost, sizeof(host));
    memcpy(above, gStatusAbove, sizeof(above));
    memcpy(container, gStatusContainer, sizeof(container));
    memcpy(slot, gStatusSlot, sizeof(slot));
    memcpy(reason, gStatusReason, sizeof(reason));
    memcpy(hierarchy, gStatusHierarchy, sizeof(hierarchy));
    memcpy(frame, gStatusFrame, sizeof(frame));
    memcpy(where, gStatusWhere, sizeof(where));
    memcpy(proc, gStatusProc, sizeof(proc));
    os_unfair_lock_unlock(&gStatusLock);

    os_unfair_lock_lock(&gLock);
    session = gCaptureSessionRunning ? 1 : 0;
    phase = (int)gPhase;
    os_unfair_lock_unlock(&gLock);
    if (phase == (int)MyVCamPhaseLive) {
        phaseName = "live";
    } else if (phase == (int)MyVCamPhaseDisabled) {
        phaseName = "disabled";
    }
    snprintf(line,
             size,
             "version=%s proc=%s ctor=%d init=%d phase=%s session=%d feed_errno=%d prepare=%d path=%s err=%s windows=%d layers=%d host=%s host_layer=%d above=%s container=%s slot=%s in_window=%d frame=%s live_hidden=%d superlayer=%d conn=%d enqueue=%d reason=%s px=%dx%d host_cover=%d blocks=%u detaches=%u write=%s write_errno=%d hierarchy=%s\n",
             kMyVCamStatusVersion,
             proc[0] != '\0' ? proc : "-",
             ctor,
             initFlag,
             phaseName,
             session,
             feedErrno,
             prepare,
             path[0] != '\0' ? path : "-",
             error[0] != '\0' ? error : "-",
             windows,
             layers,
             host[0] != '\0' ? host : "-",
             hostLayer,
             above[0] != '\0' ? above : "-",
             container[0] != '\0' ? container : "-",
             slot[0] != '\0' ? slot : "-",
             inWindow,
             frame[0] != '\0' ? frame : "-",
             liveHidden,
             superlayer,
             conn,
             enqueue,
             reason[0] != '\0' ? reason : "-",
             pxW,
             pxH,
             hostCover,
             blocks,
             detaches,
             where[0] != '\0' ? where : "-",
             writeErrno,
             hierarchy[0] != '\0' ? hierarchy : "-");
}

static void MyVCamStatus_WriteAll(const char *line, int *jbOK, int *containerOK, int *homeOK, int *errOut) {
    char realPath[PATH_MAX];
    char privatePath[PATH_MAX];
    char containerVideo[PATH_MAX];
    char containerStatus[PATH_MAX];
    char homePath[PATH_MAX];
    char mirror[1024];
    int jbErrno = ENOENT;
    int containerErrno = ENOENT;
    int homeErrno = ENOENT;

    if (jbOK != NULL) {
        *jbOK = 0;
    }
    if (containerOK != NULL) {
        *containerOK = 0;
    }
    if (homeOK != NULL) {
        *homeOK = 0;
    }
    realPath[0] = '\0';
    if (!MyVCamC1C_CopyRealJBPath("/var/jb", "/var/mobile/Library/MyVCam/runtime.status", realPath, sizeof(realPath))) {
        MyVCamC1C_CopyRealJBPath("/private/var/jb", "/var/mobile/Library/MyVCam/runtime.status", realPath, sizeof(realPath));
    }
    if (realPath[0] != '\0') {
        jbErrno = MyVCamStatus_WriteFile(realPath, line);
    }
    if (jbErrno != 0) {
        jbErrno = MyVCamStatus_WriteFile(kMyVCamRuntimeStatusPath, line);
    }
    if (jbErrno != 0 && snprintf(privatePath, sizeof(privatePath), "/private%s", kMyVCamRuntimeStatusPath) > 0) {
        jbErrno = MyVCamStatus_WriteFile(privatePath, line);
    }
    if (jbOK != NULL) {
        *jbOK = jbErrno == 0;
    }

    mirror[0] = '\0';
    containerVideo[0] = '\0';
    containerStatus[0] = '\0';
    MyVCamC1C_ReadStatus(mirror, sizeof(mirror));
    MyVCamC1C_ContainerFromStatus(mirror, containerVideo, sizeof(containerVideo));
    MyVCamStatus_Sibling(containerVideo, "runtime.status", containerStatus, sizeof(containerStatus));
    if (containerStatus[0] != '\0') {
        containerErrno = MyVCamStatus_WriteFile(containerStatus, line);
        if (containerOK != NULL) {
            *containerOK = containerErrno == 0;
        }
    }

    homePath[0] = '\0';
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        NSString *runtime = [home stringByAppendingPathComponent:@"Library/MyVCam/runtime.status"];
        if (runtime.length > 0 &&
            [runtime getFileSystemRepresentation:homePath maxLength:sizeof(homePath)] &&
            strcmp(homePath, containerStatus) != 0) {
            homeErrno = MyVCamStatus_WriteFile(homePath, line);
            if (homeOK != NULL) {
                *homeOK = homeErrno == 0;
            }
        }
    }
    if (errOut != NULL) {
        if (jbErrno == 0) {
            *errOut = 0;
        } else if (containerErrno == 0 || homeErrno == 0) {
            *errOut = 0;
        } else {
            *errOut = jbErrno != ENOENT ? jbErrno : (containerErrno != ENOENT ? containerErrno : homeErrno);
        }
    }
}

static void MyVCamStatus_Flush(int force) {
    char line[2048];
    time_t now = time(NULL);
    int jbOK = 0;
    int containerOK = 0;
    int homeOK = 0;
    int writeErrno = 0;
    const char *where = "fail";
    static int loggedErrno = -2;
    static char loggedWhere[16];

    os_unfair_lock_lock(&gStatusLock);
    if (!force && gStatusLastWrite != 0 && now == gStatusLastWrite) {
        os_unfair_lock_unlock(&gStatusLock);
        return;
    }
    gStatusLastWrite = now != 0 ? now : 1;
    os_unfair_lock_unlock(&gStatusLock);

    MyVCamStatus_RememberProcess();
    MyVCamStatus_Format(line, sizeof(line));
    MyVCamStatus_WriteAll(line, &jbOK, &containerOK, &homeOK, &writeErrno);
    if (jbOK) {
        where = "jb";
        writeErrno = 0;
    } else if (containerOK) {
        where = "container";
        writeErrno = 0;
    } else if (homeOK) {
        where = "home";
        writeErrno = 0;
    } else {
        where = "fail";
    }
    os_unfair_lock_lock(&gStatusLock);
    MyVCamStatus_CopyToken(gStatusWhere, sizeof(gStatusWhere), where);
    gStatusWriteErrno = writeErrno;
    os_unfair_lock_unlock(&gStatusLock);
    MyVCamStatus_Format(line, sizeof(line));
    MyVCamStatus_WriteAll(line, &jbOK, &containerOK, &homeOK, &writeErrno);

    if (loggedErrno != writeErrno || strcmp(loggedWhere, where) != 0) {
        loggedErrno = writeErrno;
        snprintf(loggedWhere, sizeof(loggedWhere), "%s", where);
        NSLog(@"%s runtime status write=%s errno=%d path=%s",
              kMyVCamDiagPrefix,
              where,
              writeErrno,
              kMyVCamRuntimeStatusPath);
    }
}

static void MyVCamStatus_Mark(int ctor, int initFlag) {
    MyVCamStatus_RememberProcess();
    os_unfair_lock_lock(&gStatusLock);
    if (ctor) {
        gStatusCtor = 1;
    }
    if (initFlag) {
        gStatusInit = 1;
    }
    os_unfair_lock_unlock(&gStatusLock);
    MyVCamStatus_Flush(1);
}

static void MyVCamStatus_SetFeed(const char *path, int err, const char *message, int prepare, int force) {
    os_unfair_lock_lock(&gStatusLock);
    // NULL leaves the previous token. "" clears it. A retry must not wipe
    // the reader error SessionDidStart just stored.
    if (path != NULL) {
        MyVCamStatus_CopyToken(gStatusPath, sizeof(gStatusPath), path);
    }
    if (message != NULL) {
        MyVCamStatus_CopyToken(gStatusError, sizeof(gStatusError), message);
        gStatusFeedErrno = err;
    } else if (path != NULL) {
        gStatusFeedErrno = err;
    }
    if (prepare >= 0) {
        gStatusPrepare = prepare;
    }
    os_unfair_lock_unlock(&gStatusLock);
    MyVCamStatus_Flush(force);
}

static void MyVCamStatus_AddBlock(void) {
    os_unfair_lock_lock(&gStatusLock);
    gStatusBlocks += 1;
    os_unfair_lock_unlock(&gStatusLock);
}

static void MyVCamStatus_AddDetach(void) {
    os_unfair_lock_lock(&gStatusLock);
    gStatusDetaches += 1;
    os_unfair_lock_unlock(&gStatusLock);
}

static void MyVCamStatus_SetEnqueue(int ok, const char *reason, int width, int height, int force) {
    os_unfair_lock_lock(&gStatusLock);
    gStatusEnqueue = ok;
    gStatusPxW = width;
    gStatusPxH = height;
    MyVCamStatus_CopyToken(gStatusReason, sizeof(gStatusReason), reason);
    os_unfair_lock_unlock(&gStatusLock);
    MyVCamStatus_Flush(force);
}

static void MyVCamStatus_Append(char *dest, size_t size, size_t *used, const char *text) {
    int wrote = 0;

    if (dest == NULL || used == NULL || text == NULL || *used >= size) {
        return;
    }
    wrote = snprintf(dest + *used, size - *used, "%s", text);
    if (wrote < 0 || (size_t)wrote >= size - *used) {
        dest[size - 1] = '\0';
        *used = size - 1;
        return;
    }
    *used += (size_t)wrote;
}

static void MyVCamStatus_SetCover(AVCaptureVideoPreviewLayer *preview,
                                  UIView *host,
                                  int hostLayer,
                                  UIView *above,
                                  UIView *container,
                                  const char *slot,
                                  UIView *overlay,
                                  int force) {
    char hierarchy[384];
    char frame[48];
    char hostName[64];
    char aboveName[64];
    char containerName[64];
    UIView *nodes[8];
    int count = 0;
    int windows = 0;
    int layers = 0;
    int inWindow = 0;
    int liveHidden = 0;
    int hasSuperlayer = 0;
    int conn = -1;
    int hostCover = 0;
    size_t used = 0;
    id sibling = nil;

    hierarchy[0] = '\0';
    frame[0] = '\0';
    MyVCamStatus_CopyToken(hostName, sizeof(hostName), host != nil ? class_getName(object_getClass(host)) : NULL);
    MyVCamStatus_CopyToken(aboveName, sizeof(aboveName), above != nil ? class_getName(object_getClass(above)) : NULL);
    MyVCamStatus_CopyToken(containerName, sizeof(containerName), container != nil ? class_getName(object_getClass(container)) : NULL);
    if (host != nil) {
        for (UIView *walk = host; walk != nil && count < 8; walk = walk.superview) {
            nodes[count++] = walk;
        }
        for (int index = count - 1; index >= 0; index--) {
            if (used != 0) {
                MyVCamStatus_Append(hierarchy, sizeof(hierarchy), &used, "/");
            }
            MyVCamStatus_Append(hierarchy, sizeof(hierarchy), &used, class_getName(object_getClass(nodes[index])));
        }
    } else {
        for (UIWindow *window in MyVCamPreview_Windows()) {
            UIView *root = window.rootViewController.view;
            if (used != 0) {
                MyVCamStatus_Append(hierarchy, sizeof(hierarchy), &used, ",");
            }
            MyVCamStatus_Append(hierarchy, sizeof(hierarchy), &used, class_getName(object_getClass(window)));
            MyVCamStatus_Append(hierarchy, sizeof(hierarchy), &used, ">");
            MyVCamStatus_Append(hierarchy, sizeof(hierarchy), &used, root != nil ? class_getName(object_getClass(root)) : "-");
            windows += 1;
        }
    }
    if (windows == 0) {
        windows = (int)MyVCamPreview_Windows().count;
    }
    layers = gPreviewLayers != nil ? (int)gPreviewLayers.allObjects.count : 0;
    if (overlay != nil) {
        snprintf(frame, sizeof(frame), "%.0f,%.0f,%.0f,%.0f",
                 CGRectGetMinX(overlay.frame),
                 CGRectGetMinY(overlay.frame),
                 CGRectGetWidth(overlay.frame),
                 CGRectGetHeight(overlay.frame));
        inWindow = overlay.window != nil;
    } else if (host != nil) {
        inWindow = host.window != nil;
    }
    if (preview != nil) {
        liveHidden = preview.hidden || preview.superlayer == nil;
        hasSuperlayer = preview.superlayer != nil;
        @try {
            AVCaptureConnection *connection = preview.connection;
            if (connection != nil) {
                conn = connection.enabled ? 1 : 0;
            }
        } @catch (NSException *exception) {
            (void)exception;
            conn = -1;
        }
        sibling = objc_getAssociatedObject(preview, &kMyVCamHostOverlayKey);
        if ([sibling isKindOfClass:[UIView class]]) {
            hostCover = ((UIView *)sibling).window != nil;
        }
    }

    os_unfair_lock_lock(&gStatusLock);
    gStatusWindows = windows;
    gStatusLayers = layers;
    gStatusHostLayer = hostLayer;
    gStatusInWindow = inWindow;
    gStatusLiveHidden = liveHidden ? 1 : 0;
    gStatusSuperlayer = hasSuperlayer;
    gStatusConn = conn;
    gStatusHostCover = hostCover;
    MyVCamStatus_CopyToken(gStatusHost, sizeof(gStatusHost), hostName);
    MyVCamStatus_CopyToken(gStatusAbove, sizeof(gStatusAbove), aboveName);
    MyVCamStatus_CopyToken(gStatusContainer, sizeof(gStatusContainer), containerName);
    MyVCamStatus_CopyToken(gStatusSlot, sizeof(gStatusSlot), slot);
    MyVCamStatus_CopyToken(gStatusFrame, sizeof(gStatusFrame), frame);
    MyVCamStatus_CopyToken(gStatusHierarchy, sizeof(gStatusHierarchy), hierarchy);
    os_unfair_lock_unlock(&gStatusLock);
    MyVCamStatus_Flush(force);
}

/// Empty regular file still counts. The disable marker is created with no body.
static BOOL MyVCamC1C_OpenMarker(const char *path) {
    int fd = -1;
    struct stat info;
    BOOL marker = NO;

    if (path == NULL || path[0] == '\0') {
        return NO;
    }
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return NO;
    }
    marker = fstat(fd, &info) == 0 && S_ISREG(info.st_mode);
    close(fd);
    return marker;
}

static BOOL MyVCamC1C_DisableFilePresent(void) {
    char libraryDisable[PATH_MAX];
    char realDisable[PATH_MAX];
    char status[1024];
    char containerVideo[PATH_MAX];
    char containerDisable[PATH_MAX];
    const char *candidates[6];
    int count = 0;

    // A marker counts only when this process can open it. EPERM on Documents
    // is not a disable file.
    if (MyVCamC1C_CopyLibraryPath("MyVCam/disable", libraryDisable, sizeof(libraryDisable))) {
        candidates[count++] = libraryDisable;
    }
    if (MyVCamC1C_CopyRealJBPath("/var/jb", "/var/mobile/Library/MyVCam/disable", realDisable, sizeof(realDisable))) {
        candidates[count++] = realDisable;
    }
    candidates[count++] = kMyVCamMirrorDisablePath;
    candidates[count++] = "/private/var/jb/var/mobile/Library/MyVCam/disable";
    candidates[count++] = kMyVCamDisablePath;
    MyVCamC1C_ReadStatus(status, sizeof(status));
    MyVCamC1C_ContainerFromStatus(status, containerVideo, sizeof(containerVideo));
    if (containerVideo[0] == '/') {
        NSString *video = [NSString stringWithUTF8String:containerVideo];
        NSString *disable = [[video stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"disable"];
        if ([disable getFileSystemRepresentation:containerDisable maxLength:sizeof(containerDisable)]) {
            candidates[count++] = containerDisable;
        }
    }
    for (int index = 0; index < count; index++) {
        if (MyVCamC1C_OpenMarker(candidates[index])) {
            return YES;
        }
    }
    return NO;
}

/// Container library, real jbroot path, /var/jb symlink, then Documents.
/// The Documents constant stays in the binary. The path that opens is the
/// one attach uses.
static const char *MyVCamC1C_ReadableVideoPath(int *outErrno) {
    static char chosen[PATH_MAX];
    char libraryVideo[PATH_MAX];
    char realVideo[PATH_MAX];
    char privateVideo[PATH_MAX];
    char status[1024];
    char containerVideo[PATH_MAX];
    char documentsPrivate[PATH_MAX];
    const char *candidates[8];
    int count = 0;
    int savedErrno = 0;
    const char *primary = MyVCamManagerTestVideoPathUTF8;

    if (MyVCamC1C_CopyLibraryPath("MyVCam/test.mp4", libraryVideo, sizeof(libraryVideo))) {
        candidates[count++] = libraryVideo;
    }
    if (MyVCamC1C_CopyRealJBPath("/var/jb", "/var/mobile/Library/MyVCam/test.mp4", realVideo, sizeof(realVideo)) ||
        MyVCamC1C_CopyRealJBPath("/private/var/jb", "/var/mobile/Library/MyVCam/test.mp4", realVideo, sizeof(realVideo))) {
        candidates[count++] = realVideo;
    }
    candidates[count++] = kMyVCamMirrorVideoPath;
    if (snprintf(privateVideo, sizeof(privateVideo), "/private%s", kMyVCamMirrorVideoPath) > 0) {
        candidates[count++] = privateVideo;
    }
    MyVCamC1C_ReadStatus(status, sizeof(status));
    MyVCamC1C_ContainerFromStatus(status, containerVideo, sizeof(containerVideo));
    if (containerVideo[0] == '/') {
        candidates[count++] = containerVideo;
    }
    if (primary != NULL) {
        candidates[count++] = primary;
        if (snprintf(documentsPrivate, sizeof(documentsPrivate), "/private%s", primary) > 0) {
            candidates[count++] = documentsPrivate;
        }
    }

    for (int index = 0; index < count; index++) {
        int candidateErrno = 0;
        if (MyVCamC1C_OpenRegular(candidates[index], &candidateErrno)) {
            if (strlen(candidates[index]) >= sizeof(chosen)) {
                continue;
            }
            memcpy(chosen, candidates[index], strlen(candidates[index]) + 1);
            if (outErrno != NULL) {
                *outErrno = 0;
            }
            return chosen;
        }
        if (candidateErrno != 0) {
            savedErrno = candidateErrno;
        }
    }
    if (outErrno != NULL) {
        *outErrno = savedErrno;
    }
    return NULL;
}

static BOOL MyVCamC1C_SessionDidStart(uint64_t generation) {
    // Runs on com.myvcam.enable, off the capture delegate queue and off
    // -startRunning. A missing file returns NO and does not arm the timer.
    if (!MyVCamC1C_GenerationIsCurrent(generation)) {
        return NO;
    }

    int videoErrno = 0;
    const char *readable = MyVCamC1C_ReadableVideoPath(&videoErrno);
    if (readable == NULL) {
        MyVCamStatus_SetFeed("", videoErrno, "not_readable", -1, 1);
        NSLog(@"%s feed not started: test video not readable path=%s mirror=%s errno=%d",
              kMyVCamC1CPrefix,
              MyVCamManagerTestVideoPathUTF8,
              kMyVCamMirrorVideoPath,
              videoErrno);
        return NO;
    }
    MyVCamManager *manager = [MyVCamManager sharedManager];
    NSString *path = [NSString stringWithUTF8String:readable];
    if (path.length == 0) {
        MyVCamStatus_SetFeed("", EINVAL, "empty_path", -1, 1);
        NSLog(@"%s feed not started: test video path is empty", kMyVCamC1CPrefix);
        return NO;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:path isDirectory:NO];
    [manager attachMediaFileURL:fileURL];
    NSError *error = nil;
    BOOL started = [manager startWithError:&error];
    if (!MyVCamC1C_GenerationIsCurrent(generation)) {
        [manager stop];
        MyVCamStatus_SetFeed(readable, 0, "session_ended", -1, 1);
        NSLog(@"%s feed not started: capture session ended during prepare", kMyVCamC1CPrefix);
        return NO;
    }
    if (!started) {
        const char *message = error.localizedDescription.UTF8String;
        MyVCamStatus_SetFeed(readable, 0, message != NULL ? message : "prepare_failed", -1, 1);
        NSLog(@"%s feed not started path=%s error=%@", kMyVCamC1CPrefix, readable, error);
        return NO;
    }
    os_unfair_lock_lock(&gLock);
    if (gCaptureSessionRunning && gSessionGeneration == generation) {
        gPhase = MyVCamPhaseLive;
    }
    os_unfair_lock_unlock(&gLock);
    NSLog(@"%s feed started path=%s", kMyVCamC1CPrefix, readable);
    MyVCamStatus_SetFeed(readable, 0, "started", 0, 1);
    dispatch_async(gMatchQueue, ^{
        MyVCamC1B_MatchTick(generation);
    });
    MyVCamPreview_Start();
    return YES;
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

static void MyVCamC1C_LogFileProbe(const char *role, const char *path) {
    NSString *nsPath = path != NULL ? [NSString stringWithUTF8String:path] : nil;
    NSError *error = nil;
    NSDictionary *attrs = nil;
    if (nsPath.length > 0) {
        attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:nsPath error:&error];
    }
    unsigned long long size = 0;
    if (attrs != nil) {
        size = [attrs fileSize];
    }
    NSLog(@"%s %s path=%s exists=%d size=%llu error_domain=%@ error_code=%ld",
          kMyVCamDiagPrefix,
          role != NULL ? role : "file",
          path != NULL ? path : "(null)",
          attrs != nil ? 1 : 0,
          size,
          error.domain ?: @"-",
          (long)(error != nil ? error.code : 0));
}

static void MyVCamC1C_LogCopyDiagnostics(const char *status) {
    int copied = 0;
    int copyErrno = 0;
    int sawCopied = 0;
    if (status != NULL) {
        const char *copiedKey = strstr(status, "copied=");
        const char *errnoKey = strstr(status, "copy_errno=");
        if (copiedKey != NULL) {
            copied = atoi(copiedKey + strlen("copied="));
            sawCopied = 1;
        }
        if (errnoKey != NULL) {
            copyErrno = atoi(errnoKey + strlen("copy_errno="));
        }
    }
    // The helper is C and reports POSIX errno. NSPOSIXErrorDomain is that
    // code's Foundation domain so the device log has domain and code.
    NSLog(@"%s copy success=%d error_domain=%@ error_code=%d status_present=%d",
          kMyVCamDiagPrefix,
          (sawCopied && copied != 0) ? 1 : 0,
          @"NSPOSIXErrorDomain",
          copyErrno,
          status != NULL && status[0] != '\0' ? 1 : 0);
}

static void MyVCamC1C_LogMirrorStatus(int attempt, int videoErrno) {
    char status[1024];
    char libraryVideo[PATH_MAX];
    if (attempt != 0 && (attempt % 10) != 0) {
        return;
    }
    MyVCamC1C_ReadStatus(status, sizeof(status));
    libraryVideo[0] = '\0';
    MyVCamC1C_CopyLibraryPath("MyVCam/test.mp4", libraryVideo, sizeof(libraryVideo));
    MyVCamC1C_LogFileProbe("source", MyVCamManagerTestVideoPathUTF8);
    MyVCamC1C_LogFileProbe("dest", kMyVCamMirrorVideoPath);
    MyVCamC1C_LogCopyDiagnostics(status);
    if (status[0] == '\0') {
        NSLog(@"%s mirror status unreadable errno=%d library=%s",
              kMyVCamC1CPrefix,
              videoErrno,
              libraryVideo);
        return;
    }
    NSLog(@"%s mirror status %s library=%s errno=%d",
          kMyVCamC1CPrefix,
          status,
          libraryVideo,
          videoErrno);
}

static void MyVCamC1C_EnableOnQueue(uint64_t generation, int attempt, int prepareFailures) {
    // Runs on com.myvcam.enable. Not gated on capture callbacks: the
    // viewfinder does not deliver those, so a callback counter never ends.
    // A miss does not stop this session. 0.2.7 gave up after four seconds
    // and later startRunning calls did not schedule enable again.
    @autoreleasepool {
    if (!MyVCamC1C_GenerationIsCurrent(generation)) {
        return;
    }
    if (MyVCamC1C_DisableFilePresent()) {
        os_unfair_lock_lock(&gLock);
        if (gCaptureSessionRunning && gSessionGeneration == generation) {
            gPhase = MyVCamPhaseDisabled;
        }
        os_unfair_lock_unlock(&gLock);
        MyVCamStatus_SetFeed("", 0, "disable", -1, 1);
        NSLog(@"%s feed not started: disable file %s (delete it and reopen Camera to re-enable)",
              kMyVCamC1CPrefix,
              kMyVCamDisablePath);
        return;
    }

    int videoErrno = 0;
    if (MyVCamC1C_ReadableVideoPath(&videoErrno) == NULL) {
        MyVCamC1C_LogMirrorStatus(attempt, videoErrno);
        MyVCamStatus_SetFeed("", videoErrno, "not_readable", attempt, attempt == 0);
        if (attempt == 0) {
            NSLog(@"%s feed waiting for test video path=%s mirror=%s errno=%d",
                  kMyVCamC1CPrefix,
                  MyVCamManagerTestVideoPathUTF8,
                  kMyVCamMirrorVideoPath,
                  videoErrno);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), gEnableQueue, ^{
            MyVCamC1C_EnableOnQueue(generation, attempt + 1, prepareFailures);
        });
        return;
    }

    os_unfair_lock_lock(&gLock);
    BOOL current = gCaptureSessionRunning && gSessionGeneration == generation && gPhase == MyVCamPhaseWarmup;
    os_unfair_lock_unlock(&gLock);
    if (!current) {
        return;
    }
    if (prepareFailures == 0) {
        MyVCamC1C_LogMirrorStatus(0, 0);
        NSLog(@"%s passthrough warmup finished (session up)", kMyVCamC1CPrefix);
    }
    if (!MyVCamC1C_SessionDidStart(generation)) {
        // 0.2.12 stopped after eight prepare failures and left Photo mode on
        // the live camera for the rest of the session. Keep trying. The
        // status file records the last error and the attempt count.
        int next = prepareFailures + 1;
        int64_t delay = prepareFailures < 8 ? (int64_t)NSEC_PER_SEC : (int64_t)(2 * NSEC_PER_SEC);
        MyVCamStatus_SetFeed(NULL, 0, NULL, next, next == 9);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), gEnableQueue, ^{
            MyVCamC1C_EnableOnQueue(generation, attempt, next);
        });
        return;
    }
    }
}

static void MyVCamC1C_ScheduleEnable(uint64_t generation) {
    // Next turn, off -startRunning.
    dispatch_async(gEnableQueue, ^{
        MyVCamC1C_EnableOnQueue(generation, 0, 0);
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
    static dispatch_once_t hookOnce;
    dispatch_once(&hookOnce, ^{
        NSLog(@"%s hook hit yes=1", kMyVCamDiagPrefix);
    });
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
        // Photo mode can publish the preview after startRunning, or the
        // session can already be running if the hook was installed late.
        if (layer.session.isRunning) {
            MyVCamC1C_NoteSessionStarted();
        }
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

static NSArray<UIWindow *> *MyVCamPreview_Windows(void) {
    // UIApplication.windows is deprecated in the iOS 15 SDK and Theos builds
    // with -Werror. It is still the list Camera's viewfinder is in on
    // iOS 15.3.1 when connectedScenes has not published a window yet.
    // UIWindowScene.windows is walked as well.
    UIApplication *application = [UIApplication sharedApplication];
    NSMutableArray<UIWindow *> *windows = nil;

    if (application == nil) {
        return @[];
    }
    windows = [NSMutableArray array];
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
    return windows;
}

static void MyVCamPreview_ScanWindows(void) {
    for (UIWindow *window in MyVCamPreview_Windows()) {
        MyVCamPreview_ScanLayer(window.layer);
    }
}

/// View whose layer is the preview, or the view that owns the preview as a
/// sublayer. A subview of a view whose layer is AVCaptureVideoPreviewLayer
/// is painted under the live image. The cover is added above that view.
@interface MyVCamPreviewHostView : UIView
@end

static void MyVCamPreview_ClearCoverLinks(MyVCamPreviewHostView *view);
static void MyVCamPreview_RestoreOpacity(AVCaptureVideoPreviewLayer *preview);

@implementation MyVCamPreviewHostView

- (instancetype)initWithFrame:(CGRect)frame {
    AVSampleBufferDisplayLayer *display = nil;

    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }
    // AVSampleBufferDisplayLayer stays transparent until it accepts a frame.
    // Using it as the view's backing layer let the live preview show through
    // a cover that was already in the right slot. A normal opaque view paints
    // the way the shutter does. The display layer is only the video sublayer.
    self.backgroundColor = [UIColor blackColor];
    self.opaque = YES;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    self.layer.backgroundColor = [UIColor blackColor].CGColor;
    self.layer.opaque = YES;
    display = [AVSampleBufferDisplayLayer layer];
    display.frame = self.bounds;
    display.videoGravity = AVLayerVideoGravityResizeAspectFill;
    display.backgroundColor = [UIColor blackColor].CGColor;
    display.contentsScale = UIScreen.mainScreen.scale;
    display.name = kMyVCamPreviewOverlayName;
    [self.layer addSublayer:display];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    for (CALayer *sublayer in self.layer.sublayers) {
        if (![sublayer isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
            continue;
        }
        sublayer.frame = self.bounds;
        sublayer.contentsScale = self.layer.contentsScale;
    }
}

// Removal from the superview is not the end of the cover. Photo mode's
// layout drops subviews it does not own. willMoveToSuperview: used to
// forget the cover and restore the live preview, which put the camera back
// on screen. The cover stays in gPreviewCovers and the next tick reinserts it.
@end

/// View that owns this preview layer. Photo mode's CAMVideoPreviewView does
/// not use AVCaptureVideoPreviewLayer as its backing layer: previewLayerView
/// hosts the live layer as a sublayer. Walk up until a UIView's layer is an
/// ancestor, so a wrapper CALayer between the preview and that view still
/// resolves. previewIsHostLayer is YES only when the UIView's layer is the
/// preview itself.
static UIView *MyVCamPreview_HostFromLayer(CALayer *start) {
    for (CALayer *layer = start; layer != nil; layer = layer.superlayer) {
        id delegate = layer.delegate;
        if ([delegate isKindOfClass:[UIView class]] &&
            ((UIView *)delegate).layer == layer) {
            return (UIView *)delegate;
        }
    }
    return nil;
}

static UIView *MyVCamPreview_HostView(AVCaptureVideoPreviewLayer *preview, BOOL *previewIsHostLayer) {
    UIView *host = nil;
    CALayer *remembered = nil;

    if (previewIsHostLayer != NULL) {
        *previewIsHostLayer = NO;
    }
    if (preview == nil) {
        return nil;
    }
    id previewDelegate = preview.delegate;
    if ([previewDelegate isKindOfClass:[UIView class]] &&
        ((UIView *)previewDelegate).layer == (CALayer *)preview) {
        if (previewIsHostLayer != NULL) {
            *previewIsHostLayer = YES;
        }
        return (UIView *)previewDelegate;
    }
    host = MyVCamPreview_HostFromLayer(preview.superlayer);
    if (host != nil) {
        return host;
    }
    // Detach removes the preview from its superlayer. The remembered
    // superlayer is still the preview host, so the next tick can place
    // the cover without putting the live layer back first.
    if (gPreviewSuperlayers != nil) {
        remembered = [gPreviewSuperlayers objectForKey:preview];
        host = MyVCamPreview_HostFromLayer(remembered);
    }
    return host;
}

static void MyVCamPreview_RestoreOpacity(AVCaptureVideoPreviewLayer *preview) {
    // Covering() treats a restore as not covered so setHidden:/setOpacity:
    // write the saved values instead of forcing the live layer back off.
    gMyVCamRestoringPreview = 1;
    @try {
        NSNumber *saved = objc_getAssociatedObject(preview, &kMyVCamOpacityAssociationKey);
        if (saved != nil) {
            preview.opacity = saved.floatValue;
            objc_setAssociatedObject(preview, &kMyVCamOpacityAssociationKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        NSNumber *hidden = objc_getAssociatedObject(preview, &kMyVCamHiddenAssociationKey);
        if (hidden != nil) {
            preview.hidden = hidden.boolValue;
            objc_setAssociatedObject(preview, &kMyVCamHiddenAssociationKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        NSNumber *enabled = objc_getAssociatedObject(preview, &kMyVCamConnectionAssociationKey);
        if (enabled == nil) {
            return;
        }
        @try {
            AVCaptureConnection *connection = preview.connection;
            if (connection != nil) {
                connection.enabled = enabled.boolValue;
            }
        } @catch (NSException *exception) {
            NSLog(@"%s preview connection restore skipped: %@", kMyVCamC1CPrefix, exception);
        }
        objc_setAssociatedObject(preview, &kMyVCamConnectionAssociationKey, nil, OBJC_ASSOCIATION_ASSIGN);
    } @finally {
        gMyVCamRestoringPreview = 0;
    }
}

/// previewLayerView's alpha, not the preview layer's. The live image is a
/// sublayer Camera moves to the front of that view, and that layer does not
/// keep opacity = 0 across layout. The cover is a sibling, so this fade does
/// not hide it. A backing-layer host is left alone: its alpha would also fade
/// focus indicators that are subviews of that same view.
static void MyVCamPreview_SuppressHost(UIView *host, AVCaptureVideoPreviewLayer *preview) {
    if (host == nil || preview == nil || host.layer == (CALayer *)preview) {
        return;
    }
    if (objc_getAssociatedObject(host, &kMyVCamHostAlphaKey) == nil) {
        objc_setAssociatedObject(host,
                                 &kMyVCamHostAlphaKey,
                                 @(host.alpha),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (host.alpha != 0.0) {
        host.alpha = 0.0;
    }
}

static void MyVCamPreview_RestoreHost(UIView *host) {
    if (host == nil) {
        return;
    }
    NSNumber *saved = objc_getAssociatedObject(host, &kMyVCamHostAlphaKey);
    if (saved == nil) {
        return;
    }
    host.alpha = saved.floatValue;
    objc_setAssociatedObject(host, &kMyVCamHostAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void MyVCamPreview_LogConnectionBlocked(void) {
    static dispatch_once_t onceToken;
    MyVCamStatus_AddBlock();
    dispatch_once(&onceToken, ^{
        NSLog(@"%s preview connection blocked", kMyVCamDiagPrefix);
    });
}

static void MyVCamPreview_LogDetached(void) {
    static dispatch_once_t onceToken;
    MyVCamStatus_AddDetach();
    dispatch_once(&onceToken, ^{
        NSLog(@"%s preview detached", kMyVCamDiagPrefix);
    });
}

static void MyVCamPreview_NoteCovered(AVCaptureVideoPreviewLayer *preview) {
    if (preview == nil) {
        return;
    }
    os_unfair_lock_lock(&gCoverLock);
    if (gCoveredPreviews == nil) {
        gCoveredPreviews = [NSHashTable weakObjectsHashTable];
    }
    [gCoveredPreviews addObject:preview];
    os_unfair_lock_unlock(&gCoverLock);
}

static BOOL MyVCamPreview_IsCovered(AVCaptureVideoPreviewLayer *preview) {
    BOOL covered = NO;

    if (preview == nil) {
        return NO;
    }
    os_unfair_lock_lock(&gCoverLock);
    covered = gCoveredPreviews != nil && [gCoveredPreviews containsObject:preview];
    os_unfair_lock_unlock(&gCoverLock);
    return covered;
}

static BOOL MyVCamPreview_ConnectionIsBlocked(AVCaptureConnection *connection) {
    BOOL blocked = NO;

    if (connection == nil) {
        return NO;
    }
    os_unfair_lock_lock(&gCoverLock);
    blocked = gBlockedConnections != nil && [gBlockedConnections containsObject:connection];
    os_unfair_lock_unlock(&gCoverLock);
    return blocked;
}

static void MyVCamPreview_BlockPreviewConnection(AVCaptureVideoPreviewLayer *preview,
                                                 AVCaptureConnection *connection) {
    AVCaptureConnection *previous = nil;

    if (preview == nil || connection == nil) {
        return;
    }
    previous = objc_getAssociatedObject(preview, &kMyVCamBlockedConnectionKey);
    os_unfair_lock_lock(&gCoverLock);
    if (gBlockedConnections == nil) {
        gBlockedConnections = [NSHashTable weakObjectsHashTable];
    }
    if (previous != nil && previous != connection) {
        [gBlockedConnections removeObject:previous];
    }
    [gBlockedConnections addObject:connection];
    os_unfair_lock_unlock(&gCoverLock);
    objc_setAssociatedObject(preview,
                             &kMyVCamBlockedConnectionKey,
                             connection,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void MyVCamPreview_Uncover(AVCaptureVideoPreviewLayer *preview) {
    AVCaptureConnection *connection = nil;

    if (preview == nil) {
        return;
    }
    connection = objc_getAssociatedObject(preview, &kMyVCamBlockedConnectionKey);
    os_unfair_lock_lock(&gCoverLock);
    if (gCoveredPreviews != nil) {
        [gCoveredPreviews removeObject:preview];
    }
    if (connection != nil && gBlockedConnections != nil) {
        [gBlockedConnections removeObject:connection];
    }
    os_unfair_lock_unlock(&gCoverLock);
    objc_setAssociatedObject(preview, &kMyVCamBlockedConnectionKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static BOOL MyVCamPreview_IsBackingLayer(AVCaptureVideoPreviewLayer *preview) {
    id delegate = nil;

    if (preview == nil) {
        return NO;
    }
    delegate = preview.delegate;
    return [delegate isKindOfClass:[UIView class]] && ((UIView *)delegate).layer == (CALayer *)preview;
}

static void MyVCamPreview_RememberSuperlayer(AVCaptureVideoPreviewLayer *preview) {
    CALayer *superlayer = nil;

    if (preview == nil) {
        return;
    }
    superlayer = preview.superlayer;
    if (superlayer == nil) {
        return;
    }
    if (gPreviewSuperlayers == nil) {
        gPreviewSuperlayers = [NSMapTable weakToWeakObjectsMapTable];
    }
    [gPreviewSuperlayers setObject:superlayer forKey:preview];
}

static void MyVCamPreview_RestoreSuperlayer(AVCaptureVideoPreviewLayer *preview) {
    CALayer *superlayer = nil;

    if (preview == nil || gPreviewSuperlayers == nil) {
        return;
    }
    superlayer = [gPreviewSuperlayers objectForKey:preview];
    [gPreviewSuperlayers removeObjectForKey:preview];
    if (superlayer == nil || preview.superlayer == superlayer) {
        return;
    }
    [superlayer addSublayer:preview];
}

static void MyVCamPreview_DetachPreview(AVCaptureVideoPreviewLayer *preview) {
    if (preview == nil || MyVCamPreview_IsBackingLayer(preview) || preview.superlayer == nil) {
        return;
    }
    MyVCamPreview_RememberSuperlayer(preview);
    gMyVCamInLayerInsert = 1;
    [preview removeFromSuperlayer];
    gMyVCamInLayerInsert = 0;
    MyVCamPreview_LogDetached();
}

/// Hide the live preview without hiding the cover. The cover is not a
/// subview of this layer. Host alpha and preview opacity do not stop Photo
/// mode's video context. The connection is the switch that stops frames, and
/// it is recorded so a later setEnabled: from the session queue cannot turn
/// it back on. The photo output is a different connection. A sublayer preview
/// is removed so a stale frame cannot stay in front of the cover; a backing
/// layer is left in place because removing it would drop the view.
static void MyVCamPreview_SuppressLive(AVCaptureVideoPreviewLayer *preview) {
    if (preview == nil) {
        return;
    }
    MyVCamPreview_NoteCovered(preview);
    if (objc_getAssociatedObject(preview, &kMyVCamOpacityAssociationKey) == nil) {
        objc_setAssociatedObject(preview,
                                 &kMyVCamOpacityAssociationKey,
                                 @(preview.opacity),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (preview.opacity != 0.0f) {
        preview.opacity = 0;
    }
    if (objc_getAssociatedObject(preview, &kMyVCamHiddenAssociationKey) == nil) {
        objc_setAssociatedObject(preview,
                                 &kMyVCamHiddenAssociationKey,
                                 @(preview.hidden),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!preview.hidden) {
        preview.hidden = YES;
    }
    @try {
        AVCaptureConnection *connection = preview.connection;
        if (connection != nil) {
            if (objc_getAssociatedObject(preview, &kMyVCamConnectionAssociationKey) == nil) {
                objc_setAssociatedObject(preview,
                                         &kMyVCamConnectionAssociationKey,
                                         @(connection.enabled),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            MyVCamPreview_BlockPreviewConnection(preview, connection);
            if (connection.enabled) {
                connection.enabled = NO;
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"%s preview connection suppress skipped: %@", kMyVCamC1CPrefix, exception);
    }
    MyVCamPreview_DetachPreview(preview);
}

static void MyVCamPreview_RemoveNamedSublayers(CALayer *layer) {
    if (layer == nil) {
        return;
    }
    NSArray<CALayer *> *sublayers = [layer.sublayers copy];
    for (CALayer *sublayer in sublayers) {
        if ([sublayer.name isEqualToString:kMyVCamPreviewOverlayName] &&
            ![sublayer.delegate isKindOfClass:[UIView class]]) {
            [sublayer removeFromSuperlayer];
        }
    }
}

static BOOL MyVCamPreview_HostStillUsed(UIView *host, MyVCamPreviewHostView *except) {
    if (host == nil || gPreviewCovers == nil) {
        return NO;
    }
    for (MyVCamPreviewHostView *other in gPreviewCovers.allObjects) {
        if (other == except) {
            continue;
        }
        if (objc_getAssociatedObject(other, &kMyVCamCoverHostKey) == host) {
            return YES;
        }
    }
    return NO;
}

static void MyVCamPreview_ClearCoverLinks(MyVCamPreviewHostView *view) {
    UIView *host = nil;
    UIView *container = nil;

    if (![view isKindOfClass:[MyVCamPreviewHostView class]]) {
        return;
    }
    host = objc_getAssociatedObject(view, &kMyVCamCoverHostKey);
    container = view.superview;
    if (container != nil && objc_getAssociatedObject(container, &kMyVCamCoverContainerKey) == view) {
        objc_setAssociatedObject(container, &kMyVCamCoverContainerKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    if (host != nil && host != container &&
        objc_getAssociatedObject(host, &kMyVCamCoverContainerKey) == view) {
        objc_setAssociatedObject(host, &kMyVCamCoverContainerKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    // Alpha was applied to the immediate preview host, not the chrome sibling.
    // A second cover above that host still needs the fade.
    if (!MyVCamPreview_HostStillUsed(host, view)) {
        MyVCamPreview_RestoreHost(host);
    }
    objc_setAssociatedObject(view, &kMyVCamCoverAnchorKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, &kMyVCamCoverHostKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, &kMyVCamCoverPreviewKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void MyVCamPreview_DropOverlay(AVCaptureVideoPreviewLayer *preview) {
    if (preview == nil) {
        return;
    }
    // Uncover before restore. setHidden:/setOpacity:/setEnabled: and the
    // layer-insert hook keep the live image off while the preview is covered.
    MyVCamPreview_Uncover(preview);
    MyVCamPreviewHostView *covers[2];
    covers[0] = objc_getAssociatedObject(preview, &kMyVCamOverlayAssociationKey);
    covers[1] = objc_getAssociatedObject(preview, &kMyVCamHostOverlayKey);
    objc_setAssociatedObject(preview, &kMyVCamOverlayAssociationKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(preview, &kMyVCamHostOverlayKey, nil, OBJC_ASSOCIATION_ASSIGN);
    for (int index = 0; index < 2; index++) {
        MyVCamPreviewHostView *view = covers[index];
        if (index == 1 && view == covers[0]) {
            continue;
        }
        if (![view isKindOfClass:[MyVCamPreviewHostView class]]) {
            continue;
        }
        MyVCamPreview_ClearCoverLinks(view);
        [gPreviewCovers removeObject:view];
        [view removeFromSuperview];
    }
    MyVCamPreview_RestoreSuperlayer(preview);
    MyVCamPreview_RestoreOpacity(preview);
    MyVCamPreview_RemoveNamedSublayers(preview);
    MyVCamPreview_RemoveNamedSublayers(preview.superlayer);
}

static void MyVCamPreview_RemoveOverlays(void) {
    NSArray *leftovers = nil;

    for (AVCaptureVideoPreviewLayer *preview in gPreviewLayers.allObjects) {
        MyVCamPreview_DropOverlay(preview);
    }
    leftovers = gPreviewCovers.allObjects;
    for (MyVCamPreviewHostView *view in leftovers) {
        AVCaptureVideoPreviewLayer *preview = objc_getAssociatedObject(view, &kMyVCamCoverPreviewKey);
        if ([preview isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
            MyVCamPreview_DropOverlay(preview);
        } else {
            [view removeFromSuperview];
            [gPreviewCovers removeObject:view];
        }
    }
    gPreviewEnqueueStreak = 0;
}

static void MyVCamPreview_LogOverlay(BOOL ok, UIView *host, UIView *overlay) {
    static int lastState = -1;
    BOOL inWindow = overlay != nil && overlay.window != nil;
    BOOL inHierarchy = overlay != nil && (overlay.superview != nil || overlay.layer.superlayer != nil);
    int state = ok ? (inWindow ? 2 : 1) : 0;
    if (state == lastState) {
        return;
    }
    lastState = state;
    NSLog(@"%s overlay create=%d view=%@ layer=%@ added_to=%@ in_window=%d hierarchy=%d",
          kMyVCamDiagPrefix,
          ok ? 1 : 0,
          overlay != nil ? NSStringFromClass(overlay.class) : @"-",
          overlay != nil ? NSStringFromClass(overlay.layer.class) : @"-",
          host != nil ? NSStringFromClass(host.class) : @"-",
          inWindow ? 1 : 0,
          inHierarchy ? 1 : 0);
}

typedef void (*MyVCamLayoutIMP)(id, SEL);
static MyVCamLayoutIMP gLayoutOriginals[8];
static Class gLayoutClasses[8];
static unsigned gLayoutHookCount = 0;

static MyVCamLayoutIMP MyVCamPreview_LayoutOriginal(Class start) {
    for (Class walk = start; walk != Nil; walk = class_getSuperclass(walk)) {
        for (unsigned index = 0; index < gLayoutHookCount; index++) {
            if (gLayoutClasses[index] == walk) {
                return gLayoutOriginals[index];
            }
        }
    }
    return NULL;
}

static BOOL MyVCamPreview_PlaceExisting(MyVCamPreviewHostView *overlay);

static void MyVCamPreview_LayoutHook(id self, SEL _cmd) {
    MyVCamLayoutIMP original = MyVCamPreview_LayoutOriginal(object_getClass(self));
    // PlaceExisting changes frames and can re-enter layout on this view.
    // Running the original again from that re-entry loops. The outer call
    // already ran it.
    if (gMyVCamInCoverLayout) {
        return;
    }
    if (original != NULL && original != (MyVCamLayoutIMP)MyVCamPreview_LayoutHook) {
        original(self, _cmd);
    }
    if (![self isKindOfClass:[UIView class]] || gPreviewCovers == nil) {
        return;
    }
    for (MyVCamPreviewHostView *overlay in gPreviewCovers.allObjects) {
        UIView *anchor = nil;
        if (![overlay isKindOfClass:[MyVCamPreviewHostView class]]) {
            continue;
        }
        anchor = objc_getAssociatedObject(overlay, &kMyVCamCoverAnchorKey);
        if (overlay.superview == self || ([anchor isKindOfClass:[UIView class]] && anchor.superview == self)) {
            MyVCamPreview_PlaceExisting(overlay);
        }
    }
}

/// Camera's preview host implements layoutSubviews and moves the live layer
/// to the front after UIView's layout returns. Hook that class, not UIView,
/// and place the cover after the original method.
static void MyVCamPreview_HookContainerLayout(UIView *container) {
    Class impl = Nil;
    IMP replaced = NULL;
    IMP original = NULL;

    if (container == nil || gLayoutHookCount >= 8) {
        return;
    }
    impl = MyVCamC1A_ImplementingClass([container class], @selector(layoutSubviews));
    if (impl == Nil || impl == [UIView class] || impl == [UIWindow class]) {
        return;
    }
    for (unsigned index = 0; index < gLayoutHookCount; index++) {
        if (gLayoutClasses[index] == impl) {
            return;
        }
    }
    MSHookMessageEx(impl, @selector(layoutSubviews), (IMP)MyVCamPreview_LayoutHook, &replaced);
    original = replaced != NULL ? replaced : method_getImplementation(class_getInstanceMethod(impl, @selector(layoutSubviews)));
    if (original == NULL || original == (IMP)MyVCamPreview_LayoutHook) {
        NSLog(@"%s preview layout hook failed class=%@", kMyVCamC1CPrefix, NSStringFromClass(impl));
        return;
    }
    gLayoutClasses[gLayoutHookCount] = impl;
    gLayoutOriginals[gLayoutHookCount] = (MyVCamLayoutIMP)original;
    gLayoutHookCount++;
    NSLog(@"%s preview layout hooked class=%@", kMyVCamC1CPrefix, NSStringFromClass(impl));
}

static int MyVCamPreview_ChromeRank(UIView *view) {
    NSString *name = nil;
    int rank = 0;

    if (view == nil) {
        return 0;
    }
    name = NSStringFromClass(object_getClass(view));
    if ([name rangeOfString:@"Shutter"].location != NSNotFound) {
        rank = 4;
    } else if ([name rangeOfString:@"BottomBar"].location != NSNotFound) {
        rank = 3;
    } else if ([name rangeOfString:@"ModeDial"].location != NSNotFound) {
        rank = 2;
    } else if ([name rangeOfString:@"TopBar"].location != NSNotFound) {
        rank = 1;
    }
    if (rank == 0) {
        return 0;
    }
    // A hidden control in another branch must not beat the shutter that is
    // actually on screen, or the cover lands above that shutter.
    if (!view.hidden && view.alpha > 0.01f && view.window != nil) {
        rank += 10;
    }
    return rank;
}

static void MyVCamPreview_FindChrome(UIView *view, NSUInteger depth, UIView **best, int *bestRank) {
    int rank = 0;

    if (view == nil || best == NULL || bestRank == NULL || depth > 24) {
        return;
    }
    rank = MyVCamPreview_ChromeRank(view);
    if (rank > *bestRank) {
        *bestRank = rank;
        *best = view;
    }
    for (UIView *subview in view.subviews) {
        MyVCamPreview_FindChrome(subview, depth + 1, best, bestRank);
    }
}

/// Shutter, bottom bar, mode dial, or top bar. Cached across ticks. A zoom
/// or lighting control inside the preview branch is not this anchor.
static UIView *MyVCamPreview_ChromeAnchor(void) {
    static uint32_t tick = 0;
    static __weak UIView *cached = nil;
    UIView *found = nil;
    int bestRank = 0;

    tick += 1;
    found = cached;
    if (found != nil && found.window != nil && (tick % 30u) != 1u) {
        return found;
    }
    found = nil;
    bestRank = 0;
    for (UIWindow *window in MyVCamPreview_Windows()) {
        MyVCamPreview_FindChrome(window, 0, &found, &bestRank);
    }
    cached = found;
    return found;
}

/// The view to insert the cover above, and the superview that also holds the
/// shutter. 0.2.11 stopped at the first medium-sized sibling, which is the
/// zoom or lighting control inside the preview branch, so the cover never
/// reached the viewfinder slot that paints over the video context.
static void MyVCamPreview_ChoosePlacement(UIView *host,
                                          UIView **outAbove,
                                          UIView **outContainer,
                                          const char **outSlot) {
    Class viewfinderClass = Nil;
    UIView *chrome = nil;
    UIView *previewBranch = nil;

    if (outAbove != NULL) {
        *outAbove = nil;
    }
    if (outContainer != NULL) {
        *outContainer = nil;
    }
    if (outSlot != NULL) {
        *outSlot = "none";
    }
    if (host == nil) {
        return;
    }

    viewfinderClass = NSClassFromString(@"CAMViewfinderView");
    if (viewfinderClass != Nil) {
        for (UIView *branch = host; branch.superview != nil; branch = branch.superview) {
            if ([branch.superview isKindOfClass:viewfinderClass]) {
                if (outAbove != NULL) {
                    *outAbove = branch;
                }
                if (outContainer != NULL) {
                    *outContainer = branch.superview;
                }
                if (outSlot != NULL) {
                    *outSlot = "viewfinder";
                }
                return;
            }
        }
    }

    chrome = MyVCamPreview_ChromeAnchor();
    if (chrome != nil && chrome.window != nil && host.window == chrome.window) {
        NSMutableSet<UIView *> *ancestors = [NSMutableSet set];
        for (UIView *walk = chrome; walk != nil; walk = walk.superview) {
            [ancestors addObject:walk];
        }
        for (UIView *branch = host; branch.superview != nil; branch = branch.superview) {
            if ([branch.superview isKindOfClass:[UIWindow class]]) {
                break;
            }
            if ([ancestors containsObject:branch.superview]) {
                if (outAbove != NULL) {
                    *outAbove = branch;
                }
                if (outContainer != NULL) {
                    *outContainer = branch.superview;
                }
                if (outSlot != NULL) {
                    *outSlot = "chrome";
                }
                return;
            }
        }
    }

    for (UIView *walk = host; walk != nil && ![walk isKindOfClass:[UIWindow class]]; walk = walk.superview) {
        NSString *name = NSStringFromClass(object_getClass(walk));
        if ([name rangeOfString:@"Preview"].location != NSNotFound &&
            walk.superview != nil &&
            ![walk.superview isKindOfClass:[UIWindow class]]) {
            previewBranch = walk;
        }
    }
    if (previewBranch != nil) {
        if (outAbove != NULL) {
            *outAbove = previewBranch;
        }
        if (outContainer != NULL) {
            *outContainer = previewBranch.superview;
        }
        if (outSlot != NULL) {
            *outSlot = "preview";
        }
        return;
    }

    {
        UIView *branch = host;
        while (branch.superview != nil && ![branch.superview isKindOfClass:[UIWindow class]]) {
            UIView *parent = branch.superview;
            BOOL parentIsRoot = parent.superview == nil || [parent.superview isKindOfClass:[UIWindow class]];
            if (parentIsRoot) {
                if (outAbove != NULL) {
                    *outAbove = branch;
                }
                if (outContainer != NULL) {
                    *outContainer = parent;
                }
                if (outSlot != NULL) {
                    *outSlot = "root";
                }
                return;
            }
            branch = parent;
        }
    }
    if (outAbove != NULL) {
        *outAbove = host;
    }
    if (outContainer != NULL) {
        *outContainer = host.superview;
    }
    if (outSlot != NULL) {
        *outSlot = "host";
    }
}

/// YES while this preview's cover is on screen. setHidden: and setOpacity:
/// use it to keep Camera from showing the live layer again. A restore in
/// progress is not covering, so the saved values can be written back.
static BOOL MyVCamPreview_Covering(AVCaptureVideoPreviewLayer *preview) {
    MyVCamPreviewHostView *overlay = nil;

    if (gMyVCamRestoringPreview || preview == nil || ![NSThread isMainThread]) {
        return NO;
    }
    if (!MyVCamPreview_SessionIsLive()) {
        return NO;
    }
    overlay = objc_getAssociatedObject(preview, &kMyVCamOverlayAssociationKey);
    if ([overlay isKindOfClass:[MyVCamPreviewHostView class]] && overlay.superview != nil && !overlay.hidden) {
        return YES;
    }
    overlay = objc_getAssociatedObject(preview, &kMyVCamHostOverlayKey);
    return [overlay isKindOfClass:[MyVCamPreviewHostView class]] && overlay.superview != nil && !overlay.hidden;
}

/// Keep the cover as the next sibling above the preview branch. Returns NO
/// when that branch is not in a superview yet. Called from the preview tick
/// and from the chrome superview's layoutSubviews.
static BOOL MyVCamPreview_PlaceExisting(MyVCamPreviewHostView *overlay) {
    UIView *above = nil;
    UIView *host = nil;
    AVCaptureVideoPreviewLayer *preview = nil;
    UIView *container = nil;
    UIView *previous = nil;
    BOOL placed = NO;

    if (![overlay isKindOfClass:[MyVCamPreviewHostView class]]) {
        return NO;
    }
    if (gMyVCamInCoverLayout) {
        return overlay.superview != nil;
    }
    gMyVCamInCoverLayout = 1;
    @try {
        above = objc_getAssociatedObject(overlay, &kMyVCamCoverAnchorKey);
        host = objc_getAssociatedObject(overlay, &kMyVCamCoverHostKey);
        preview = objc_getAssociatedObject(overlay, &kMyVCamCoverPreviewKey);
        if (![above isKindOfClass:[UIView class]] || above.superview == nil || CGRectIsEmpty(above.bounds)) {
            placed = NO;
        } else {
            // Mark covered before insert. Camera's layout runs inside
            // insertSubview and would otherwise put the live layer back
            // above the cover before SuppressLive runs.
            if ([preview isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
                MyVCamPreview_NoteCovered(preview);
            }
            container = above.superview;
            previous = overlay.superview;
            if (previous != nil && previous != container &&
                objc_getAssociatedObject(previous, &kMyVCamCoverContainerKey) == overlay) {
                objc_setAssociatedObject(previous, &kMyVCamCoverContainerKey, nil, OBJC_ASSOCIATION_ASSIGN);
            }
            if (!CATransform3DIsIdentity(above.layer.transform)) {
                if (!CGRectEqualToRect(overlay.bounds, above.bounds) ||
                    !CGPointEqualToPoint(overlay.center, above.center)) {
                    overlay.bounds = above.bounds;
                    overlay.center = above.center;
                }
                if (!CGAffineTransformEqualToTransform(overlay.transform, above.transform)) {
                    overlay.transform = above.transform;
                }
            } else if (!CGAffineTransformIsIdentity(overlay.transform) ||
                       !CGRectEqualToRect(overlay.frame, above.frame)) {
                overlay.transform = CGAffineTransformIdentity;
                overlay.frame = above.frame;
            }
            overlay.hidden = NO;
            overlay.alpha = 1.0;
            overlay.autoresizingMask = above.autoresizingMask;
            overlay.layer.zPosition = above.layer.zPosition;
            NSUInteger aboveIndex = [container.subviews indexOfObject:above];
            NSUInteger overlayIndex = [container.subviews indexOfObject:overlay];
            if (overlay.superview != container || aboveIndex == NSNotFound || overlayIndex != aboveIndex + 1) {
                [container insertSubview:overlay aboveSubview:above];
            }
            // Same superlayer as the live preview means the climb stopped
            // inside the view Camera reorders. Stay above that layer.
            if ([preview isKindOfClass:[AVCaptureVideoPreviewLayer class]] &&
                overlay.layer.superlayer != nil &&
                overlay.layer.superlayer == preview.superlayer) {
                overlay.layer.zPosition = preview.zPosition + 1.0;
            }
            objc_setAssociatedObject(container,
                                     &kMyVCamCoverContainerKey,
                                     overlay,
                                     OBJC_ASSOCIATION_ASSIGN);
            if ([host isKindOfClass:[UIView class]] && host != container) {
                objc_setAssociatedObject(host,
                                         &kMyVCamCoverContainerKey,
                                         overlay,
                                         OBJC_ASSOCIATION_ASSIGN);
                MyVCamPreview_HookContainerLayout(host);
            }
            MyVCamPreview_HookContainerLayout(container);
            if ([preview isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
                MyVCamPreview_SuppressLive(preview);
                if ([host isKindOfClass:[UIView class]]) {
                    MyVCamPreview_SuppressHost(host, preview);
                }
            }
            placed = overlay.superview != nil;
        }
    } @finally {
        gMyVCamInCoverLayout = 0;
    }
    return placed;
}

static void MyVCamPreview_LogHost(UIView *host, BOOL hostLayer, UIView *above, UIView *container, const char *slot) {
    static NSString *last = nil;
    NSString *token = [NSString stringWithFormat:@"%@|%d|%@|%@|%s",
                       host != nil ? NSStringFromClass(host.class) : @"-",
                       hostLayer ? 1 : 0,
                       above != nil ? NSStringFromClass(above.class) : @"-",
                       container != nil ? NSStringFromClass(container.class) : @"-",
                       slot != NULL ? slot : "none"];
    if (last != nil && [last isEqualToString:token]) {
        return;
    }
    last = token;
    NSLog(@"%s host found class=%@ host_layer=%d above=%@ container=%@ in_window=%d slot=%s",
          kMyVCamDiagPrefix,
          host != nil ? NSStringFromClass(host.class) : @"-",
          hostLayer ? 1 : 0,
          above != nil ? NSStringFromClass(above.class) : @"-",
          container != nil ? NSStringFromClass(container.class) : @"-",
          (host.window != nil || above.window != nil) ? 1 : 0,
          slot != NULL ? slot : "none");
}

static void MyVCamPreview_LogCoverAttach(BOOL ok,
                                         UIView *container,
                                         UIView *above,
                                         UIView *host,
                                         UIView *overlay,
                                         AVCaptureVideoPreviewLayer *preview,
                                         const char *slot) {
    static int lastState = -1;
    BOOL inWindow = overlay != nil && overlay.window != nil;
    int state = ok ? (inWindow ? 2 : 1) : 0;
    if (state == lastState) {
        return;
    }
    lastState = state;
    if (!ok) {
        NSLog(@"%s cover attach failed container=%@ above=%@ host=%@ slot=%s",
              kMyVCamDiagPrefix,
              container != nil ? NSStringFromClass(container.class) : @"-",
              above != nil ? NSStringFromClass(above.class) : @"-",
              host != nil ? NSStringFromClass(host.class) : @"-",
              slot != NULL ? slot : "none");
        return;
    }
    NSLog(@"%s cover attach container=%@ above=%@ host=%@ frame=%@ in_window=%d live_hidden=%d slot=%s",
          kMyVCamDiagPrefix,
          container != nil ? NSStringFromClass(container.class) : @"-",
          above != nil ? NSStringFromClass(above.class) : @"-",
          host != nil ? NSStringFromClass(host.class) : @"-",
          overlay != nil ? NSStringFromCGRect(overlay.frame) : @"-",
          inWindow ? 1 : 0,
          (preview != nil && (preview.hidden || preview.superlayer == nil)) ? 1 : 0,
          slot != NULL ? slot : "none");
}

static AVSampleBufferDisplayLayer *MyVCamPreview_DisplayLayer(UIView *view) {
    if (view == nil) {
        return nil;
    }
    for (CALayer *sublayer in view.layer.sublayers) {
        if ([sublayer isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
            return (AVSampleBufferDisplayLayer *)sublayer;
        }
    }
    return nil;
}

/// Opaque cover immediately above the preview host, when that is not the
/// same superview as the viewfinder cover. After the live layer is detached,
/// this is the view that occupies the hole Photo mode was drawing into.
static AVSampleBufferDisplayLayer *MyVCamPreview_EnsureHostSibling(AVCaptureVideoPreviewLayer *preview,
                                                                   UIView *host,
                                                                   UIView *primaryContainer) {
    MyVCamPreviewHostView *cover = nil;
    UIView *container = nil;

    if (preview == nil || ![host isKindOfClass:[UIView class]]) {
        return nil;
    }
    container = host.superview;
    if (container == nil || [container isKindOfClass:[UIWindow class]] || container == primaryContainer) {
        return nil;
    }
    if (CGRectIsEmpty(host.bounds) && CGRectIsEmpty(host.frame)) {
        return nil;
    }
    cover = objc_getAssociatedObject(preview, &kMyVCamHostOverlayKey);
    if (![cover isKindOfClass:[MyVCamPreviewHostView class]]) {
        if (gPreviewCovers == nil) {
            gPreviewCovers = [[NSMutableSet alloc] init];
        }
        cover = [[MyVCamPreviewHostView alloc] initWithFrame:host.frame];
        cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [gPreviewCovers addObject:cover];
        objc_setAssociatedObject(preview,
                                 &kMyVCamHostOverlayKey,
                                 cover,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
    objc_setAssociatedObject(cover, &kMyVCamCoverAnchorKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cover, &kMyVCamCoverHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cover, &kMyVCamCoverPreviewKey, preview, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!MyVCamPreview_PlaceExisting(cover)) {
        return nil;
    }
    return MyVCamPreview_DisplayLayer(cover);
}

/// Opaque UIView above the live image. Its backing layer is a normal layer,
/// so an empty display sublayer cannot show the camera through the cover.
///
/// Photo mode keeps AVCaptureVideoPreviewLayer as a sublayer of
/// previewLayerView. The shutter paints from the viewfinder, which is the
/// superview of the whole preview branch. The cover is inserted there,
/// immediately above that branch. A second cover is inserted above the
/// preview host when that slot is different. The preview connection stays
/// disabled and the layer is removed while a cover is up. The cover objects
/// stay in gPreviewCovers, so a layout pass that removes one does not
/// restore the live image.
static AVSampleBufferDisplayLayer *MyVCamPreview_Overlay(AVCaptureVideoPreviewLayer *preview, BOOL create) {
    static BOOL loggedHost = NO;
    BOOL previewIsHostLayer = NO;
    const char *slot = "none";
    UIView *host = MyVCamPreview_HostView(preview, &previewIsHostLayer);
    UIView *above = nil;
    UIView *container = nil;
    MyVCamPreviewHostView *overlay = objc_getAssociatedObject(preview, &kMyVCamOverlayAssociationKey);

    if (![overlay isKindOfClass:[MyVCamPreviewHostView class]]) {
        overlay = nil;
    }
    if (host == nil && overlay != nil) {
        host = objc_getAssociatedObject(overlay, &kMyVCamCoverHostKey);
    }
    if (host != nil) {
        MyVCamPreview_ChoosePlacement(host, &above, &container, &slot);
    }
    if (above == nil || container == nil || CGRectIsEmpty(above.bounds)) {
        AVSampleBufferDisplayLayer *hostLayer = nil;
        if (create) {
            UIView *sibling = nil;
            MyVCamPreview_LogHost(host, previewIsHostLayer, above, container, slot);
            MyVCamPreview_LogCoverAttach(NO, container, above, host, overlay, preview, slot);
            MyVCamPreview_LogOverlay(NO, container != nil ? container : host, overlay);
            hostLayer = MyVCamPreview_EnsureHostSibling(preview, host, container);
            sibling = objc_getAssociatedObject(preview, &kMyVCamHostOverlayKey);
            MyVCamStatus_SetCover(preview,
                                  host,
                                  previewIsHostLayer,
                                  above,
                                  container,
                                  slot,
                                  [sibling isKindOfClass:[UIView class]] ? sibling : host,
                                  0);
        }
        return hostLayer;
    }
    MyVCamPreview_LogHost(host, previewIsHostLayer, above, container, slot);
    if (overlay == nil) {
        if (!create) {
            return nil;
        }
        if (gPreviewCovers == nil) {
            gPreviewCovers = [[NSMutableSet alloc] init];
        }
        overlay = [[MyVCamPreviewHostView alloc] initWithFrame:above.frame];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // gPreviewCovers retains the cover. The cover retains the preview
        // layer. The preview's association is assign, so the two do not cycle.
        [gPreviewCovers addObject:overlay];
        objc_setAssociatedObject(preview,
                                 &kMyVCamOverlayAssociationKey,
                                 overlay,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
    objc_setAssociatedObject(overlay, &kMyVCamCoverAnchorKey, above, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlay, &kMyVCamCoverHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlay, &kMyVCamCoverPreviewKey, preview, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!MyVCamPreview_PlaceExisting(overlay)) {
        AVSampleBufferDisplayLayer *hostLayer = nil;
        UIView *sibling = nil;
        MyVCamPreview_LogCoverAttach(NO, container, above, host, overlay, preview, slot);
        MyVCamPreview_LogOverlay(NO, container, overlay);
        hostLayer = MyVCamPreview_EnsureHostSibling(preview, host, container);
        sibling = objc_getAssociatedObject(preview, &kMyVCamHostOverlayKey);
        MyVCamStatus_SetCover(preview,
                              host,
                              previewIsHostLayer,
                              above,
                              container,
                              slot,
                              [sibling isKindOfClass:[UIView class]] ? sibling : overlay,
                              0);
        return hostLayer;
    }
    if (!loggedHost) {
        loggedHost = YES;
        NSLog(@"%s preview overlay attached host=%@ above=%@ container=%@ host_layer=%d",
              kMyVCamC1CPrefix,
              host != nil ? NSStringFromClass(host.class) : @"-",
              NSStringFromClass(above.class),
              NSStringFromClass(container.class),
              previewIsHostLayer ? 1 : 0);
    }
    MyVCamPreview_EnsureHostSibling(preview, host, container);
    MyVCamPreview_LogCoverAttach(YES, container, above, host, overlay, preview, slot);
    MyVCamPreview_LogOverlay(YES, container, overlay);
    MyVCamStatus_SetCover(preview, host, previewIsHostLayer, above, container, slot, overlay, 0);
    return MyVCamPreview_DisplayLayer(overlay);
}

static CVPixelBufferRef MyVCamPreview_CreateIOSurfaceBGRA(size_t width, size_t height) {
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: @YES,
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
    BOOL sourceCVLocked = CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess;
    BOOL destinationCVLocked = CVPixelBufferLockBaseAddress(destination, 0) == kCVReturnSuccess;
    IOSurfaceRef sourceSurface = NULL;
    IOSurfaceRef destinationSurface = NULL;
    uint8_t *sourceBase = NULL;
    uint8_t *destinationBase = NULL;
    size_t sourceRow = 0;
    size_t destinationRow = 0;
    size_t width = 0;
    size_t height = 0;
    size_t rowBytes = 0;
    BOOL copied = NO;

    if (sourceCVLocked) {
        sourceBase = CVPixelBufferGetBaseAddress(source);
        sourceRow = CVPixelBufferGetBytesPerRow(source);
        if (sourceBase == NULL) {
            CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
            sourceCVLocked = NO;
        }
    }
    if (destinationCVLocked) {
        destinationBase = CVPixelBufferGetBaseAddress(destination);
        destinationRow = CVPixelBufferGetBytesPerRow(destination);
        if (destinationBase == NULL) {
            CVPixelBufferUnlockBaseAddress(destination, 0);
            destinationCVLocked = NO;
        }
    }
    // AVAssetReader can hand back an IOSurface that CVPixelBufferLock does
    // not map. Unlock first, then map the surface. Never hold both locks.
    if (sourceBase == NULL) {
        sourceSurface = CVPixelBufferGetIOSurface(source);
        if (sourceSurface != NULL &&
            IOSurfaceLock(sourceSurface, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess) {
            sourceBase = IOSurfaceGetBaseAddress(sourceSurface);
            sourceRow = IOSurfaceGetBytesPerRow(sourceSurface);
        } else {
            sourceSurface = NULL;
        }
    }
    if (destinationBase == NULL) {
        destinationSurface = CVPixelBufferGetIOSurface(destination);
        if (destinationSurface != NULL &&
            IOSurfaceLock(destinationSurface, 0, NULL) == kIOReturnSuccess) {
            destinationBase = IOSurfaceGetBaseAddress(destinationSurface);
            destinationRow = IOSurfaceGetBytesPerRow(destinationSurface);
        } else {
            destinationSurface = NULL;
        }
    }
    width = CVPixelBufferGetWidth(destination);
    height = CVPixelBufferGetHeight(destination);
    rowBytes = width * 4u;
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
    if (sourceSurface != NULL) {
        IOSurfaceUnlock(sourceSurface, kIOSurfaceLockReadOnly, NULL);
    }
    if (destinationSurface != NULL) {
        IOSurfaceUnlock(destinationSurface, 0, NULL);
    }
    if (destinationCVLocked) {
        CVPixelBufferUnlockBaseAddress(destination, 0);
    }
    if (sourceCVLocked) {
        CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    }
    return copied;
}

/// New IOSurface-backed 32BGRA sample (+1). AVSampleBufferDisplayLayer rejects
/// a buffer that is not IOSurface-backed, and AVAssetReader does not promise
/// one. DisplayImmediately so a control timebase is not required.
static CMSampleBufferRef MyVCamPreview_CopyDisplaySample(CMSampleBufferRef source, const char **outReason) {
    static int64_t tick = 0;
    if (outReason != NULL) {
        *outReason = "ok";
    }
    if (source == NULL) {
        if (outReason != NULL) {
            *outReason = "latest";
        }
        return NULL;
    }
    CVPixelBufferRef sourcePixels = CMSampleBufferGetImageBuffer(source);
    if (sourcePixels == NULL) {
        if (outReason != NULL) {
            *outReason = "pixelbuffer";
        }
        return NULL;
    }
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(sourcePixels);
    if (pixelFormat != kCVPixelFormatType_32BGRA) {
        if (outReason != NULL) {
            *outReason = "format";
        }
        return NULL;
    }
    size_t width = CVPixelBufferGetWidth(sourcePixels);
    size_t height = CVPixelBufferGetHeight(sourcePixels);
    if (width == 0 || height == 0) {
        if (outReason != NULL) {
            *outReason = "size";
        }
        return NULL;
    }
    // MediaReader asks for a CoreAnimation-compatible IOSurface. Wrapping
    // that buffer is the fast path. A rejected enqueue switches to a copy
    // into a buffer this process created, which the display layer accepts.
    // If the copy cannot map the source, the original surface is still wrapped.
    CVPixelBufferRef pixels = NULL;
    BOOL canWrap = CVPixelBufferGetIOSurface(sourcePixels) != NULL;
    if (canWrap && !gPreviewForceCopy) {
        pixels = CVPixelBufferRetain(sourcePixels);
    } else {
        pixels = MyVCamPreview_CreateIOSurfaceBGRA(width, height);
        if (pixels == NULL || !MyVCamPreview_CopyBGRA(sourcePixels, pixels)) {
            BOOL created = pixels != NULL;
            if (created) {
                CVPixelBufferRelease(pixels);
                pixels = NULL;
            }
            if (canWrap) {
                pixels = CVPixelBufferRetain(sourcePixels);
            } else {
                if (outReason != NULL) {
                    *outReason = created ? "copy" : "iosurface";
                }
                return NULL;
            }
        }
    }
    if (pixels == NULL) {
        if (outReason != NULL) {
            *outReason = "iosurface";
        }
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
        if (outReason != NULL) {
            *outReason = "format_desc";
        }
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
        if (outReason != NULL) {
            *outReason = "sample";
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

static void MyVCamPreview_ArmIfNeeded(void) {
    BOOL shouldArm = NO;
    os_unfair_lock_lock(&gLock);
    shouldArm = !gCaptureSessionRunning && gPhase != MyVCamPhaseDisabled;
    os_unfair_lock_unlock(&gLock);
    if (!shouldArm || gPreviewLayers == nil) {
        return;
    }
    for (AVCaptureVideoPreviewLayer *preview in gPreviewLayers.allObjects) {
        if (preview.session.isRunning) {
            MyVCamC1C_NoteSessionStarted();
            return;
        }
    }
}

static void MyVCamPreview_LogTimer(uint32_t scanTick, int latest) {
    unsigned long layers = 0;
    if (scanTick != 1u && (scanTick % 30u) != 0u) {
        return;
    }
    layers = gPreviewLayers != nil ? gPreviewLayers.allObjects.count : 0;
    NSLog(@"%s timer ticks preview=%u live=%d layers=%lu latest=%d",
          kMyVCamDiagPrefix,
          scanTick,
          MyVCamPreview_SessionIsLive() ? 1 : 0,
          layers,
          latest);
}

static void MyVCamPreview_LogCoverFrame(BOOL success,
                                        const char *reason,
                                        size_t width,
                                        size_t height,
                                        NSInteger status) {
    static int logged = 0;
    if (success) {
        if ((logged & 2) != 0) {
            return;
        }
        logged |= 2;
    } else {
        if ((logged & 1) != 0) {
            return;
        }
        logged |= 1;
    }
    NSLog(@"%s first frame to cover success=%d reason=%s width=%zu height=%zu status=%ld",
          kMyVCamDiagPrefix,
          success ? 1 : 0,
          reason != NULL ? reason : "-",
          width,
          height,
          (long)status);
}

static void MyVCamPreview_SyncTimebase(AVSampleBufferDisplayLayer *display, CMTime pts) {
    CMTimebaseRef timebase = NULL;
    CMTimebaseRef created = NULL;

    if (display == nil) {
        return;
    }
    timebase = display.controlTimebase;
    if (timebase == NULL) {
        if (CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &created) != noErr ||
            created == NULL) {
            return;
        }
        display.controlTimebase = created;
        timebase = created;
        CFRelease(created);
    }
    if (!CMTIME_IS_VALID(pts)) {
        pts = kCMTimeZero;
    }
    (void)CMTimebaseSetTime(timebase, pts);
    (void)CMTimebaseSetRate(timebase, 0.0);
}

static BOOL MyVCamPreview_PushSample(AVSampleBufferDisplayLayer *overlay, CMSampleBufferRef stamped) {
    if (overlay == nil || stamped == NULL) {
        return NO;
    }
    MyVCamPreview_SyncTimebase(overlay, CMSampleBufferGetPresentationTimeStamp(stamped));
    if (overlay.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [overlay flush];
    }
    if (!overlay.isReadyForMoreMediaData) {
        return NO;
    }
    [overlay enqueueSampleBuffer:stamped];
    return overlay.status != AVQueuedSampleBufferRenderingStatusFailed;
}

static void MyVCamPreview_Tick(void) {
    static uint32_t scanTick = 0;
    scanTick += 1;
    BOOL noLayers = gPreviewLayers == nil || gPreviewLayers.allObjects.count == 0;
    if (noLayers || (scanTick % 15u) == 1u) {
        MyVCamPreview_ScanWindows();
    }
    MyVCamPreview_ArmIfNeeded();
    if (!MyVCamPreview_SessionIsLive()) {
        MyVCamPreview_LogTimer(scanTick, -1);
        MyVCamPreview_RemoveOverlays();
        if ((scanTick % 30u) == 1u) {
            MyVCamStatus_SetCover(nil, nil, 0, nil, nil, "idle", nil, 0);
        }
        return;
    }
    if (gPreviewLayers == nil || gPreviewLayers.allObjects.count == 0) {
        MyVCamPreview_LogTimer(scanTick, -1);
        if (!gPreviewMissingLogged && scanTick > 30u) {
            gPreviewMissingLogged = YES;
            NSLog(@"%s preview layer not in a window", kMyVCamC1CPrefix);
        }
        MyVCamStatus_SetCover(nil, nil, 0, nil, nil, "no_layer", nil, scanTick == 31u);
        return;
    }
    VideoInjector *injector = [[MyVCamManager sharedManager] videoInjector];
    CMSampleBufferRef latest = injector != nil ? [injector copyLatestSampleBuffer] : NULL;
    MyVCamPreview_LogTimer(scanTick, latest != NULL ? 1 : 0);
    // Attach the covering view even before the first decoded frame so Photo
    // mode does not keep the live surface on top while the reader starts.
    BOOL enqueued = NO;
    for (AVCaptureVideoPreviewLayer *preview in gPreviewLayers.allObjects) {
        // A session that exists and is stopped is not the viewfinder. A layer
        // whose session property is still nil can already be on screen;
        // Photo mode does that before the property is published.
        if (preview.session != nil && !preview.session.isRunning) {
            continue;
        }
        AVSampleBufferDisplayLayer *overlay = MyVCamPreview_Overlay(preview, YES);
        UIView *hostCoverView = objc_getAssociatedObject(preview, &kMyVCamHostOverlayKey);
        AVSampleBufferDisplayLayer *secondary = MyVCamPreview_DisplayLayer([hostCoverView isKindOfClass:[UIView class]] ? hostCoverView : nil);
        AVSampleBufferDisplayLayer *reported = overlay != nil ? overlay : secondary;
        const char *reason = NULL;
        CMSampleBufferRef stamped = NULL;
        CVPixelBufferRef pixels = NULL;
        size_t width = 0;
        size_t height = 0;
        BOOL pushed = NO;
        if (secondary == overlay) {
            secondary = nil;
        }
        if (overlay == nil && secondary == nil) {
            // The slot was not ready. Still detach and disable the preview
            // so a missed cover cannot leave the live image up.
            MyVCamPreview_SuppressLive(preview);
            MyVCamPreview_LogCoverFrame(NO, "cover", 0, 0, AVQueuedSampleBufferRenderingStatusUnknown);
            MyVCamStatus_SetEnqueue(0, "cover", 0, 0, 0);
            continue;
        }
        if (latest == NULL) {
            MyVCamPreview_LogCoverFrame(NO, "latest", 0, 0, reported.status);
            MyVCamStatus_SetEnqueue(0, "latest", 0, 0, 0);
            continue;
        }
        if ((overlay == nil || !overlay.isReadyForMoreMediaData) &&
            (secondary == nil || !secondary.isReadyForMoreMediaData)) {
            MyVCamPreview_LogCoverFrame(NO, "not_ready", 0, 0, reported.status);
            MyVCamStatus_SetEnqueue(0, "not_ready", 0, 0, 0);
            continue;
        }
        stamped = MyVCamPreview_CopyDisplaySample(latest, &reason);
        if (stamped == NULL) {
            MyVCamPreview_LogCoverFrame(NO, reason != NULL ? reason : "sample", 0, 0, reported.status);
            MyVCamStatus_SetEnqueue(0, reason != NULL ? reason : "sample", 0, 0, 0);
            continue;
        }
        pushed = MyVCamPreview_PushSample(overlay, stamped) || MyVCamPreview_PushSample(secondary, stamped);
        pixels = CMSampleBufferGetImageBuffer(stamped);
        width = pixels != NULL ? CVPixelBufferGetWidth(pixels) : 0;
        height = pixels != NULL ? CVPixelBufferGetHeight(pixels) : 0;
        if (pushed) {
            gPreviewEnqueueStreak = 0;
            enqueued = YES;
            MyVCamPreview_LogCoverFrame(YES, "enqueued", width, height, reported.status);
            MyVCamStatus_SetEnqueue(1, "enqueued", (int)width, (int)height, !gPreviewLogged);
        } else {
            // Keep the cover. Dropping it restored the live preview, which
            // is what Photo mode was still showing. flush and the next tick
            // retry; the opaque view stays in front of the camera either way.
            gPreviewEnqueueStreak += 1;
            if (!gPreviewEnqueueFailedLogged) {
                gPreviewEnqueueFailedLogged = YES;
                NSLog(@"%s preview enqueue failed: %@", kMyVCamC1CPrefix, reported.error);
            }
            gPreviewForceCopy = YES;
            MyVCamPreview_LogCoverFrame(NO, "enqueue", width, height, reported.status);
            MyVCamStatus_SetEnqueue(0, "enqueue", (int)width, (int)height, 0);
            if (overlay != nil) {
                [overlay flush];
            }
            if (secondary != nil) {
                [secondary flush];
            }
            if (gPreviewEnqueueStreak >= 30) {
                gPreviewEnqueueStreak = 0;
                if (overlay != nil) {
                    [overlay flushAndRemoveImage];
                }
                if (secondary != nil) {
                    [secondary flushAndRemoveImage];
                }
            }
        }
        CFRelease(stamped);
    }
    if (latest != NULL) {
        CFRelease(latest);
    }
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
        // Leave the timer. The next session may already be running by the
        // time startRunning's hook can see it; the tick arms that session.
        gPreviewLogged = NO;
        gPreviewEnqueueFailedLogged = NO;
        gPreviewMissingLogged = NO;
        gPreviewEnqueueStreak = 0;
        gPreviewForceCopy = NO;
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

- (void)setHidden:(BOOL)hidden {
    AVCaptureVideoPreviewLayer *preview = (AVCaptureVideoPreviewLayer *)self;
    if (!gMyVCamForcingLive && !gMyVCamRestoringPreview && MyVCamPreview_Covering(preview)) {
        gMyVCamForcingLive = 1;
        %orig(YES);
        gMyVCamForcingLive = 0;
        return;
    }
    %orig(hidden);
}

- (void)setOpacity:(float)opacity {
    AVCaptureVideoPreviewLayer *preview = (AVCaptureVideoPreviewLayer *)self;
    if (!gMyVCamForcingLive && !gMyVCamRestoringPreview && MyVCamPreview_Covering(preview)) {
        gMyVCamForcingLive = 1;
        %orig(0.0f);
        gMyVCamForcingLive = 0;
        return;
    }
    %orig(opacity);
}

- (void)layoutSublayers {
    AVCaptureVideoPreviewLayer *preview = (AVCaptureVideoPreviewLayer *)self;
    %orig;
    if (gMyVCamForcingLive || gMyVCamRestoringPreview || !MyVCamPreview_Covering(preview)) {
        return;
    }
    gMyVCamForcingLive = 1;
    if (!preview.hidden) {
        preview.hidden = YES;
    }
    if (preview.opacity != 0.0f) {
        preview.opacity = 0.0f;
    }
    gMyVCamForcingLive = 0;
}

%end

static BOOL MyVCamPreview_ShouldKeepDetached(CALayer *layer) {
    AVCaptureVideoPreviewLayer *preview = nil;

    if (![layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
        return NO;
    }
    preview = (AVCaptureVideoPreviewLayer *)layer;
    if (MyVCamPreview_IsBackingLayer(preview)) {
        return NO;
    }
    return MyVCamPreview_IsCovered(preview);
}

%hook CALayer

- (void)addSublayer:(CALayer *)layer {
    if (MyVCamPreview_ShouldKeepDetached(layer)) {
        MyVCamPreview_LogDetached();
        return;
    }
    %orig;
}

- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned int)idx {
    if (MyVCamPreview_ShouldKeepDetached(layer)) {
        MyVCamPreview_LogDetached();
        (void)idx;
        return;
    }
    %orig;
}

- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling {
    if (MyVCamPreview_ShouldKeepDetached(layer)) {
        MyVCamPreview_LogDetached();
        (void)sibling;
        return;
    }
    %orig;
}

- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling {
    if (MyVCamPreview_ShouldKeepDetached(layer)) {
        MyVCamPreview_LogDetached();
        (void)sibling;
        return;
    }
    %orig;
}

- (void)replaceSublayer:(CALayer *)layer with:(CALayer *)replacement {
    if (MyVCamPreview_ShouldKeepDetached(replacement)) {
        MyVCamPreview_LogDetached();
        (void)layer;
        return;
    }
    %orig;
}

- (void)setSublayers:(NSArray<CALayer *> *)sublayers {
    BOOL strip = NO;
    NSMutableArray<CALayer *> *kept = nil;

    if (sublayers == nil || gMyVCamInLayerInsert) {
        %orig;
        return;
    }
    for (CALayer *layer in sublayers) {
        if (MyVCamPreview_ShouldKeepDetached(layer)) {
            strip = YES;
            break;
        }
    }
    if (!strip) {
        %orig;
        return;
    }
    kept = [NSMutableArray arrayWithCapacity:sublayers.count];
    for (CALayer *layer in sublayers) {
        if (!MyVCamPreview_ShouldKeepDetached(layer)) {
            [kept addObject:layer];
        }
    }
    MyVCamPreview_LogDetached();
    gMyVCamInLayerInsert = 1;
    %orig(kept);
    gMyVCamInLayerInsert = 0;
}

%end

%hook AVCaptureConnection

- (void)setEnabled:(BOOL)enabled {
    if (!enabled || gMyVCamInConnectionHook || !MyVCamPreview_ConnectionIsBlocked(self)) {
        %orig(enabled);
        return;
    }
    gMyVCamInConnectionHook = 1;
    %orig(NO);
    gMyVCamInConnectionHook = 0;
    MyVCamPreview_LogConnectionBlocked();
}

%end

// Positive SpringBoard match only. Camera and any other process still
// install the existing hooks. SpringBoard must not.
static int MyVCamLoad_IsSpringBoard(void) {
    const char *prog = getprogname();
    char executable[1024];
    uint32_t size = sizeof(executable);

    if (prog != NULL && strcmp(prog, "SpringBoard") == 0) {
        return 1;
    }
    executable[0] = '\0';
    if (_NSGetExecutablePath(executable, &size) == 0) {
        const char *leaf = MyVCamLoad_LastComponent(executable);
        if (leaf != NULL && strcmp(leaf, "SpringBoard") == 0) {
            return 1;
        }
    }
    @autoreleasepool {
        NSString *name = [[NSProcessInfo processInfo] processName];
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
        if ([name isEqualToString:@"SpringBoard"] ||
            [bundle isEqualToString:@"com.apple.springboard"]) {
            return 1;
        }
    }
    return 0;
}

%ctor {
    // First, before InitState and %init. Mach-O ignores constructor
    // priority, so this is the earliest reliable write. A dylib that maps
    // and then dies in InitState or the hook installer still leaves
    // ctor=1 init=0 in runtime.status. proc= is SpringBoard or Camera.
    MyVCamStatus_Mark(1, 0);
    // Load witness only. Do not install Camera hooks in SpringBoard.
    if (MyVCamLoad_IsSpringBoard()) {
        return;
    }
    MyVCamC1A_InitState();
    dispatch_async(dispatch_get_main_queue(), ^{
        %init;
        NSLog(@"%s init runs=1", kMyVCamDiagPrefix);
        NSLog(@"%s hooks installed", kMyVCamC1APrefix);
        MyVCamStatus_Mark(1, 1);
        MyVCamPreview_Start();
    });
}
