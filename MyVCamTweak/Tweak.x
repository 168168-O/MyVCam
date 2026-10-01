//
//  Tweak.x
//  MyVCam
//
//  C1-A: hook AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:,
//  then hook that delegate class's
//  -captureOutput:didOutputSampleBuffer:fromConnection: once.
//
//  C1-B: the same delegate hook reads VideoInjector. When
//  copyLatestSampleBufferMatchingOrigin: returns a buffer, the original
//  IMP is called with that replacement and the replacement is CFReleased.
//  When it returns NULL, the original IMP is called with the original
//  sampleBuffer. The original sampleBuffer is never mutated.
//  The delegate hook does not call inject or injectNext and does not arm
//  a timer. That work stays on MyVCamManager's feed queue.
//
//  C1-C: AVCaptureSession startRunning attaches the fixed test video and
//  calls startWithError:. stopRunning calls stop. The manager owns the
//  30 fps loop. This file does not decode and does not touch mediaserverd.
//
//  MyVCamTweak.plist matches com.apple.camera only.
//

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
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

static void MyVCamC1A_DidOutput(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
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

    if (original != NULL) {
        // Caller-owned when non-NULL. The camera buffer itself is not written.
        CMSampleBufferRef replacement = NULL;
        if (sampleBuffer != NULL) {
            VideoInjector *injector = [[MyVCamManager sharedManager] videoInjector];
            replacement = [injector copyLatestSampleBufferMatchingOrigin:sampleBuffer];
        }
        if (replacement != NULL) {
            MyVCamC1B_LogPathOnce(YES);
            ((MyVCamC1ACaptureOutputIMP)original)(self, _cmd, output, replacement, connection);
            CFRelease(replacement);
        } else {
            MyVCamC1B_LogPathOnce(NO);
            ((MyVCamC1ACaptureOutputIMP)original)(self, _cmd, output, sampleBuffer, connection);
        }
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

static void MyVCamC1C_SessionDidStart(void) {
    // Attach and start on the thread that called startRunning. Frame pulls
    // happen later, on the manager's feed queue, not on this thread and not
    // on the sample-buffer delegate queue. A missing file returns NO.
    MyVCamManager *manager = [MyVCamManager sharedManager];
    NSString *path = [NSString stringWithUTF8String:MyVCamManagerTestVideoPathUTF8];
    if (path.length == 0) {
        NSLog(@"%s feed not started: test video path is empty", kMyVCamC1CPrefix);
        return;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:path isDirectory:NO];
    [manager attachMediaFileURL:fileURL];
    NSError *error = nil;
    if (![manager startWithError:&error]) {
        NSLog(@"%s feed not started path=%s error=%@", kMyVCamC1CPrefix, MyVCamManagerTestVideoPathUTF8, error);
        return;
    }
    NSLog(@"%s feed started path=%s", kMyVCamC1CPrefix, MyVCamManagerTestVideoPathUTF8);
}

static void MyVCamC1C_SessionDidStop(void) {
    [[MyVCamManager sharedManager] stop];
    NSLog(@"%s capture session stopped the feed", kMyVCamC1CPrefix);
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    MyVCamC1A_HookDelegateIfNeeded(sampleBufferDelegate);
    %orig;
}

%end

%hook AVCaptureSession

- (void)startRunning {
    MyVCamC1C_SessionDidStart();
    %orig;
}

- (void)stopRunning {
    MyVCamC1C_SessionDidStop();
    %orig;
}

%end

%ctor {
    MyVCamC1A_InitState();
    %init;
}
