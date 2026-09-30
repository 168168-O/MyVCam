# MyVCam

Phase B wires the local-file chain to `VideoInjector`. Phase A only arms that injector in memory. There is still no injection sink, so a borrowed inject still fails.

```
MyVCamManager
  → MediaReader (local file, AVAssetReader)
      → CVPixelBuffer
  → SampleBufferBuilder
      → CMSampleBuffer
  → VideoInjector
      → borrowed buffer, no sink
```

`copyNextSampleBufferWithError:` stops at the sample buffer. `injectNextSampleBufferWithError:` borrows that buffer to `VideoInjector` and `CFRelease`s it. Phase A `injectSampleBuffer:error:` returns `NO` with `NotImplemented` once armed. Phase B keeps that result a failure.

GitHub Actions workflow `Compile MyVCam` builds the rootless tweak on `main` and uploads `MyVCam-deb` and `MyVCam-dylib`. That compile does not install the package and does not feed a camera.

## What Phase A and Phase B do

- `MediaReader` opens a local file URL, selects the first video track, and decodes `32BGRA` pixel buffers.
- `SampleBufferBuilder` wraps one pixel buffer in a `CMSampleBuffer`.
- Phase A: `VideoInjector` `prepareWithError:` sets a local prepared flag and returns `YES`. That `YES` is local state. `injectSampleBuffer:error:` borrows a buffer and returns `NO`: `NotPrepared` before arming, `InvalidSampleBuffer` for `NULL`, `NotImplemented` when armed. `stop` clears the flag.
- Phase B: `MyVCamManager` prepares the reader, then prepares the injector. `injectNextSampleBufferWithError:` produces one sample buffer, borrows it to the injector, and `CFRelease`s it on both success and failure. Injector `NotImplemented` stays a failure (`InjectFailed`, with that error underneath). End of media on this path is `EndOfMedia`. `copyNextSampleBufferWithError:` stays a pure producer: end of file is `NULL` and a nil error, and it does not call the injector.
- `stop`, `detachMediaFile`, and `attachMediaFileURL:` reset the reader and stop the injector.
- The tweak Makefile links `AVFoundation` in addition to `Foundation`, `CoreMedia`, and `CoreVideo`. Packaging stays rootless.

## What it does not do

- Deliver a buffer to a camera, a capture session, or mediaserverd
- AVFoundation or mediaserverd hooks, including `BWNodeOutput`
- Report inject success when `VideoInjector` returns `NotImplemented`
- Loop playback, audio, rotation, or an origin camera buffer
- RTSP, HLS, MJPEG, or Murk `AVAssetStreamAdapter`
- DiCoyServer, Mach XPC, or any other IPC
- Screen mirror
- Anti-detection or runtime protection
- A preferences UI
- A real Substrate filter

`MyVCamFrameSource` includes `lastError` so end of media (`NULL` and a nil error) is distinct from a failed read. `MyVCamManager` uses that method and does not downcast to `MediaReader`.

## Layering

`MyVCamManager` is the only type that sees more than one stage. Its state lock is the outer lock. `MediaReader` and `VideoInjector` take their own locks and do not call back into the manager.

- `MediaReader` only reads and only conforms to `MyVCamFrameSource`. It does not import `SampleBufferBuilder` or `VideoInjector`.
- `SampleBufferBuilder` only converts `CVPixelBuffer` to `CMSampleBuffer`.
- `VideoInjector` only injects. It does not decode and it does not build sample buffers. The buffer passed to `injectSampleBuffer:error:` is borrowed.

The manager produces a sample buffer on the inject path through `copyNextSampleBufferLockedWithError:`. That method assumes the state lock is already held. Calling the public copy method under that lock would deadlock.

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

`startWithError:` prepares the reader and then the injector. It does not decode a frame. `copyNextSampleBufferWithError:` decodes one frame and builds one sample buffer. It does not call `VideoInjector`.

```objc
if ([manager startWithError:&error]) {
    // NO while there is no sink. Code is InjectFailed.
    // NSUnderlyingErrorKey is the injector error (NotImplemented once armed).
    // End of the track is EndOfMedia, not a nil error.
    // The manager CFReleases the buffer it produced.
    [manager injectNextSampleBufferWithError:&error];
}
[manager stop];
```

## Module map

| Path | Duty now |
| --- | --- |
| `Sources/Media/MediaReader.h` `.m` | Local `AVAssetReader`. `copyNextPixelBuffer` returns a retained `32BGRA` buffer or `NULL`. |
| `Sources/Buffer/SampleBufferBuilder.h` `.m` | `CMVideoFormatDescriptionCreateForImageBuffer` + `CMSampleBufferCreateForImageBuffer`. |
| `Sources/Core/MyVCamManager.h` `.m` | Attach, prepare the reader and the injector, pull, and build. `injectNext` borrows one buffer and releases it. |
| `Sources/Core/MyVCamFrameSource.h` | Protocol. `lastError` distinguishes end of media from failure. |
| `Sources/Core/MyVCamFrame.h` `.m` | Unchanged thin carrier. Unused by the new chain. |
| `Sources/Inject/VideoInjector.h` `.m` | Phase A local arm. `prepare` returns `YES`. `inject` still returns `NO`. |
| `MyVCamTweak/Tweak.x` | Unchanged `%ctor`. No `%hook`. |
| `MyVCamTweak/MyVCamTweak.plist` | Still `com.myvcam.stage21.placeholder`. |

## APIs

| API | Result |
| --- | --- |
| `-[MyVCamManager attachMediaFileURL:]` | Stores the URL and a `MediaReader`. Does not open the file. Stops the injector. |
| `-[MyVCamManager startWithError:]` | Prepares the reader, then the injector. `NO` with `NoMedia` or `PrepareFailed` on failure. Reader failure stops the injector. Injector failure resets the reader and stops the injector. |
| `-[MyVCamManager copyNextSampleBufferWithError:]` | One pixel buffer, then one sample buffer. Does not inject. End of file is `NULL` and a nil error. |
| `-[MyVCamManager injectNextSampleBufferWithError:]` | Same producer, then `injectSampleBuffer:error:`, then one `CFRelease`. `YES` only if inject returns `YES`. End of file is `EndOfMedia` (5). Injector refusal is `InjectFailed` (6) with `NSUnderlyingErrorKey`. |
| `-[MyVCamManager stop]` / `detachMediaFile` | Reset the reader and stop the injector. |
| `-[MediaReader prepareWithError:]` | Opens the first video track. |
| `-[MediaReader copyNextPixelBuffer]` | Retained pixel buffer, or `NULL` at end or on failure. |
| `-[MediaReader presentationTimeOfLastFrame]` / `durationOfLastFrame` | Times of the last returned frame, else `kCMTimeInvalid`. |
| `-[SampleBufferBuilder sampleBufferWithPixelBuffer:presentationTime:duration:error:]` | Retained image sample buffer, or `NULL` plus an error. |
| `-[VideoInjector prepareWithError:]` | `YES`. Local prepared flag only. |
| `-[VideoInjector injectSampleBuffer:error:]` | `NO`. Armed and non-`NULL` is `NotImplemented`. |
| `-[VideoInjector stop]` | Clears the prepared flag. |

End of file on `copyNextSampleBufferWithError:` is `NULL` with a nil error. The same end on `injectNextSampleBufferWithError:` is `NO` with `MyVCamManagerErrorCodeEndOfMedia`. A reader failure returns the frame source's `lastError`. `-[MediaReader copyNextPixelBuffer]` before `prepareWithError:` returns `NULL` with `MyVCamMediaReaderErrorCodeNotPrepared`, which is not end of file.

## Third-party references

Ideas were adapted from public sources. This repository does not vendor those trees and does not claim compatibility with them.

| Module | Reference used | Left out |
| --- | --- | --- |
| `MediaReader` | DiCoy local `AVAssetReader` / first video track / BGRA output | Audio reader, wall-clock loop, rotation, hooks |
| `SampleBufferBuilder` | DiCoy `buildSampleBufferMatchingBuffer` image-buffer create; Murk `_create_buffer` naming only | Origin camera buffer, EXIF/TIFF copy, format conversion, network adapters |
| `MyVCamManager` | DiCoy `DiCoyTweakManager` as the object that owns the reader | Screen mirror, daemon, IPC, and any hook-based inject |
| `VideoInjector` | Phase A local arm. Phase B manager calls prepare, a borrowed inject, and stop | DiCoy AVFoundation hooks; Ethan mediaserverd / `BWNodeOutput`; a real sink |

Detail is in [Docs/THIRD_PARTY_MAP.md](Docs/THIRD_PARTY_MAP.md).

## Filter

`MyVCamTweak.plist` still matches `com.myvcam.stage21.placeholder` only. Phase B does not point it at a camera app or at `mediaserverd`.

## Build locally

Requires Theos and an iOS SDK new enough for `iphone:clang:latest:15.0`. Both Makefiles export `THEOS_PACKAGE_SCHEME=rootless`. `control` is `Architecture: iphoneos-arm64`, package version `0.2.3`.

```sh
export THEOS=$HOME/theos
make package
```

The Linux toolchain used by Actions warns that the `arm64e` objects were built with an incompatible arm64e ABI. The link still produces a merged dylib. Confirm that slice on a device before relying on it. There is no device install in this tree.
