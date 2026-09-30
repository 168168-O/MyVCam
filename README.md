# MyVCam

Stage 2.2 local-file video chain for an independent Theos tweak.

```
MyVCamManager
  → MediaReader (local file, AVAssetReader)
      → CVPixelBuffer
  → SampleBufferBuilder
      → CMSampleBuffer
```

`VideoInjector` is still a stub. Nothing in this stage injects a buffer, installs a hook, or targets a real process.

**未验证.** This tree was not compiled with Theos and was not installed on a device.

## What Stage 2.2 does

- `MediaReader` opens a local file URL, selects the first video track, and decodes `32BGRA` pixel buffers.
- `SampleBufferBuilder` wraps one pixel buffer in a `CMSampleBuffer`.
- `MyVCamManager` attaches the file, prepares the reader, pulls one pixel buffer at a time, and builds a sample buffer.
- The tweak Makefile links `AVFoundation` in addition to `Foundation`, `CoreMedia`, and `CoreVideo`. Packaging stays rootless.

## What it does not do

- Call `VideoInjector` (`prepare` / `inject` / `stop` still fail or no-op)
- AVFoundation or mediaserverd hooks, including `BWNodeOutput`
- Loop playback, audio, rotation, or an origin camera buffer
- RTSP, HLS, MJPEG, or Murk `AVAssetStreamAdapter`
- DiCoyServer, Mach XPC, or any other IPC
- Screen mirror
- Anti-detection or runtime protection
- A preferences UI
- A real Substrate filter

`MyVCamFrameSource` selectors are unchanged.

## Layering

`MyVCamManager` is the only type that sees more than one stage.

- `MediaReader` only reads and only conforms to `MyVCamFrameSource`. It does not import `SampleBufferBuilder` or `VideoInjector`.
- `SampleBufferBuilder` only converts `CVPixelBuffer` to `CMSampleBuffer`.
- `VideoInjector` only injects, and that implementation is still empty.

`MyVCamFrame` remains an optional carrier. The reader does not return it. The builder does not accept it.

## How to pull frames

`Tweak.x` still only constructs `[MyVCamManager sharedManager]`. It does not open a file. A later caller drives the chain:

```objc
MyVCamManager *manager = [MyVCamManager sharedManager];
[manager attachMediaFileURL:[NSURL fileURLWithPath:@"/path/to/clip.mov"]];
NSError *error = nil;
if ([manager startWithError:&error]) {
    CMSampleBufferRef sample = [manager copyNextSampleBufferWithError:&error];
    // NULL and error == nil means the video track ended.
    if (sample != NULL) {
        CFRelease(sample);
    }
}
[manager stop];
```

`startWithError:` prepares the reader and does not decode a frame. `copyNextSampleBufferWithError:` decodes one frame and builds one sample buffer. Neither method calls `VideoInjector`.

## Module map

| Path | Duty now |
| --- | --- |
| `Sources/Media/MediaReader.h` `.m` | Local `AVAssetReader`. `copyNextPixelBuffer` returns a retained `32BGRA` buffer or `NULL`. |
| `Sources/Buffer/SampleBufferBuilder.h` `.m` | `CMVideoFormatDescriptionCreateForImageBuffer` + `CMSampleBufferCreateForImageBuffer`. |
| `Sources/Core/MyVCamManager.h` `.m` | Attach, prepare, pull, build. Does not inject. |
| `Sources/Core/MyVCamFrameSource.h` | Unchanged protocol. |
| `Sources/Core/MyVCamFrame.h` `.m` | Unchanged thin carrier. Unused by the new chain. |
| `Sources/Inject/VideoInjector.h` `.m` | Unchanged stubs. |
| `MyVCamTweak/Tweak.x` | Unchanged `%ctor`. No `%hook`. |
| `MyVCamTweak/MyVCamTweak.plist` | Still `com.myvcam.stage21.placeholder`. |

## APIs

| API | Stage 2.2 result |
| --- | --- |
| `-[MyVCamManager attachMediaFileURL:]` | Stores the URL and a `MediaReader`. Does not open the file. |
| `-[MyVCamManager startWithError:]` | Prepares the reader. `NO` with `NoMedia` or `PrepareFailed` on failure. |
| `-[MyVCamManager copyNextSampleBufferWithError:]` | One pixel buffer, then one sample buffer. Does not inject. |
| `-[MyVCamManager stop]` / `detachMediaFile` | Reset the reader. Do not call `VideoInjector`. |
| `-[MediaReader prepareWithError:]` | Opens the first video track. |
| `-[MediaReader copyNextPixelBuffer]` | Retained pixel buffer, or `NULL` at end or on failure. |
| `-[MediaReader presentationTimeOfLastFrame]` / `durationOfLastFrame` | Times of the last returned frame, else `kCMTimeInvalid`. |
| `-[SampleBufferBuilder sampleBufferWithPixelBuffer:presentationTime:duration:error:]` | Retained image sample buffer, or `NULL` plus an error. |
| `-[VideoInjector prepareWithError:]` / `injectSampleBuffer:error:` | Still `NO`, not implemented. |
| `-[VideoInjector stop]` | Still a no-op. |

End of file is `copyNextSampleBufferWithError:` returning `NULL` with a nil error. A reader failure returns `NULL` with `lastError` attached.

## Third-party references

Ideas were adapted from public sources. This repository does not vendor those trees and does not claim compatibility with them.

| Module | Reference used for Stage 2.2 | Left out |
| --- | --- | --- |
| `MediaReader` | DiCoy local `AVAssetReader` / first video track / BGRA output | Audio reader, wall-clock loop, rotation, hooks |
| `SampleBufferBuilder` | DiCoy `buildSampleBufferMatchingBuffer` image-buffer create; Murk `_create_buffer` naming only | Origin camera buffer, EXIF/TIFF copy, format conversion, network adapters |
| `MyVCamManager` | DiCoy `DiCoyTweakManager` as the object that owns the reader | Screen mirror, daemon, IPC |
| `VideoInjector` | Not implemented | DiCoy AVFoundation hooks; Ethan mediaserverd / `BWNodeOutput` |

Detail is in [Docs/THIRD_PARTY_MAP.md](Docs/THIRD_PARTY_MAP.md).

## Filter

`MyVCamTweak.plist` still matches `com.myvcam.stage21.placeholder` only. Stage 2.2 does not point it at a camera app or at `mediaserverd`.

## Build locally

Requires Theos and an iOS SDK new enough for `iphone:clang:latest:15.0`. Both Makefiles export `THEOS_PACKAGE_SCHEME=rootless`. `control` is `Architecture: iphoneos-arm64`, package version `0.2.2`.

```sh
export THEOS=$HOME/theos
make package
```

Run that from this directory. Those commands were not run here. There is no package log and no device install.
