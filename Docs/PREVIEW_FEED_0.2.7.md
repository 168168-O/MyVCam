# Live preview after 0.2.6

Device report: iPhone 12, iOS 15.3.1, Dopamine rootless, ElleKit. MyVCam 0.2.6 (`eb8e00c3729b5ac7530a0780e30b135c4ab302b7`) loads. Camera no longer force-quits. A real file is at `/var/mobile/Documents/MyVCam/test.mp4`. The viewfinder still shows the live camera. No new device run was used. This is from the 0.2.6 control flow and from Dopamine's process check-in.

0.2.7 keeps the same chain: `MyVCamManager` → `MediaReader` → `SampleBufferBuilder` → `VideoInjector`, and the C1 delegate hook. The filter is still `com.apple.camera` only. The tweak dylib and `myvcam-mirror` stay arm64 only.

## Root cause

### 1. Camera cannot read the Documents path, so the feed never starts

`MyVCamC1C_ReadableVideoPath` accepts the file only when `access(..., R_OK)` succeeds inside `com.apple.camera`. Dopamine's check-in (`systemwide_process_checkin`) issues a read extension for `/var/jb` and a read-write extension for `/var/jb/var/mobile`. It does not issue one for `/var/mobile/Documents`. Camera's own sandbox does not allow that directory either.

`access` then returns `EPERM`. 0.2.6 treats that as "not readable", returns before `attachMediaFileURL:` / `startWithError:`, and never calls `MyVCamPreview_Start`. The viewfinder timer does not run. The live preview stays. Filza can see the file because Filza is not in Camera's sandbox. A directory named `test.mp4` was an earlier failure; a real file at that path still fails this check.

The disable file at the same Documents directory is invisible for the same reason. `access(..., F_OK)` is `EPERM` there too.

### 2. The display layer was a sublayer of the preview

`AVCaptureVideoPreviewLayer` composites the capture preview above its own sublayers. `zPosition` only orders those sublayers against each other. Camera's focus UI is not a sublayer of the preview layer: `CAMVideoPreviewView` hosts the layer, and the indicators are separate views. 0.2.6 did `[preview addSublayer:overlay]`, so a running feed would still leave the live image on top.

A failed `enqueueSampleBuffer:` then removed that layer. `AVSampleBufferDisplayLayer` rejects a pixel buffer that is not IOSurface-backed, and the reader buffer is not promised to be one. The layer also had a control timebase parked at zero, so a later sample whose presentation time had moved on was late. After eight failures the tick stopped trying. The live preview was uncovered again.

## What 0.2.7 changes

- `myvcam-mirror` runs as root, outside Camera. It copies a regular file at `/var/mobile/Documents/MyVCam/test.mp4` to `/var/jb/var/mobile/Library/MyVCam/test.mp4` and mirrors the disable file the same way. `postinst` runs it once and bootstraps the launch daemon; the daemon also watches those two paths.
- The tweak still tries the Documents path and the `/private/var/...` spelling first. If those are denied, it opens the mirror. Both unreadable, or a disable marker on either path, still leaves the feed off.
- The display layer is inserted as the next sibling above the preview, with the preview's frame and zPosition, so it covers the viewfinder and stays under chrome that is already above the preview. `init` / `setSession` with no connection are tracked, and the window walk includes `UIApplication.windows` as well as window scenes.
- Each enqueued sample is a new IOSurface-backed 32BGRA buffer, marked display-immediately, with no control timebase. A failed enqueue flushes and leaves the layer in place.

The arm64-only link is unchanged. There is no device install in this change.
