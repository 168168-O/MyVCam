# Third-party map (reference only)

Stage 2.2 adapts two local-file ideas. It does not vendor, merge, or claim compatibility with the projects below. None of their source trees are in this repository.

Do not treat this file as a merge log.

## What Stage 2.2 took, as an idea

| MyVCam module | Reference | Idea used | Not taken |
| --- | --- | --- | --- |
| `MediaReader` | [W9720/DiCoy](https://github.com/W9720/DiCoy) `DiCoyTweak` `_setupVideoReaderForPath:` | Local `AVURLAsset`, first video track, `AVAssetReaderTrackOutput`, `32BGRA` | Audio reader, looping clock, rotation, `alwaysCopiesSampleData = NO`, hooks |
| `SampleBufferBuilder` | DiCoy `buildSampleBufferMatchingBuffer` | `CMVideoFormatDescriptionCreateForImageBuffer` then `CMSampleBufferCreateForImageBuffer` | Origin camera buffer, timing copied from a capture sample, EXIF/TIFF, IOSurface screen-mirror path, pixel-format conversion |
| `SampleBufferBuilder` | [MurkAskA01/ios-vcam](https://github.com/MurkAskA01/ios-vcam) `_create_buffer` | Same conversion shape: pixel buffer plus a `CMSampleTimingInfo` | `AVAssetStreamAdapter`, HLS, MJPEG, RTSP, and the rest of that network path. The function was not ported |
| `MyVCamManager` | DiCoy `DiCoyTweakManager` | One object owns the reader and asks for the next frame. Phase B also calls the local injector. C1-C schedules that call on `com.myvcam.feed` | Daemon client, screen mirror, preview cache, audio, hook-based inject inside the manager |
| `VideoInjector` | DiCoy AVFoundation hooks, later | Armed non-NULL `injectSampleBuffer:error:` `CFRetain`s the latest buffer and returns `YES`. `stop` releases it. `copyLatestSampleBufferMatchingOrigin:` returns a new caller-owned buffer timed like the origin sample | Swizzles inside this class, and delivery into mediaserverd. The feed loop lives on `MyVCamManager`, not here |
| (none) | [EthanArbuckle/vcam-ios](https://github.com/EthanArbuckle/vcam-ios) | Deferred | `BWNodeOutput` and mediaserverd injection are not a MyVCam interface |

`MediaReader` returns a `CVPixelBuffer`. DiCoy's reader path returns a `CMSampleBuffer` from the same manager that also injects. Those steps stay split here.

`alwaysCopiesSampleData` is `YES` in `MediaReader` so the retained pixel buffer remains valid after the reader sample buffer is released. DiCoy uses `NO` because it rewraps the buffer before the next read.

## Per project

### W9720/DiCoy

Repository: https://github.com/W9720/DiCoy

Inspected for Stage 2.2: `DiCoyTweak/Tweak.x` local media-inject reader and the image-buffer half of `buildSampleBufferMatchingBuffer`.

Still out of MyVCam:

- DiCoyServer / IPC / Mach XPC
- Screen mirror and the daemon IOSurface path
- Preferences UI
- Preferences, audio, and screen mirror. C1-A installs the Camera delegate hook. C1-B reads `VideoInjector` from that hook. C1-C's tweak hooks `AVCaptureSession` start/stop and calls the manager; the manager owns the feed timer. The injector class still has no swizzle. Phase A arms a local flag and Phase B calls that injector from `MyVCamManager`

### MurkAskA01/ios-vcam

Repository: https://github.com/MurkAskA01/ios-vcam

`_create_buffer` is a naming reference for the pixel-buffer to sample-buffer step only. No network reader was brought over.

### EthanArbuckle/vcam-ios

Repository: https://github.com/EthanArbuckle/vcam-ios

Listed so the mediaserverd / `BWNodeOutput` path stays deferred. C1-A and C1-B filter `com.apple.camera` only and do not name `mediaserverd`.

## C1-A

`Tweak.x` follows the DiCoy / ios-vcam shape: hook `AVCaptureVideoDataOutput`'s `setSampleBufferDelegate:queue:`, then hook the delegate class's `captureOutput:didOutputSampleBuffer:fromConnection:` once. `%orig` runs before that hook is installed, and `MSHookMessageEx` is not called while the tweak lock is held. `%init` runs on the next main-queue turn, not inside the constructor. C1-A logs that the delegate hook fired (`[MyVCam C1-A]`). The filter is `com.apple.camera` only. It does not hook mediaserverd / `BWNodeOutput`. The packaged dylib is arm64 only.

## C1-B

`com.myvcam.match` calls `-[VideoInjector copyLatestSampleBufferMatchingOrigin:]` on the shared manager's injector. The capture callback does not. Until that queue publishes a buffer, the callback calls the original IMP with the camera sample and does not message the injector. A published buffer is restamped and passed to the original IMP only for a video image. Audio uses the same selector and is passed through. The hook keeps the last eight deliveries. NULL from the copy, including an origin format that is not `32BGRA`, `420f`, or `420v`, leaves the camera sample in place. The original buffer is not mutated and is never released. `[MyVCam C1-B]` logs the first replace and the first video pass-through. Compile and package do not prove a live swap. A replacement exists only after `injectSampleBuffer:` has stored a frame and the origin format can be matched. C1-C is that caller.

## C1-C

`MyVCamManager` arms a 30 fps `dispatch_source` timer on `com.myvcam.feed` from `startWithError:`. Each tick calls `injectNextSampleBufferWithError:`. End of the file prepares the reader again from the start. A missing or unreadable `/var/mobile/Documents/MyVCam/test.mp4` fails before the timer is armed. `Tweak.x` does not call attach or start from inside `AVCaptureSession` `startRunning`; `com.myvcam.enable` does that on the next turn after `startRunning` returns. It does not wait for delegate callbacks. `/var/mobile/Documents/MyVCam/disable`, when present, skips that start; deleting the file and reopening Camera re-enables it. A real `stopRunning` sets a flag and stops the manager on `com.myvcam.enable`, not on the session thread. A `stopRunning` nested inside `startRunning` does not. The delegate hook still does not inject. While the feed is running, an `AVSampleBufferDisplayLayer` on `AVCaptureVideoPreviewLayer` enqueues the injector's latest frame, because that preview layer is the Camera viewfinder and does not use the video-data-output delegate. The filter stays `com.apple.camera` only.

## Layering

```
MyVCamManager
  → id<MyVCamFrameSource>  (MediaReader)
      → CVPixelBuffer
  → SampleBufferBuilder
      → CMSampleBuffer
  → VideoInjector          (latest retained buffer; C1-B reads it)
```

- `MediaReader` implements `MyVCamFrameSource` and must not depend on `SampleBufferBuilder` or `VideoInjector`.
- `lastError` on `MyVCamFrameSource` is how the manager tells end of media from a failed read. It does not downcast to `MediaReader`.
- `SampleBufferBuilder` only converts `CVPixelBuffer` to `CMSampleBuffer`.
- `VideoInjector` stores and reads. `prepareWithError:` returns `YES` for a local flag. Armed non-NULL `injectSampleBuffer:error:` retains `_latest` and returns `YES`. `copyLatestSampleBufferMatchingOrigin:` does not import `SampleBufferBuilder`. It builds a new image sample buffer from the stored pixel buffer and the origin timing. The caller `CFRelease`s that result.
- Phase B calls `prepare`, `inject`, and `stop` from `MyVCamManager` only. `copyNextSampleBufferWithError:` does not. The inject path decodes without the manager lock, borrows the buffer to `VideoInjector`, then `CFRelease`s it once. The retain into `_latest` is committed while the manager lock is held. A `NO` from the injector stays `NO` (`InjectFailed`, underlying injector error). End of media on that path is `EndOfMedia`. The public copy path still uses `NULL` and a nil error. `com.myvcam.match` reads the same injector. The capture callback does not call `inject`. C1-C's timer calls `injectNext` on `com.myvcam.feed` and loops by preparing the frame source again. It does not teach `VideoInjector` about the reader. The manager lock is not held across `MediaReader` prepare or `copyNextSampleBuffer`.
- The manager lock is the outer lock. Reader and injector locks are leaves. Do not nest them back into the manager.
- Do not collapse these types into one class to match a third-party file.
