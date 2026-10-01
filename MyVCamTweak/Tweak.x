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
//  delegate. The display layer is a UIView inserted at the back of the
//  preview's host view, so it covers the live image and stays under chrome.
//  A loose sibling of the preview is what Photo mode kept painting over.
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
#import <fcntl.h>
#import <limits.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
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
static const char kMyVCamDiagPrefix[] = "[MyVCam 0.2.8]";
static const char kMyVCamDisablePath[] = "/var/mobile/Documents/MyVCam/disable";
// Dopamine issues the sandbox extension for the real jbroot vnode
// (JBROOT_PATH("/var/mobile")), not for the "/var/jb" symlink string.
// myvcam-mirror writes the symlink path and Camera's container. open()
// is the check; access() rejects paths this process can still open.
static const char kMyVCamMirrorVideoPath[] = "/var/jb/var/mobile/Library/MyVCam/test.mp4";
static const char kMyVCamMirrorDisablePath[] = "/var/jb/var/mobile/Library/MyVCam/disable";
static const char kMyVCamMirrorStatusPath[] = "/var/jb/var/mobile/Library/MyVCam/mirror.status";
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
static __thread int gMyVCamInDelegateHook;
static int gMyVCamStartDepth = 0;
static __thread int gMyVCamInStop;

static void MyVCamC1B_MatchTick(uint64_t generation);
static BOOL MyVCamC1C_SessionDidStart(uint64_t generation);
static void MyVCamC1C_ScheduleEnable(uint64_t generation);
static void MyVCamC1C_EnableOnQueue(uint64_t generation, int attempt, int prepareFailures);
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
    NSLog(@"%s hook hit replaced=%d", kMyVCamDiagPrefix, replaced ? 1 : 0);
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
        NSLog(@"%s feed not started: test video path is empty", kMyVCamC1CPrefix);
        return NO;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:path isDirectory:NO];
    [manager attachMediaFileURL:fileURL];
    NSError *error = nil;
    BOOL started = [manager startWithError:&error];
    if (!MyVCamC1C_GenerationIsCurrent(generation)) {
        [manager stop];
        NSLog(@"%s feed not started: capture session ended during prepare", kMyVCamC1CPrefix);
        return NO;
    }
    if (!started) {
        NSLog(@"%s feed not started path=%s error=%@", kMyVCamC1CPrefix, readable, error);
        return NO;
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
        NSLog(@"%s feed not started: disable file %s (delete it and reopen Camera to re-enable)",
              kMyVCamC1CPrefix,
              kMyVCamDisablePath);
        return;
    }

    int videoErrno = 0;
    if (MyVCamC1C_ReadableVideoPath(&videoErrno) == NULL) {
        MyVCamC1C_LogMirrorStatus(attempt, videoErrno);
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
        if (prepareFailures < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), gEnableQueue, ^{
                MyVCamC1C_EnableOnQueue(generation, attempt, prepareFailures + 1);
            });
        }
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
        NSLog(@"%s hook hit", kMyVCamDiagPrefix);
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

/// Host view for the imported frames. A loose CALayer sibling stays under
/// Photo mode's live preview surface. A subview at index 0 is above that
/// surface and under shutter / focus views added later.
@interface MyVCamPreviewHostView : UIView
@end

@implementation MyVCamPreviewHostView
+ (Class)layerClass {
    return [AVSampleBufferDisplayLayer class];
}
@end

static UIView *MyVCamPreview_HostView(AVCaptureVideoPreviewLayer *preview, BOOL *previewIsHostLayer) {
    if (previewIsHostLayer != NULL) {
        *previewIsHostLayer = NO;
    }
    id previewDelegate = preview.delegate;
    if ([previewDelegate isKindOfClass:[UIView class]] &&
        ((UIView *)previewDelegate).layer == (CALayer *)preview) {
        if (previewIsHostLayer != NULL) {
            *previewIsHostLayer = YES;
        }
        return (UIView *)previewDelegate;
    }
    CALayer *superlayer = preview.superlayer;
    id superDelegate = superlayer.delegate;
    if ([superDelegate isKindOfClass:[UIView class]] &&
        ((UIView *)superDelegate).layer == superlayer) {
        return (UIView *)superDelegate;
    }
    return nil;
}

static void MyVCamPreview_RestoreOpacity(AVCaptureVideoPreviewLayer *preview) {
    NSNumber *saved = objc_getAssociatedObject(preview, &kMyVCamOpacityAssociationKey);
    if (saved == nil) {
        return;
    }
    preview.opacity = saved.floatValue;
    objc_setAssociatedObject(preview, &kMyVCamOpacityAssociationKey, nil, OBJC_ASSOCIATION_ASSIGN);
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

static void MyVCamPreview_DropOverlay(AVCaptureVideoPreviewLayer *preview) {
    if (preview == nil) {
        return;
    }
    MyVCamPreviewHostView *view = objc_getAssociatedObject(preview, &kMyVCamOverlayAssociationKey);
    if ([view isKindOfClass:[MyVCamPreviewHostView class]]) {
        [view removeFromSuperview];
    }
    objc_setAssociatedObject(preview, &kMyVCamOverlayAssociationKey, nil, OBJC_ASSOCIATION_ASSIGN);
    MyVCamPreview_RestoreOpacity(preview);
    MyVCamPreview_RemoveNamedSublayers(preview);
    MyVCamPreview_RemoveNamedSublayers(preview.superlayer);
}

static void MyVCamPreview_RemoveOverlays(void) {
    for (AVCaptureVideoPreviewLayer *preview in gPreviewLayers.allObjects) {
        MyVCamPreview_DropOverlay(preview);
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
    NSLog(@"%s overlay create ok=%d view=%@ layer=%@ added_to=%@ in_window=%d hierarchy=%d",
          kMyVCamDiagPrefix,
          ok ? 1 : 0,
          overlay != nil ? NSStringFromClass(overlay.class) : @"-",
          overlay != nil ? NSStringFromClass(overlay.layer.class) : @"-",
          host != nil ? NSStringFromClass(host.class) : @"-",
          inWindow ? 1 : 0,
          inHierarchy ? 1 : 0);
}

/// UIView above the live image. When the preview is only a sublayer, its
/// opacity is cleared while this view is in a window so the camera surface
/// cannot paint over the imported frames. Chrome that is a later subview of
/// the host stays above index 0.
static AVSampleBufferDisplayLayer *MyVCamPreview_Overlay(AVCaptureVideoPreviewLayer *preview, BOOL create) {
    static BOOL loggedHost = NO;
    BOOL previewIsHostLayer = NO;
    UIView *host = MyVCamPreview_HostView(preview, &previewIsHostLayer);
    MyVCamPreviewHostView *overlay = objc_getAssociatedObject(preview, &kMyVCamOverlayAssociationKey);
    CGRect frame = CGRectZero;

    if (![overlay isKindOfClass:[MyVCamPreviewHostView class]]) {
        overlay = nil;
    }
    if (host != nil) {
        if (previewIsHostLayer) {
            frame = host.bounds;
        } else if (preview.superlayer == host.layer) {
            frame = preview.frame;
        } else {
            frame = [host.layer convertRect:preview.bounds fromLayer:preview];
        }
    }
    if (overlay == nil) {
        if (!create || host == nil || CGRectIsEmpty(frame)) {
            if (create) {
                MyVCamPreview_LogOverlay(NO, host, nil);
            }
            return nil;
        }
        overlay = [[MyVCamPreviewHostView alloc] initWithFrame:frame];
        overlay.userInteractionEnabled = NO;
        overlay.backgroundColor = [UIColor blackColor];
        overlay.opaque = YES;
        overlay.clipsToBounds = YES;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlay.layer.name = kMyVCamPreviewOverlayName;
        AVSampleBufferDisplayLayer *display = (AVSampleBufferDisplayLayer *)overlay.layer;
        display.videoGravity = AVLayerVideoGravityResizeAspectFill;
        display.backgroundColor = [UIColor blackColor].CGColor;
        display.contentsScale = UIScreen.mainScreen.scale;
        objc_setAssociatedObject(preview,
                                 &kMyVCamOverlayAssociationKey,
                                 overlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (host == nil || CGRectIsEmpty(frame)) {
        MyVCamPreview_LogOverlay(NO, host, overlay);
        return nil;
    }
    overlay.frame = frame;
    overlay.hidden = NO;
    overlay.alpha = 1.0;
    if (overlay.superview != host || [host.subviews indexOfObject:overlay] != 0) {
        [host insertSubview:overlay atIndex:0];
    }
    if (!previewIsHostLayer && overlay.window != nil) {
        if (objc_getAssociatedObject(preview, &kMyVCamOpacityAssociationKey) == nil) {
            objc_setAssociatedObject(preview,
                                     &kMyVCamOpacityAssociationKey,
                                     @(preview.opacity),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        preview.opacity = 0;
    }
    if (!loggedHost) {
        loggedHost = YES;
        NSLog(@"%s preview overlay attached host=%@", kMyVCamC1CPrefix, NSStringFromClass(host.class));
    }
    MyVCamPreview_LogOverlay(YES, host, overlay);
    return (AVSampleBufferDisplayLayer *)overlay.layer;
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

static void MyVCamPreview_Tick(void) {
    static uint32_t scanTick = 0;
    scanTick += 1;
    BOOL noLayers = gPreviewLayers == nil || gPreviewLayers.allObjects.count == 0;
    if (noLayers || (scanTick % 15u) == 1u) {
        MyVCamPreview_ScanWindows();
    }
    MyVCamPreview_ArmIfNeeded();
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
        if (overlay == nil || latest == NULL) {
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
            // Keep the view. Removing it on the first failure is what left
            // the live preview uncovered. flush and the next tick retry.
            // A layer that stays failed is rebuilt so Photo mode does not
            // sit on a dead AVSampleBufferDisplayLayer.
            gPreviewEnqueueStreak += 1;
            if (!gPreviewEnqueueFailedLogged) {
                gPreviewEnqueueFailedLogged = YES;
                NSLog(@"%s preview enqueue failed: %@", kMyVCamC1CPrefix, overlay.error);
            }
            [overlay flush];
            if (gPreviewEnqueueStreak >= 30) {
                gPreviewEnqueueStreak = 0;
                MyVCamPreview_DropOverlay(preview);
            }
        } else {
            gPreviewEnqueueStreak = 0;
            enqueued = YES;
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
        MyVCamPreview_Start();
    });
}
