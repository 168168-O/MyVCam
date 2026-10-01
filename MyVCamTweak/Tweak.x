//
//  Tweak.x
//  MyVCam
//
//  C1-A: hook AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:,
//  then hook that delegate class's
//  -captureOutput:didOutputSampleBuffer:fromConnection: once.
//  The hook is installed only when the method encoding is the void instance
//  method Camera uses. A NULL original IMP is never called.
//
//  C1-B: the same delegate hook reads VideoInjector for video image buffers
//  only. Audio (and any other non-image sample) is passed through untouched.
//  When copyLatestSampleBufferMatchingOrigin: returns a buffer, the original
//  IMP is called with that replacement. The camera-owned sampleBuffer is
//  never CFReleased and never written. The replacement stays retained across
//  the callback (last two deliveries) because Camera may use the pointer
//  after the callback returns.
//  When the copy returns NULL, the original IMP is called with the original
//  sampleBuffer. NULL covers "no frame yet" and "origin format was not matched".
//  The delegate hook does not call inject or injectNext and does not arm
//  a timer. That work stays on MyVCamManager's feed queue.
//
//  C1-C: AVCaptureSession startRunning only records that a session is up.
//  It does not attach, prepare, or decode. The first video delegate callback
//  schedules attach+start on a background queue after the main queue has had
//  a turn, so startRunning is not blocked and the feed does not run inside it.
//  stopRunning calls stop before the original implementation. The manager owns
//  the 30 fps loop. This file does not decode and does not touch mediaserverd.
//
//  MyVCamTweak.plist matches com.apple.camera only.
//

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdlib.h>
#import <substrate.h>
#import "MyVCamManager.h"
#import "VideoInjector.h"

typedef void (*MyVCamC1ACaptureOutputIMP)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *);

typedef struct {
    Class cls;
    IMP imp;
} MyVCamC1AOriginal;

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
static BOOL gC1BLoggedPassThrough = NO;
static BOOL gC1BLoggedReplace = NO;
static BOOL gCaptureSessionRunning = NO;
static BOOL gFeedStartRequested = NO;
static uint64_t gSessionGeneration = 0;
static CMSampleBufferRef gHandoff[2] = {NULL, NULL};

static void MyVCamC1A_InitState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gHookedClasses = [[NSMutableSet alloc] init];
        gLoggedClasses = [[NSMutableSet alloc] init];
        gMissingClasses = [[NSMutableSet alloc] init];
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

static BOOL MyVCamC1A_EncodingCanCall(Method method) {
    if (method == NULL) {
        return NO;
    }
    // self, _cmd, output, sampleBuffer, connection.
    if (method_getNumberOfArguments(method) != 5) {
        return NO;
    }
    const char *encoding = method_getTypeEncoding(method);
    return encoding != NULL && encoding[0] == 'v';
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

/// Takes ownership of `owned` (+1 or NULL). Retires the delivery from two
/// callbacks ago. The camera buffer is never stored here.
static void MyVCamC1B_StoreHandoff(CMSampleBufferRef owned) {
    CMSampleBufferRef retired = NULL;
    os_unfair_lock_lock(&gLock);
    retired = gHandoff[1];
    gHandoff[1] = gHandoff[0];
    gHandoff[0] = owned;
    os_unfair_lock_unlock(&gLock);
    if (retired != NULL) {
        CFRelease(retired);
    }
}

static void MyVCamC1C_SessionDidStart(uint64_t generation) {
    // Runs off the capture delegate queue and off -startRunning. A missing
    // file returns NO and does not arm the timer. If the session stopped
    // while prepare was in flight, stop again so a late arm does not keep
    // decoding into a dead session.
    os_unfair_lock_lock(&gLock);
    BOOL current = gCaptureSessionRunning && gSessionGeneration == generation;
    os_unfair_lock_unlock(&gLock);
    if (!current) {
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
    os_unfair_lock_lock(&gLock);
    current = gCaptureSessionRunning && gSessionGeneration == generation;
    os_unfair_lock_unlock(&gLock);
    if (!current) {
        [manager stop];
        NSLog(@"%s feed not started: capture session ended during prepare", kMyVCamC1CPrefix);
        return;
    }
    if (!started) {
        NSLog(@"%s feed not started path=%s error=%@", kMyVCamC1CPrefix, MyVCamManagerTestVideoPathUTF8, error);
        return;
    }
    NSLog(@"%s feed started path=%s", kMyVCamC1CPrefix, MyVCamManagerTestVideoPathUTF8);
}

static void MyVCamC1C_NoteSessionStarted(void) {
    os_unfair_lock_lock(&gLock);
    gCaptureSessionRunning = YES;
    gSessionGeneration += 1;
    gFeedStartRequested = NO;
    os_unfair_lock_unlock(&gLock);
}

static void MyVCamC1C_NoteSessionStopped(void) {
    os_unfair_lock_lock(&gLock);
    gCaptureSessionRunning = NO;
    gSessionGeneration += 1;
    gFeedStartRequested = NO;
    os_unfair_lock_unlock(&gLock);
    [[MyVCamManager sharedManager] stop];
    NSLog(@"%s capture session stopped the feed", kMyVCamC1CPrefix);
}

static void MyVCamC1C_RequestFeedStart(void) {
    uint64_t generation = 0;
    os_unfair_lock_lock(&gLock);
    if (!gCaptureSessionRunning || gFeedStartRequested) {
        os_unfair_lock_unlock(&gLock);
        return;
    }
    gFeedStartRequested = YES;
    generation = gSessionGeneration;
    os_unfair_lock_unlock(&gLock);

    NSLog(@"%s feed deferred until after the first video sample", kMyVCamC1CPrefix);
    // Bounce through the main queue first so a callback delivered inside
    // -startRunning does not prepare until that call can return.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            os_unfair_lock_lock(&gLock);
            BOOL current = gCaptureSessionRunning && gSessionGeneration == generation;
            os_unfair_lock_unlock(&gLock);
            if (!current) {
                return;
            }
            MyVCamC1C_SessionDidStart(generation);
        });
    });
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

    // Same selector as the audio data-output delegate. Substituting a video
    // buffer there crashes Camera on the first callback after a frame exists.
    if (!MyVCamC1B_OriginIsVideoImage(sampleBuffer)) {
        ((MyVCamC1ACaptureOutputIMP)original)(self, _cmd, output, sampleBuffer, connection);
        return;
    }

    MyVCamC1C_RequestFeedStart();

    CMSampleBufferRef replacement = NULL;
    VideoInjector *injector = [[MyVCamManager sharedManager] videoInjector];
    if (injector != nil && sampleBuffer != NULL) {
        replacement = [injector copyLatestSampleBufferMatchingOrigin:sampleBuffer];
    }
    if (replacement != NULL) {
        MyVCamC1B_LogPathOnce(YES);
        ((MyVCamC1ACaptureOutputIMP)original)(self, _cmd, output, replacement, connection);
        // Keep this buffer alive past the callback. Do not release sampleBuffer.
        MyVCamC1B_StoreHandoff(replacement);
    } else {
        MyVCamC1B_LogPathOnce(NO);
        ((MyVCamC1ACaptureOutputIMP)original)(self, _cmd, output, sampleBuffer, connection);
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

    Method method = class_getInstanceMethod(implClass, selector);
    IMP prior = method != NULL ? method_getImplementation(method) : NULL;
    if (prior == (IMP)MyVCamC1A_DidOutput) {
        [gHookedClasses addObject:(id)implClass];
        os_unfair_lock_unlock(&gLock);
        return;
    }
    if (!MyVCamC1A_EncodingCanCall(method)) {
        [gHookedClasses addObject:(id)implClass];
        os_unfair_lock_unlock(&gLock);
        const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
        NSLog(@"%s refused to hook %@ encoding=%s", kMyVCamC1APrefix, NSStringFromClass(implClass), encoding != NULL ? encoding : "");
        return;
    }

    [gHookedClasses addObject:(id)implClass];
    IMP replaced = NULL;
    MSHookMessageEx(implClass, selector, (IMP)MyVCamC1A_DidOutput, &replaced);
    IMP original = replaced != NULL ? replaced : prior;
    if (original == NULL || original == (IMP)MyVCamC1A_DidOutput || !MyVCamC1A_StoreOriginal(implClass, original)) {
        os_unfair_lock_unlock(&gLock);
        NSLog(@"%s failed to hook %@", kMyVCamC1APrefix, NSStringFromClass(implClass));
        return;
    }
    os_unfair_lock_unlock(&gLock);
    NSLog(@"%s hooked captureOutput:didOutputSampleBuffer:fromConnection: on %@", kMyVCamC1APrefix, NSStringFromClass(implClass));
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    MyVCamC1A_HookDelegateIfNeeded(sampleBufferDelegate);
    %orig;
}

%end

%hook AVCaptureSession

- (void)startRunning {
    // Flags only. Preparing the file here used to block this thread and run
    // AVAssetReader inside the capture startup.
    MyVCamC1C_NoteSessionStarted();
    %orig;
}

- (void)stopRunning {
    MyVCamC1C_NoteSessionStopped();
    %orig;
}

%end

%ctor {
    MyVCamC1A_InitState();
    %init;
}
