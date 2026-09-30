# MyVCam

Phase B wires the local-file chain to `VideoInjector`. The injector keeps the latest retained sample buffer. It still does not deliver that buffer to a camera or to mediaserverd.

```
MyVCamManager
  → MediaReader (local file, AVAssetReader)
      → CVPixelBuffer
  → SampleBufferBuilder
      → CMSampleBuffer
  → VideoInjector
      → latest retained buffer, no hooks
```

## C1-A — hook verify only

`Tweak.x` hooks `-[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]`. When a delegate is set, it installs a one-time hook on the class that implements `-captureOutput:didOutputSampleBuffer:fromConnection:`. That hook logs once per delegate class and calls the original implementation with the same `sampleBuffer`. It does not replace, copy, or mutate the buffer. It does not call `VideoInjector` or `MyVCamManager`.

`MyVCamTweak.plist` matches `com.apple.camera` only. This stage does not install the package and does not claim a device result. On a device, the hook fired when the log contains:

```
[MyVCam C1-A] captureOutput:didOutputSampleBuffer:fromConnection: fired class=<DelegateClass>
```

The install log is `[MyVCam C1-A] hooked captureOutput:didOutputSampleBuffer:fromConnection: on <Class>`. The `fired` line is the pass-through confirmation.

`copyNextSampleBufferWithError:` stops at the sample buffer. `injectNextSampleBufferWithError:` borrows that buffer to `VideoInjector` and `CFRelease`s the original. Once armed, `injectSampleBuffer:error:` returns `YES` for a non-NULL buffer and `CFRetain`s it as the latest buffer. `NotPrepared` and `InvalidSampleBuffer` stay failures.

GitHub Actions workflow `Compile MyVCam` builds the rootless tweak on `main` and uploads `MyVCam-deb` and `MyVCam-dylib`. That compile does not install the package and does not feed a camera.

## What Phase A and Phase B do

- `MediaReader` opens a local file URL, selects the first video track, and decodes `32BGRA` pixel buffers.
- `SampleBufferBuilder` wraps one pixel buffer in a `CMSampleBuffer`.
- `VideoInjector` `prepareWithError:` sets a local prepared flag and returns `YES`. That `YES` is local state. `injectSampleBuffer:error:` returns `NO` with `NotPrepared` before arming, even for `NULL`, and `InvalidSampleBuffer` for `NULL` once armed. A non-NULL buffer once armed is `CFRetain`ed as `_latest` (any previous latest is `CFRelease`d first) and the call returns `YES`. `stop` releases `_latest` and clears the flag. `dealloc` releases `_latest` if it is still set.
- Phase B: `MyVCamManager` prepares the reader, then prepares the injector. `injectNextSampleBufferWithError:` produces one sample buffer, borrows it to the injector, and `CFRelease`s it on both success and failure. A `NO` from the injector stays a failure (`InjectFailed`, with that error underneath). A `YES` means the injector retained the latest buffer. End of media on this path is `EndOfMedia`. `copyNextSampleBufferWithError:` stays a pure producer: end of file is `NULL` and a nil error, and it does not call the injector.
- `stop`, `detachMediaFile`, and `attachMediaFileURL:` reset the reader and stop the injector.
- The tweak Makefile links `AVFoundation` in addition to `Foundation`, `CoreMedia`, and `CoreVideo`. Packaging stays rootless.

## What it does not do

- Deliver a buffer to a camera, a capture session, or mediaserverd
- Replace, copy, or mutate the capture `sampleBuffer` in the C1-A delegate hook
- Call `VideoInjector` or drive `MyVCamManager` from the tweak
- mediaserverd hooks, including `BWNodeOutput`
- Photo, preview, or audio capture hooks
- Report inject success when `VideoInjector` returns `NotImplemented`
- Loop playback, audio, rotation, or an origin camera buffer
- RTSP, HLS, MJPEG, or Murk `AVAssetStreamAdapter`
- DiCoyServer, Mach XPC, or any other IPC
- Screen mirror
- Anti-detection or runtime protection
- A preferences UI
- A multi-process filter. C1-A matches `com.apple.camera` only

`MyVCamFrameSource` includes `lastError` so end of media (`NULL` and a nil error) is distinct from a failed read. `MyVCamManager` uses that method and does not downcast to `MediaReader`.

## Layering

`MyVCamManager` is the only type that sees more than one stage. Its state lock is the outer lock. `MediaReader` and `VideoInjector` take their own locks and do not call back into the manager.

- `MediaReader` only reads and only conforms to `MyVCamFrameSource`. It does not import `SampleBufferBuilder` or `VideoInjector`.
- `SampleBufferBuilder` only converts `CVPixelBuffer` to `CMSampleBuffer`.
- `VideoInjector` only injects. It does not decode and it does not build sample buffers. The buffer passed to `injectSampleBuffer:error:` is borrowed; the injector `CFRetain`s its latest copy.

The manager produces a sample buffer on the inject path through `copyNextSampleBufferLockedWithError:`. That method assumes the state lock is already held. Calling the public copy method under that lock would deadlock.

`MyVCamFrame` remains an optional carrier. The reader does not return it. The builder does not accept it.

## How to pull frames

`Tweak.x` does not construct `MyVCamManager` and does not open a file. A later caller drives the chain:

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
    // YES when the injector retains the latest buffer.
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
| `Sources/Inject/VideoInjector.h` `.m` | Latest-buffer sink. `prepare` returns `YES`. Armed non-NULL `inject` retains `_latest` and returns `YES`. |
| `MyVCamTweak/Tweak.x` | C1-A pass-through hook. Logs once per delegate class, then calls the original with the original `sampleBuffer`. |
| `MyVCamTweak/MyVCamTweak.plist` | `com.apple.camera` only. |

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
| `-[VideoInjector injectSampleBuffer:error:]` | `NO` with `NotPrepared` or `InvalidSampleBuffer`. Armed and non-`NULL` retains `_latest` and returns `YES`. |
| `-[VideoInjector stop]` | Releases `_latest` and clears the prepared flag. |

End of file on `copyNextSampleBufferWithError:` is `NULL` with a nil error. The same end on `injectNextSampleBufferWithError:` is `NO` with `MyVCamManagerErrorCodeEndOfMedia`. A reader failure returns the frame source's `lastError`. `-[MediaReader copyNextPixelBuffer]` before `prepareWithError:` returns `NULL` with `MyVCamMediaReaderErrorCodeNotPrepared`, which is not end of file.

## Third-party references

Ideas were adapted from public sources. This repository does not vendor those trees and does not claim compatibility with them.

| Module | Reference used | Left out |
| --- | --- | --- |
| `MediaReader` | DiCoy local `AVAssetReader` / first video track / BGRA output | Audio reader, wall-clock loop, rotation, hooks |
| `SampleBufferBuilder` | DiCoy `buildSampleBufferMatchingBuffer` image-buffer create; Murk `_create_buffer` naming only | Origin camera buffer, EXIF/TIFF copy, format conversion, network adapters |
| `MyVCamManager` | DiCoy `DiCoyTweakManager` as the object that owns the reader | Screen mirror, daemon, IPC, and any hook-based inject |
| `VideoInjector` | Latest retained sample buffer. The manager calls prepare, inject, and stop | DiCoy AVFoundation hooks; Ethan mediaserverd / `BWNodeOutput` |

Detail is in [Docs/THIRD_PARTY_MAP.md](Docs/THIRD_PARTY_MAP.md).

## Filter

`MyVCamTweak.plist` matches `com.apple.camera` only. C1-A does not add a second bundle and does not name a media server.

## Build locally

Requires Theos and an iOS SDK new enough for `iphone:clang:latest:15.0`. Both Makefiles export `THEOS_PACKAGE_SCHEME=rootless`. `control` is `Architecture: iphoneos-arm64`, package version `0.2.3`.

```sh
export THEOS=$HOME/theos
make package
```

The Linux toolchain used by Actions warns that the `arm64e` objects were built with an incompatible arm64e ABI. The link still produces a merged dylib. Confirm that slice on a device before relying on it. There is no device install in this tree.
