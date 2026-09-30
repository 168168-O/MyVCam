# Third-party map (reference only)

Stage 2.2 adapts two local-file ideas. It does not vendor, merge, or claim compatibility with the projects below. None of their source trees are in this repository.

Do not treat this file as a merge log.

## What Stage 2.2 took, as an idea

| MyVCam module | Reference | Idea used | Not taken |
| --- | --- | --- | --- |
| `MediaReader` | [W9720/DiCoy](https://github.com/W9720/DiCoy) `DiCoyTweak` `_setupVideoReaderForPath:` | Local `AVURLAsset`, first video track, `AVAssetReaderTrackOutput`, `32BGRA` | Audio reader, looping clock, rotation, `alwaysCopiesSampleData = NO`, hooks |
| `SampleBufferBuilder` | DiCoy `buildSampleBufferMatchingBuffer` | `CMVideoFormatDescriptionCreateForImageBuffer` then `CMSampleBufferCreateForImageBuffer` | Origin camera buffer, timing copied from a capture sample, EXIF/TIFF, IOSurface screen-mirror path, pixel-format conversion |
| `SampleBufferBuilder` | [MurkAskA01/ios-vcam](https://github.com/MurkAskA01/ios-vcam) `_create_buffer` | Same conversion shape: pixel buffer plus a `CMSampleTimingInfo` | `AVAssetStreamAdapter`, HLS, MJPEG, RTSP, and the rest of that network path. The function was not ported |
| `MyVCamManager` | DiCoy `DiCoyTweakManager` | One object owns the reader and asks for the next frame | Daemon client, screen mirror, preview cache, audio |
| `VideoInjector` | DiCoy AVFoundation hooks, later | Not implemented in Stage 2.2 | No hooks and no swizzles |
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
- AVFoundation capture hooks (reserved for a later injector stage)

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
  → VideoInjector          (stub; not called)
```

- `MediaReader` implements `MyVCamFrameSource` and must not depend on `SampleBufferBuilder` or `VideoInjector`.
- `SampleBufferBuilder` only converts `CVPixelBuffer` to `CMSampleBuffer`.
- `VideoInjector` only injects.
- Do not collapse these types into one class to match a third-party file.
