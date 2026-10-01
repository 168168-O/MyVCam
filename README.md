# MyVCam

The local-file chain feeds `VideoInjector`. The injector keeps the latest retained sample buffer. C1-B reads that buffer from the Camera delegate hook. C1-C is the manager-owned loop that keeps calling inject while a capture session is running. It does not deliver into mediaserverd.

```
MyVCamManager
  → MediaReader (local file, AVAssetReader)
      → CVPixelBuffer
  → SampleBufferBuilder
      → CMSampleBuffer
  → VideoInjector
      → latest retained buffer
          → C1-B read from the Camera delegate hook
  C1-C timer on com.myvcam.feed calls injectNext at 30 fps
```

## C1-A — hook install

`Tweak.x` hooks `-[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]`. When a delegate is set, it installs a one-time hook on the class that implements `-captureOutput:didOutputSampleBuffer:fromConnection:`. That hook logs once per delegate class. C1-B, below, decides which sample buffer the original implementation receives.

`MyVCamTweak.plist` matches `com.apple.camera` only. `%init` runs on the next turn of the main queue, after the constructor returns. `setSampleBufferDelegate:queue:` calls the original implementation before the delegate class is hooked. This stage does not install the package and does not claim a device result. On a device, the hook fired when the log contains:

```
[MyVCam C1-A] captureOutput:didOutputSampleBuffer:fromConnection: fired class=<DelegateClass>
```

The install log is `[MyVCam C1-A] hooked captureOutput:didOutputSampleBuffer:fromConnection: on <Class>`.

## C1-B — read the latest frame into that hook

`com.myvcam.match` calls `-[VideoInjector copyLatestSampleBufferMatchingOrigin:]` on `[MyVCamManager sharedManager].videoInjector`. The capture callback does not call it.

- Until a buffer has been published, the callback passes the original `sampleBuffer` through and does not message the injector.
- A published buffer is restamped with the current sample's timing and passed to the original IMP for a video image only. Audio stays on the camera sample.
- NULL from the copy means the hook keeps passing the original `sampleBuffer` through.
- The original `sampleBuffer` is never written and never released.

The new buffer keeps the origin sample's presentation time and duration, and its pixels are the latest frame scaled into an IOSurface buffer of the origin's width, height, and pixel format (`32BGRA`, `420f`, or `420v`). A non-video origin (including audio, which shares this selector), a missing or non-numeric origin presentation time, a latest buffer with no image buffer, an unsupported origin format, or a CoreMedia create failure returns NULL (pass-through). Duration falls back to 1/30 second when the origin duration is not a positive numeric time. The sample-attachment array is created and marked display-immediately. The camera intrinsic matrix is copied when it is a `CFData`. Other origin attachments are not aliased. The camera-owned buffer is never released. The hook keeps the last eight replacements so Camera can use a pointer after the callback returns.

Each path logs once per process:

```
[MyVCam C1-B] pass-through original sampleBuffer
[MyVCam C1-B] replaced sampleBuffer with VideoInjector latest
```

Actions can compile this glue. It cannot show a live replacement. The replace log happens only after a frame has been stored. C1-C, below, is the caller that stores frames. Until that feed has stored one, the hook pass-through is the expected device result.

`copyNextSampleBufferWithError:` stops at the sample buffer. `injectNextSampleBufferWithError:` borrows that buffer to `VideoInjector` and `CFRelease`s the original. Once armed, `injectSampleBuffer:error:` returns `YES` for a non-NULL buffer and `CFRetain`s it as the latest buffer. `NotPrepared` and `InvalidSampleBuffer` stay failures.

## C1-C — feed loop

The test video is a fixed path. There is no preferences UI and the file is not inside the package. Copy a video here on device:

```
/var/mobile/Documents/MyVCam/test.mp4
```

That string is `MyVCamManagerTestVideoPathUTF8`. `Tweak.x` hooks `-[AVCaptureSession startRunning]` and `-[AVCaptureSession stopRunning]`.

- `startRunning` calls the original implementation, then, if the session is running, records that a capture session is up. It does not open the file on that thread. The next turn of `com.myvcam.enable` attaches and calls `-[MyVCamManager startWithError:]`. That queue is not the sample-buffer queue and not `startRunning`. A redundant `startRunning` while the session is already recorded does not reset the feed. `stopRunning` stops the feed only when the session actually stops, and not when Camera calls `stopRunning` from inside `startRunning`. A missing file, an unreadable file, a directory, or any other prepare failure returns `NO` with `PrepareFailed`. The timer is not armed and the process does not crash. The log is `[MyVCam C1-C] feed not started path=...` or `feed not started: test video not readable path=... errno=...`. The warmup log is `[MyVCam C1-C] passthrough warmup finished (session up)`.
- The Camera viewfinder is an `AVCaptureVideoPreviewLayer`. It does not call `captureOutput:didOutputSampleBuffer:fromConnection:`, so swapping that delegate cannot change the preview. While the feed is running, an `AVSampleBufferDisplayLayer` is inserted as the next sibling above each preview layer and enqueues an IOSurface-backed copy of `VideoInjector`'s latest frame. A sublayer of the preview stays behind the live image. The log is `[MyVCam C1-C] preview showing imported video`.
- Camera cannot read `/var/mobile/Documents`. `myvcam-mirror` copies `test.mp4` to `/var/jb/var/mobile/Library/MyVCam/test.mp4`, which this process can read. The Documents path is still the file you put on the device. The same helper mirrors the disable file.
- Creating `/var/mobile/Documents/MyVCam/disable` skips the feed and the replacement. The delegate hook stays installed and keeps passing the camera sample through, and the preview overlay is not added. Delete that file and reopen Camera to re-enable. The log is `[MyVCam C1-C] feed not started: disable file ...`.
- `stopRunning` records the stop, calls the original implementation, and stops the manager on `com.myvcam.enable`. It does not call `MediaReader` on the session thread. The log is `[MyVCam C1-C] capture session stopped the feed`.

`startWithError:` prepares the reader, prepares the injector, then resumes a `DISPATCH_SOURCE_TYPE_TIMER` on the serial queue `com.myvcam.feed`. The rate is a fixed 30 fps (`NSEC_PER_SEC / 30`, leeway 1 ms). It does not read the file's nominal frame rate. The first fire is immediate. Each tick calls `injectNextSampleBufferWithError:` on that queue. The capture delegate hook only reads `_latest`. It does not decode and it does not call inject.

End of the video track loops. If a tick reaches the end after at least one frame since the last open, the manager prepares the frame source again from the start of the same file. `VideoInjector` stays armed, so `_latest` remains until the next frame replaces it. The first loop after a start logs `[MyVCam C1-C] end of media, looping`. If the end arrives again before any frame, or a tick fails for another reason, the feed cancels its timer, resets the reader, and stops the injector. A `NotRunning` error on a tick means `stop` already won; the tick returns and does not start another timer.

`stop`, `detachMediaFile`, and `attachMediaFileURL:` cancel the timer and bump a generation counter. An in-flight tick from the old timer cannot rewind the file or install a new timer. Cancelling the dispatch source does not wait for the handler, and nothing syncs onto `com.myvcam.feed` while the manager lock is held.

This stage still does not install the package and does not claim a device result. A live replacement on device requires the file above and a running Camera capture session. Actions only compiles and packages.

GitHub Actions workflow `Compile MyVCam` builds the rootless tweak on `main` and uploads `MyVCam-deb` and `MyVCam-dylib`. That compile does not install the package and does not feed a camera.

## What Phase A and Phase B do

- `MediaReader` opens a local file URL, selects the first video track, and decodes IOSurface-backed `32BGRA` pixel buffers.
- `SampleBufferBuilder` wraps one pixel buffer in a `CMSampleBuffer`.
- `VideoInjector` `prepareWithError:` sets a local prepared flag and returns `YES`. That `YES` is local state. `injectSampleBuffer:error:` returns `NO` with `NotPrepared` before arming, even for `NULL`, and `InvalidSampleBuffer` for `NULL` once armed. A non-NULL buffer once armed is `CFRetain`ed as `_latest` (any previous latest is `CFRelease`d first) and the call returns `YES`. `stop` releases `_latest` and clears the flag. `dealloc` releases `_latest` if it is still set.
- Phase B: `MyVCamManager` prepares the reader, then prepares the injector. `injectNextSampleBufferWithError:` produces one sample buffer, borrows it to the injector, and `CFRelease`s it on both success and failure. A `NO` from the injector stays a failure (`InjectFailed`, with that error underneath). A `YES` means the injector retained the latest buffer. End of media on this path is `EndOfMedia`. `copyNextSampleBufferWithError:` stays a pure producer: end of file is `NULL` and a nil error, and it does not call the injector.
- C1-C: a successful `startWithError:` also arms the 30 fps feed. End of media on that feed reopens the file from the start. `stop`, `detachMediaFile`, and `attachMediaFileURL:` cancel the feed, reset the reader, and stop the injector.
- The tweak Makefile links `AVFoundation` in addition to `Foundation`, `CoreMedia`, and `CoreVideo`. Packaging stays rootless.

## What it does not do

- Decode or call `injectNext` on the capture delegate queue. `com.myvcam.match` reads the shared injector. The delegate hook only swaps a buffer that queue has already published. The viewfinder overlay also reads the injector, on the main queue, and does not decode
- Mutate the original capture `sampleBuffer`. C1-B only swaps in a separate buffer when one is already stored
- mediaserverd hooks, including `BWNodeOutput`
- Photo capture or audio capture hooks. The viewfinder overlay is an `AVSampleBufferDisplayLayer` above `AVCaptureVideoPreviewLayer`; it does not replace photo output
- Report inject success when `VideoInjector` returns `NotImplemented`
- Match the file's nominal frame rate, play audio, or rotate frames. The feed is fixed 30 fps. C1-B copies origin timing and matches origin dimensions and pixel format (`32BGRA`, `420f`, `420v`). It does not alias the camera buffer's attachments
- RTSP, HLS, MJPEG, or Murk `AVAssetStreamAdapter`
- DiCoyServer, Mach XPC, or any other IPC
- Screen mirror
- Anti-detection or runtime protection
- A preferences UI
- A multi-process filter. C1-A matches `com.apple.camera` only

`MyVCamFrameSource` includes `lastError` so end of media (`NULL` and a nil error) is distinct from a failed read. `MyVCamManager` uses that method and does not downcast to `MediaReader`.

## Layering

`MyVCamManager` is the only type that sees more than one stage. Its state lock is the outer lock and is not held across `MediaReader` or other AVFoundation calls. `MediaReader` serializes reader work on `com.myvcam.reader`. `VideoInjector` takes its own lock. Neither calls back into the manager.

- `MediaReader` only reads and only conforms to `MyVCamFrameSource`. It does not import `SampleBufferBuilder` or `VideoInjector`.
- `SampleBufferBuilder` only converts `CVPixelBuffer` to `CMSampleBuffer`.
- `VideoInjector` stores the latest injected buffer and can copy it back out. It does not decode and it does not import `SampleBufferBuilder`. The buffer passed to `injectSampleBuffer:error:` is borrowed; the injector `CFRetain`s its latest copy. `copyLatestSampleBufferMatchingOrigin:` returns a new caller-owned buffer.

The inject path decodes without the state lock, then commits the injector retain while the lock is held. Calling `injectNext` or the frame source while that lock is already held can deadlock. The feed timer is cancelled without waiting for its handler. Do not `dispatch_sync` onto `com.myvcam.feed` while holding the manager lock.

`MyVCamFrame` remains an optional carrier. The reader does not return it. The builder does not accept it.

## How the feed runs

On device, put a video at `/var/mobile/Documents/MyVCam/test.mp4`. Opening Camera calls `startRunning`, which does not start the feed on that thread. The next turn of `com.myvcam.enable` attaches and starts when that file or its `/var/jb` mirror is readable and the disable file is absent. `com.myvcam.match` builds replacements; the capture callback only swaps in a finished buffer. The viewfinder overlay enqueues an IOSurface-backed copy of the injector's latest frame onto an `AVSampleBufferDisplayLayer` that sits immediately above `AVCaptureVideoPreviewLayer`. The manager injects on `com.myvcam.feed` until a real `stopRunning` or a feed error. `copyNextSampleBufferWithError:` is still a one-frame producer and does not call `VideoInjector`. A direct `injectNextSampleBufferWithError:` still pulls one frame; the feed calls that same method and shares its lock.

```objc
MyVCamManager *manager = [MyVCamManager sharedManager];
NSString *path = [NSString stringWithUTF8String:MyVCamManagerTestVideoPathUTF8];
[manager attachMediaFileURL:[NSURL fileURLWithPath:path isDirectory:NO]];
NSError *error = nil;
if ([manager startWithError:&error]) {
    // Timer is armed. Frames land in VideoInjector until stop.
}
[manager stop];
```

`startWithError:` prepares the reader and the injector, then arms the timer. It does not itself decode a frame. A missing file leaves `error` set and does not arm the timer.

## Module map

| Path | Duty now |
| --- | --- |
| `Sources/Media/MediaReader.h` `.m` | Local `AVAssetReader`. `copyNextPixelBuffer` returns a retained `32BGRA` buffer or `NULL`. |
| `Sources/Buffer/SampleBufferBuilder.h` `.m` | `CMVideoFormatDescriptionCreateForImageBuffer` + `CMSampleBufferCreateForImageBuffer`. |
| `Sources/Core/MyVCamManager.h` `.m` | Attach, prepare, and the 30 fps feed. `injectNext` borrows one buffer and releases it. End of file loops. |
| `Sources/Core/MyVCamFrameSource.h` | Protocol. `lastError` distinguishes end of media from failure. |
| `Sources/Core/MyVCamFrame.h` `.m` | Unchanged thin carrier. Unused by the new chain. |
| `Sources/Inject/VideoInjector.h` `.m` | Latest-buffer sink. `prepare` returns `YES`. Armed non-NULL `inject` retains `_latest` and returns `YES`. `copyLatestSampleBufferMatchingOrigin:` returns a caller-owned buffer matched to the origin format, or `NULL`. |
| `MyVCamTweak/Tweak.x` | C1-A delegate hook. C1-B passes a format-matched replacement into the original IMP for video only after `com.myvcam.match` has published one; otherwise the original `sampleBuffer`. C1-C starts the feed on `com.myvcam.enable` after `startRunning` returns, stops it from a real `stopRunning`, and shows the injector's latest frame above `AVCaptureVideoPreviewLayer`. |
| `MyVCamTweak/MyVCamTweak.plist` | `com.apple.camera` only. |

## APIs

| API | Result |
| --- | --- |
| `-[MyVCamManager attachMediaFileURL:]` | Stores the URL and a `MediaReader`. Does not open the file. Cancels the feed and stops the injector. |
| `-[MyVCamManager startWithError:]` | Prepares the reader, then the injector, then arms the 30 fps feed. `NO` with `NoMedia` or `PrepareFailed` on failure, including a missing file. Failure cancels any feed. |
| `-[MyVCamManager copyNextSampleBufferWithError:]` | One pixel buffer, then one sample buffer. Does not inject. End of file is `NULL` and a nil error. |
| `-[MyVCamManager injectNextSampleBufferWithError:]` | Same producer, then `injectSampleBuffer:error:`, then one `CFRelease`. `YES` only if inject returns `YES`. End of file is `EndOfMedia` (5). Injector refusal is `InjectFailed` (6) with `NSUnderlyingErrorKey`. |
| `-[MyVCamManager stop]` / `detachMediaFile` | Cancel the feed timer, reset the reader, and stop the injector. |
| `-[MediaReader prepareWithError:]` | Opens the first video track. |
| `-[MediaReader copyNextPixelBuffer]` | Retained pixel buffer, or `NULL` at end or on failure. |
| `-[MediaReader presentationTimeOfLastFrame]` / `durationOfLastFrame` | Times of the last returned frame, else `kCMTimeInvalid`. |
| `-[SampleBufferBuilder sampleBufferWithPixelBuffer:presentationTime:duration:error:]` | Retained image sample buffer, or `NULL` plus an error. |
| `-[VideoInjector prepareWithError:]` | `YES`. Local prepared flag only. |
| `-[VideoInjector injectSampleBuffer:error:]` | `NO` with `NotPrepared` or `InvalidSampleBuffer`. Armed and non-`NULL` retains `_latest` and returns `YES`. |
| `-[VideoInjector copyLatestSampleBuffer]` | Caller-owned retain of the stored latest sample buffer, or `NULL`. `CFRelease` the result. Does not convert or restamp. The preview overlay calls this. |
| `-[VideoInjector copyLatestSampleBufferMatchingOrigin:]` | Caller-owned image sample buffer timed like `origin` and matched to its pixel format and size, or `NULL`. `CFRelease` the result. Does not mutate `origin` or `_latest`. Non-video origin is `NULL`. Copies the origin camera intrinsic matrix when it is a `CFData`. The capture callback does not call this; `com.myvcam.match` does. A miss logs the origin FourCC once. |
| `-[VideoInjector stop]` | Releases `_latest` and clears the prepared flag. |

End of file on `copyNextSampleBufferWithError:` is `NULL` with a nil error. The same end on `injectNextSampleBufferWithError:` is `NO` with `MyVCamManagerErrorCodeEndOfMedia`. A reader failure returns the frame source's `lastError`. `-[MediaReader copyNextPixelBuffer]` before `prepareWithError:` returns `NULL` with `MyVCamMediaReaderErrorCodeNotPrepared`, which is not end of file.

## Third-party references

Ideas were adapted from public sources. This repository does not vendor those trees and does not claim compatibility with them.

| Module | Reference used | Left out |
| --- | --- | --- |
| `MediaReader` | DiCoy local `AVAssetReader` / first video track / BGRA output | Audio reader, wall-clock loop, rotation, hooks |
| `SampleBufferBuilder` | DiCoy `buildSampleBufferMatchingBuffer` image-buffer create; Murk `_create_buffer` naming only | Origin camera buffer, EXIF/TIFF copy, format conversion, network adapters |
| `MyVCamManager` | DiCoy `DiCoyTweakManager` as the object that owns the reader. C1-C also owns the 30 fps feed timer | Screen mirror, daemon, IPC, and hook-based inject inside the manager |
| `VideoInjector` | Latest retained sample buffer, plus a read that restamps it onto the origin timing. The manager calls prepare, inject, and stop. The C1-B hook only reads. The C1-C feed calls inject through the manager | Ethan mediaserverd / `BWNodeOutput`. The injector still does not import the reader |

Detail is in [Docs/THIRD_PARTY_MAP.md](Docs/THIRD_PARTY_MAP.md).

## Filter

`MyVCamTweak.plist` matches `com.apple.camera` only. C1-A, C1-B, and C1-C do not add a second bundle and do not name a media server.

## Build locally

Requires Theos and an iOS SDK new enough for `iphone:clang:latest:15.0`. The Makefiles export `THEOS_PACKAGE_SCHEME=rootless`. `control` is `Architecture: iphoneos-arm64`, package version `0.2.7`.

```sh
export THEOS=$HOME/theos
make package
```

The tweak is built `arm64` only. iPhone 12 is arm64e, and the Linux toolchain's arm64e slice uses a pointer-auth ABI that does not match iOS 15. Shipping that slice makes dyld load it and abort Camera at the first call. ElleKit on Dopamine loads the arm64 slice into the arm64e Camera process. There is no device install in this tree.

Why 0.2.4 still force-quit Camera on first open, and what 0.2.5 changes, is in [Docs/LAUNCH_CRASH_0.2.5.md](Docs/LAUNCH_CRASH_0.2.5.md). Why 0.2.5 can leave the viewfinder on the live camera, and what 0.2.6 changes, is in [Docs/PREVIEW_PASSTHROUGH_0.2.6.md](Docs/PREVIEW_PASSTHROUGH_0.2.6.md). Why 0.2.6 can still leave that viewfinder on the live camera when `test.mp4` is on disk, and what 0.2.7 changes, is in [Docs/PREVIEW_FEED_0.2.7.md](Docs/PREVIEW_FEED_0.2.7.md).
