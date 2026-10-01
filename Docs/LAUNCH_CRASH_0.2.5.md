# Camera launch crash after 0.2.4

Device report: iPhone 12, iOS 15.3.1, Dopamine rootless. `test.mp4` is at `/var/mobile/Documents/MyVCam/test.mp4`. Camera (`com.apple.camera`) still force-quits on first open after 0.2.4 (`e5d2931223ae69454abe7e7c28d0df1086d7a7bf`, PR #10). No new device run was used. The ranking is from the 0.2.4 sources and the Actions log of that package.

0.2.5 keeps the same chain: `MyVCamManager` → `MediaReader` → `SampleBufferBuilder` → `VideoInjector` → the Camera delegate hook. The filter is still `com.apple.camera` only.

## Ranked causes

### 1. Broken arm64e slice (highest)

Actions run [36815248390](https://github.com/168168-O/MyVCam/actions/runs/36815248390) links the 0.2.4 dylib with:

```
ld: warning: object file ... was built with an incompatible arm64e ABI compiler
```

iPhone 12 (A14) is arm64e. dyld picks the arm64e slice of a fat dylib. That slice's pointer-auth ABI does not match iOS 15, so Camera dies on the first authenticated call. That is during image load or the constructor, before `startRunning`, before the feed, and before any sample buffer. The 0.2.4 logic changes never ran on this phone.

0.2.5 ships arm64 only. ElleKit on Dopamine loads an arm64 tweak into an arm64e process. The Linux toolchain is unchanged; arm64e is not built.

### 2. Capture callback still did the dangerous work (high)

After the slice loads, 0.2.4 still did this on the first video callback, on Camera's queue, before the original IMP:

- `CMSampleBuffer` inspection
- schedule of attach + `AVAssetReader` prepare
- once a frame existed, `copyLatestSampleBufferMatchingOrigin:` (vImage scale and 420 conversion) on that same queue
- `CFRelease` of the replacement two callbacks later

A convert fault, or a buffer Camera's pipeline still held, kills the process on the first replaced frame. The feed's first timer fire is immediate, so that frame is during the open, not later.

0.2.5 calls the original IMP and returns for the first 30 callbacks. It does not inspect the sample and does not message `VideoInjector`. `com.myvcam.match` builds the replacement. The callback only restamps a finished buffer, and only for a video image. The last eight deliveries stay retained.

### 3. `startRunning` / `stopRunning` order (medium)

0.2.4 set the running flag before `%orig`. Camera calls `stopRunning` from inside `startRunning`, which cleared the flag while the session stayed up, or ran `-[MyVCamManager stop]` on the session thread. `stop` reaches `MediaReader`, which `dispatch_sync`s to `com.myvcam.reader`. If that queue is inside a media-server call that needs the session thread, the process watchdog-kills. `os_unfair_lock` also aborts if the same thread locks it again (`_os_unfair_lock_recursive_abort`).

0.2.5 calls `%orig` on `startRunning` first, then sets the flag. `stopRunning` only updates flags and stops the manager on `com.myvcam.enable`. A re-entrancy guard covers a same-thread re-entry of the hook.

### 4. Delegate hook install (medium)

0.2.4 called `MSHookMessageEx` while holding `gLock`, from inside `setSampleBufferDelegate:queue:`, before `%orig`. ElleKit can re-enter while it patches the class. A same-thread relock aborts. Patching the class before AVFoundation has finished the setter is the same window.

0.2.5 calls `%orig` first, claims the class, drops the lock, then hooks. The encoding check requires a void method whose arguments are an object, a pointer, and an object. `%init` runs on the next main-queue turn so the constructor does not hook while dyld is still loading images. There is no `+load`.

### 5. `MediaReader` track load on a serial queue (lower)

The first prepare in 0.2.4 is not on `com.myvcam.feed`. The loop path is. `loadTracksWithMediaType:completionHandler:` plus `dispatch_semaphore_wait` on that serial queue deadlocks if the completion needs the same queue. That is not the first-open path. 0.2.5 starts the load on a concurrent queue and waits on the caller. An `NSException` from the reader build becomes `PrepareFailed` instead of an uncaught exception.

### 6. Sample attachments (lower)

`CMSampleBufferGetSampleAttachmentsArray` can return an array whose first element is not a dictionary. `CFDictionarySetValue` on that pointer faults. Copying every origin attachment into the replacement can alias memory the camera buffer owns; releasing the camera buffer then faults on a later frame.

0.2.5 type-checks the attachment dictionary, sets display-immediately, and copies the camera intrinsic matrix only when it is a `CFData`. Nothing else is aliased.

## Discarded

- **`CVBufferCopyAttachment` missing on iOS 15.3.1.** The symbol is iOS 15.0+. It is not a dyld abort on this phone.
- **Filter injects the wrong process.** `MyVCamTweak.plist` is `Bundles` → `com.apple.camera` only. It does not name `mediaserverd` or SpringBoard.
- **Empty injector crashes the hook.** With no published buffer the hook calls the original IMP and does not message `VideoInjector`, does not convert, and does not `CFRelease` the camera sample.
- **ElleKit's `MSHookMessageEx` ABI differs from Substrate.** The original IMP is still the pointer ElleKit writes. The ElleKit failure on this device is the arm64e slice, not the hook call.

## Safe mode

Replacement stays off until 30 delegate callbacks have returned. Create `/var/mobile/Documents/MyVCam/disable` to keep that passthrough for the rest of the launch (no feed, no `AVAssetReader`, no replacement). Delete the file and reopen Camera to re-enable. The hooks stay installed either way.
