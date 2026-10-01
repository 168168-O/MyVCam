# Third-party map (reference only)

Stage 2.2 adapts two local-file ideas. It does not vendor, merge, or claim compatibility with the projects below. None of their source trees are in this repository.

Do not treat this file as a merge log.

## What Stage 2.2 took, as an idea

| MyVCam module | Reference | Idea used | Not taken |
| --- | --- | --- | --- |
| `MediaReader` | [W9720/DiCoy](https://github.com/W9720/DiCoy) `DiCoyTweak` `_setupVideoReaderForPath:` | Local `AVURLAsset`, first video track, `AVAssetReaderTrackOutput`, `32BGRA` | Audio reader, looping clock, rotation, `alwaysCopiesSampleData = NO`, hooks |
| `SampleBufferBuilder` | DiCoy `buildSampleBufferMatchingBuffer` | `CMVideoFormatDescriptionCreateForImageBuffer` then `CMSampleBufferCreateForImageBuffer` | Origin camera buffer, timing copied from a capture sample, EXIF/TIFF, IOSurface screen-mirror path, pixel-format conversion |
| `SampleBufferBuilder` | [MurkAskA01/ios-vcam](https://github.com/MurkAskA01/ios-vcam) `_create_buffer` | Same conversion shape: pixel buffer plus a `CMSampleTimingInfo` | `AVAssetStreamAdapter`, HLS, MJPEG, RTSP, and the rest of that network path. The function was not ported |
| `MyVCamManager` | DiCoy `DiCoyTweakManager` | One object owns the reader and asks for the next frame. Phase B also calls the local injector | Daemon client, screen mirror, preview cache, audio, hook-based inject |
| `VideoInjector` | DiCoy AVFoundation hooks, later | Armed non-NULL `injectSampleBuffer:error:` `CFRetain`s the latest buffer and returns `YES`. `stop` releases it. `copyLatestSampleBufferMatchingOrigin:` returns a new caller-owned buffer timed like the origin sample | Capture-session feed loop, swizzles inside this class, and delivery into mediaserverd |
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
- A capture-session feed loop. C1-A installs the Camera delegate hook. C1-B reads `VideoInjector` from that hook and passes a replacement only when a frame is already stored. The tweak does not call `inject` or start a session. Phase A arms a local flag and Phase B calls that injector from `MyVCamManager`

### MurkAskA01/ios-vcam

Repository: https://github.com/MurkAskA01/ios-vcam

`_create_buffer` is a naming reference for the pixel-buffer to sample-buffer step only. No network reader was brought over.

### EthanArbuckle/vcam-ios

Repository: https://github.com/EthanArbuckle/vcam-ios

Listed so the mediaserverd / `BWNodeOutput` path stays deferred. C1-A and C1-B filter `com.apple.camera` only and do not name `mediaserverd`.

## C1-A

`Tweak.x` follows the DiCoy / ios-vcam shape: hook `AVCaptureVideoDataOutput`'s `setSampleBufferDelegate:queue:`, then hook the delegate class's `captureOutput:didOutputSampleBuffer:fromConnection:` once. C1-A logs that the delegate hook fired (`[MyVCam C1-A]`). The filter is `com.apple.camera` only. It does not hook mediaserverd / `BWNodeOutput`.

## C1-B

The same delegate hook calls `-[VideoInjector copyLatestSampleBufferMatchingOrigin:]` on the shared manager's injector. Non-NULL: the original IMP receives that caller-owned buffer, then the hook `CFRelease`s it. NULL: the original IMP receives the original `sampleBuffer`. The original buffer is not mutated. `[MyVCam C1-B]` logs the first replace and the first pass-through. Compile and package do not prove a live swap. A replacement exists only after something else has `injectSampleBuffer:`'d a frame. C1-C (the feed loop) is not in this change.

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
- Phase B calls `prepare`, `inject`, and `stop` from `MyVCamManager` only. `copyNextSampleBufferWithError:` does not. The inject path produces through `copyNextSampleBufferLockedWithError:` while the manager lock is held, borrows the buffer, then `CFRelease`s it once. A `NO` from the injector stays `NO` (`InjectFailed`, underlying injector error). End of media on that path is `EndOfMedia`. The public copy path still uses `NULL` and a nil error. The C1-B hook reads the same injector and does not call `inject`.
- The manager lock is the outer lock. Reader and injector locks are leaves. Do not nest them back into the manager.
- Do not collapse these types into one class to match a third-party file.
