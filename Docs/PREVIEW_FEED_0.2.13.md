# Live preview after 0.2.12

Device report: iPhone 12, iOS 15.3.1, Dopamine rootless. MyVCam 0.2.12 is installed. The copy into `/var/jb/var/mobile/Library/MyVCam/test.mp4` was already confirmed. Camera stays up and Photo mode still shows the live preview, not `test.mp4`. No device log was attached. This is from the 0.2.12 control flow.

0.2.13 keeps the same chain: `MyVCamManager` → `MediaReader` → `SampleBufferBuilder` → `VideoInjector`, and the C1 delegate hook. The filter is still `com.apple.camera` only. The tweak dylib and `myvcam-mirror` stay arm64 only. Step logs use `[MyVCam 0.2.13]`.

## Root cause

The viewfinder is still `AVCaptureVideoPreviewLayer`. The delegate hook is not this break. 0.2.12 already inserts the cover in `CAMViewfinderView` above the preview branch, forces `setEnabled:` to stay off, and detaches a preview sublayer. A live picture after that means one of these, and Console was the only way to tell them apart:

1. The cover path never stays up. `gPhase` becomes `Live` only after `startWithError:` succeeds. A prepare failure was retried eight times and then abandoned, leaving the phase at warmup for the rest of the session. Every preview tick then calls `RemoveOverlays`, which puts the live layer back. The viewfinder slot, the connection hook, and the detach never remain in effect.
2. `AVSampleBufferDisplayLayer` does not paint its background until it accepts a frame. 0.2.12 used that layer as the cover's backing layer. A cover that was already in the shutter's slot stayed transparent, so the live image showed through it whenever enqueue had not yet succeeded. An opaque `UIView` in that same slot is what actually covers the camera; the shutter is that kind of view.
3. Placement and enqueue were visible only in Console. A dylib that never ran, a host that was never found, a cover that never entered a window, and a black cover from a rejected sample all look the same on the phone.

The filter plist is not this break. `com.apple.camera` is the Camera process. `runtime.status` missing `ctor=1` after a relaunch is the injection failure.

## What 0.2.13 changes

The cover is an opaque `UIView` (`backgroundColor` black, `opaque` YES). `AVSampleBufferDisplayLayer` is a sublayer of that view, not its backing layer. The view is still inserted in `CAMViewfinderView` when that class is present, immediately above the preview branch. A second opaque view is inserted above the preview host when that superview is different, which is the hole left when the live layer is detached. The display layer's control timebase is parked on the sample's presentation time before each enqueue.

While a cover is up, the preview connection stays disabled, including `setEnabled:` from the session queue. `addSublayer:`, `insertSublayer:`, `replaceSublayer:with:`, and `setSublayers:` leave a non-backing preview layer detached. If the cover slot is not ready yet, the live layer is still detached and disabled. Prepare failures are retried for the life of the capture session.

The constructor writes `/var/jb/var/mobile/Library/MyVCam/runtime.status` before `%init`, and the preview tick refreshes it. The same line is written into Camera's container. `postinst` and `myvcam-mirror` create the jb file mode `0666`, and the mirror copies a newer container file onto the jb path. One line, no spaces inside values:

```
version=0.2.13 ctor=1 init=1 phase=live session=1 feed_errno=0 prepare=0 path=... err=started windows=1 layers=1 host=... above=... container=... slot=viewfinder in_window=1 frame=... live_hidden=1 superlayer=0 conn=0 enqueue=1 reason=enqueued px=WxH host_cover=0 blocks=0 detaches=1 write=jb write_errno=0 hierarchy=...
```

Read it in Filza after opening Camera. The first field that is wrong is the break:

| Field | Means |
| --- | --- |
| file missing | the dylib did not run, or neither Camera nor the mirror could write the directory |
| `ctor=1 init=0` | the constructor ran and `%init` did not finish |
| `phase=warmup` `err=not_readable` | `open()` did not find `test.mp4` |
| `phase=warmup` `err=` a reader message | the file opened and `AVAssetReader` failed; `prepare` is the attempt count |
| `phase=disabled` | a disable file is openable |
| `slot=no_layer` or `layers=0` | no `AVCaptureVideoPreviewLayer` is in a window |
| `in_window=0` | the cover's superview was chosen and the cover is not on screen |
| `enqueue=0 reason=cover` | the host was not in a window yet; `live_hidden` says whether the preview layer was still detached |
| `enqueue=1 reason=enqueued` `in_window=1` | a sample reached a cover that is in a window |

`[MyVCam C1-C] preview overlay attached` and `preview showing imported video` stay. `hook hit` is still only after a capture delegate runs. The viewfinder does not run it.

Copy, mirror, `test.mp4` paths, and the reader → pixel buffer → sample buffer → injector chain are unchanged. The arm64-only link is unchanged. There is no device install in this change.
