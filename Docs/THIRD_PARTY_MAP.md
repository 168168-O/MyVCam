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
| `VideoInjector` | DiCoy AVFoundation hooks, later | Phase A sets a local prepared flag. Phase B: `MyVCamManager` calls `prepareWithError:`, `injectSampleBuffer:error:` (borrowed buffer), and `stop`. `injectSampleBuffer:error:` still returns `NotImplemented` once armed | Hooks, swizzles, and a real sink |
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
- AVFoundation capture hooks. Phase A arms a local flag and Phase B calls that injector. The hooks themselves stay out

### MurkAskA01/ios-vcam

Repository: https://github.com/MurkAskA01/ios-vcam

`_create_buffer` is a naming reference for the pixel-buffer to sample-buffer step only. No network reader was brought over.

### EthanArbuckle/vcam-ios

Repository: https://github.com/EthanArbuckle/vcam-ios

Listed so the mediaserverd / `BWNodeOutput` path stays deferred. The placeholder filter still does not name `mediaserverd`.

## Layering

```
MyVCamManager
  → id<MyVCamFrameSource>  (MediaReader)
      → CVPixelBuffer
  → SampleBufferBuilder
      → CMSampleBuffer
  → VideoInjector          (Phase A armed locally; Phase B calls it; no sink)
```

- `MediaReader` implements `MyVCamFrameSource` and must not depend on `SampleBufferBuilder` or `VideoInjector`.
- `lastError` on `MyVCamFrameSource` is how the manager tells end of media from a failed read. It does not downcast to `MediaReader`.
- `SampleBufferBuilder` only converts `CVPixelBuffer` to `CMSampleBuffer`.
- `VideoInjector` only injects. Phase A `prepareWithError:` returns `YES` for a local flag. `injectSampleBuffer:error:` still returns `NO`.
- Phase B calls `VideoInjector` from `MyVCamManager` only. `copyNextSampleBufferWithError:` does not. The inject path produces through `copyNextSampleBufferLockedWithError:` while the manager lock is held, borrows the buffer, then `CFRelease`s it once. A `NO` from the injector stays `NO` (`InjectFailed`, underlying injector error). End of media on that path is `EndOfMedia`. The public copy path still uses `NULL` and a nil error.
- The manager lock is the outer lock. Reader and injector locks are leaves. Do not nest them back into the manager.
- Do not collapse these types into one class to match a third-party file.
