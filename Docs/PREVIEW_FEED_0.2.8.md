# Live preview after 0.2.7

Device report: iPhone 12, iOS 15.3.1, Dopamine rootless. MyVCam 0.2.7 (`feffc23d536d028eed2c30cd9af2fc9dc323050c`) was installed with Sileo. A real file is at `/var/mobile/Documents/MyVCam/test.mp4`. Camera stays up and the viewfinder is still the live camera. No new device run was used. This is from the 0.2.7 control flow and from Dopamine's `systemwide_process_checkin`.

0.2.8 keeps the same chain: `MyVCamManager` → `MediaReader` → `SampleBufferBuilder` → `VideoInjector`, and the C1 delegate hook. The filter is still `com.apple.camera` only. The tweak dylib and `myvcam-mirror` stay arm64 only. LordVCAM replaces buffers in mediaserverd. This package does not. That path is not this viewfinder.

## Root cause

### 1. The feed still starts only when `access()` succeeds, then it gives up

`MyVCamC1C_ReadableVideoPath` returns a path only when `access(path, R_OK) == 0`. That is the same check 0.2.6 used to reject `/var/mobile/Documents`. Dopamine's check-in does not issue an extension for the string `/var/jb`. `systemwide_process_checkin` issues `com.apple.app-sandbox.read` for `JBROOT_PATH("")` and `com.apple.app-sandbox.read-write` for `JBROOT_PATH("/var/mobile")`, which are the real procursus vnodes. `access()` on the `/var/jb` symlink does not prove those vnodes can be opened, and a denial returns before `attachMediaFileURL:` / `startWithError:` / `MyVCamPreview_Start`.

`-[MediaReader prepareWithError:]` then asks `NSFileManager fileExistsAtPath:`. A sandbox denial there is reported as a missing file, so prepare returns `NO` and the 30 fps timer is not armed.

The enable queue retries that check eight times, half a second apart, and stops. `gCaptureSessionRunning` stays YES, so a later `startRunning` does not schedule enable again. The preview timer is created only after a successful start. The live preview stays for the rest of the session.

### 2. The helper can miss the file, and nothing records that it ran

`myvcam-mirror` is a one-shot from `postinst` plus a launchd job with `WatchPaths`. `postinst` discards launchctl's status. `WatchPaths` does not keep a process running, and launchd drops a watch whose directory was missing when the job loaded. A file that shows up after that is never copied.

The helper does not record its uid, the destination mode, or errno. From Camera, a missing mirror looks the same as a mirror that `access()` cannot see. If `lstat` of Documents fails, including `EPERM` from a sandboxed run, the helper unlinks the destination and deletes a copy a root run already wrote.

### 3. Photo mode never puts the imported frames above the live surface

`AVCaptureVideoPreviewLayer` in Camera is the preview view's backing layer, or a sublayer the app orders with the live surface. 0.2.7 inserts a loose `AVSampleBufferDisplayLayer` as the next sibling, with the preview's zPosition. That is not a subview. A sublayer of the preview is painted under the live image. A loose sibling with the same zPosition still loses to that surface, so an enqueued frame does not change what Photo mode shows.

## What 0.2.8 changes

- The readable test is `open()` plus `fstat` of a non-empty regular file. Candidates are Camera's library `MyVCam/test.mp4`, the realpath of `/var/jb` plus `/var/mobile/Library/MyVCam/test.mp4`, the `/var/jb` and `/private/var/jb` spellings, the container path recorded in `mirror.status`, then Documents. The disable marker uses the same paths and counts an empty file. `EPERM` is not a disable marker.
- `com.myvcam.enable` keeps waiting while that capture session is current. A prepare failure is retried for a few seconds. A preview layer whose session is already running arms the same enable if `startRunning` was missed. The scan timer stays up for the life of Camera.
- `myvcam-mirror` stays arm64 and is not injected. Launchd runs it as root with `--watch` and `KeepAlive`. `postinst` runs one shot, records launchctl's exit status, then bootstraps the job. Each pass copies a regular `test.mp4` into the jb mirror and into the `com.apple.camera` data container, mode `0644`, owned like `/var/mobile`. `mirror.status` in both places records `euid`, `uid`, byte count, mode, and errno. `EPERM` on Documents does not delete a destination. The tweak logs `mirror status ...`.
- The display layer is a non-interactive view (`layerClass` is `AVSampleBufferDisplayLayer`) inserted at index 0 of the preview host. It covers the live image and stays under later chrome. When the preview is only a sublayer, its opacity is set to 0 while that view is in a window, and restored when the overlay is removed. The view is attached as soon as the feed is live, including before the first decoded frame.

The arm64-only link is unchanged. There is no device install in this change.
