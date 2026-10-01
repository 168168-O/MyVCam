# Live preview after 0.2.7

Device report: iPhone 12, iOS 15.3.1, Dopamine rootless. MyVCam 0.2.7 was installed with Sileo. A real file is at `/var/mobile/Documents/MyVCam/test.mp4`. Camera stays up and the viewfinder is still the live camera. No new device run was used.

Confirmed from earlier builds, not from a new theory:

1. 0.2.5 waited for a camera callback before starting the feed. The preview path does not hit that callback, so the feed never started.
2. 0.2.6 started earlier, and Camera's sandbox cannot read `/var/mobile/Documents/.../test.mp4`.
3. 0.2.7 copies to `/var/jb/var/mobile/Library/MyVCam/test.mp4` and adds a preview overlay.
4. A device with 0.2.7 still shows the live camera.
5. 0.2.8 does not replace `MediaReader`, `SampleBufferBuilder`, or `VideoInjector`. It records whether the 0.2.7 copy and overlay actually run.

The chain stays `MyVCamManager` → `MediaReader` → `SampleBufferBuilder` → `VideoInjector`, plus the C1 delegate hook. The filter is still `com.apple.camera` only. The tweak dylib and `myvcam-mirror` stay arm64 only.

## What the device log must show

Lines use the prefix `[MyVCam 0.2.8]`.

- Helper (`syslog`, user `myvcam-mirror`) and Camera (`NSLog`): source path, dest path, source exists, dest exists, dest size, copy success, copy error domain `NSPOSIXErrorDomain` and code.
- `MediaReader open success=` with the URL that was opened, then `first frame read ok=`.
- `feed timer started` and `injected frames/sec=`.
- `VideoInjector got CMSampleBuffer` after the injector retains a buffer.
- `hook hit` the first time the capture delegate runs, and `hook hit replaced=1` only when that sample was swapped.
- `overlay create ok=` with the view and layer the overlay was added to, plus `in_window` and `hierarchy`.

If the jb file exists and the viewfinder is still live, those lines say whether the reader opened, the timer ran, the injector stored a buffer, the hook ran, and the sample was replaced. They do not add another path guess.

## What 0.2.8 changes

- Logs with prefix `[MyVCam 0.2.8]` for the copy, the reader URL, the first frame, the feed timer, injected frames per second, the injector retain, hook hit and replace, and overlay create plus window hierarchy. Existing `[MyVCam C1-A]`, `[MyVCam C1-B]`, and `[MyVCam C1-C]` lines stay.
- The readable test is `open()` plus `fstat` of a non-empty regular file. Candidates are Camera's library `MyVCam/test.mp4`, the realpath of `/var/jb` plus `/var/mobile/Library/MyVCam/test.mp4`, the `/var/jb` and `/private/var/jb` spellings, the container path recorded in `mirror.status`, then Documents. The disable marker uses the same paths and counts an empty file. `EPERM` is not a disable marker.
- `com.myvcam.enable` keeps waiting while that capture session is current. A prepare failure is retried for a few seconds. A preview layer whose session is already running arms the same enable if `startRunning` was missed. The scan timer stays up for the life of Camera.
- `myvcam-mirror` stays arm64 and is not injected. Launchd runs it as root with `--watch` and `KeepAlive`. `postinst` runs one shot, records launchctl's exit status, then bootstraps the job. Each pass copies a regular `test.mp4` into the jb mirror and into the `com.apple.camera` data container, mode `0644`, owned like `/var/mobile`. `mirror.status` in both places records `euid`, `uid`, byte count, mode, and errno. `EPERM` on Documents does not delete a destination. The tweak logs `mirror status ...`.
- The display layer is a non-interactive view (`layerClass` is `AVSampleBufferDisplayLayer`) inserted at index 0 of the preview host. It covers the live image and stays under later chrome. When the preview is only a sublayer, its opacity is set to 0 while that view is in a window, and restored when the overlay is removed. The view is attached as soon as the feed is live, including before the first decoded frame.

The arm64-only link is unchanged. There is no device install in this change.
