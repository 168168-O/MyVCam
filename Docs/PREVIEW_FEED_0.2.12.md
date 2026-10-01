# Live preview after 0.2.11

Device report: iPhone 12, iOS 15.3.1, Dopamine rootless. MyVCam 0.2.11 is installed. `/var/jb/var/mobile/Library/MyVCam/test.mp4` was already confirmed. Camera stays up and Photo mode still shows the live preview, not `test.mp4`. No new device log was attached. This is from the 0.2.11 control flow.

0.2.12 keeps the same chain: `MyVCamManager` → `MediaReader` → `SampleBufferBuilder` → `VideoInjector`, and the C1 delegate hook. The filter is still `com.apple.camera` only. The tweak dylib and `myvcam-mirror` stay arm64 only. Step logs use `[MyVCam 0.2.12]`.

## Root cause

The viewfinder is still `AVCaptureVideoPreviewLayer`. The delegate hook is not this break. Two 0.2.11 choices stack, and either one leaves the live image on screen.

1. Placement stopped too early. `SiblingIsChrome` treated any view that was neither full-bleed nor tiny as the shutter. Photo mode's zoom and lighting controls are that size, and they live inside the preview branch. The climb stopped there, so the cover was inserted under the preview's video context. That context is what the shutter paints over, from the viewfinder, which is the superview of the whole preview branch. A cover that never reaches that superview stays behind the live image. `hidden`, opacity, and the host view's alpha do not change it.
2. The connection disable did not stick. Apple's preview layer stops frames when its connection is disabled, and the photo output uses a different connection. 0.2.11 set `enabled = NO` on the main queue. Camera sets it back to `YES` from the session queue. Nothing hooked `setEnabled:`, and the cover check bailed off the main thread, so the re-enable won. The same layout then calls `addSublayer:` and puts the preview layer above the cover again.

The filter plist is not this break. `com.apple.camera` is the Camera process, and 0.2.5 already proved the dylib loads there. A missing `init runs=1` would be the injection failure. The window walk is not this break either: the preview layer is found, and the cover was attached in the wrong superview.

## What 0.2.12 changes

The cover is inserted in `CAMViewfinderView` when that class is present, immediately above the preview branch. If the class is absent, the same slot is the deepest common ancestor of the preview host and the shutter, bottom bar, mode dial, or top bar. An in-preview control is not that ancestor. The cover is not inserted above the window's root view.

While the cover is up, the preview connection is recorded and `setEnabled:` forces it to stay off, including from the session queue. Photo and audio connections are not in that set. A preview layer that is only a sublayer is removed, and `addSublayer:` / `insertSublayer:` leave it detached when Camera adds it again. A preview that is a view's backing layer is not removed. Host alpha, hidden, and opacity are still applied. The cover stays retained across removal.

`MediaReader` requests a CoreAnimation-compatible IOSurface. The cover wraps that buffer. If `enqueueSampleBuffer:` fails, the next sample is copied into a buffer created for the display layer, including when the source surface has no CPU address until `IOSurfaceLock`.

Copy, mirror, `test.mp4` paths, and the reader → pixel buffer → sample buffer → injector chain are unchanged.

These lines are the runtime order. The first one that is missing, or that says `0` / `failed`, is the break:

1. `init runs=1` — the tweak constructor ran inside Camera.
2. `MediaReader open path=… exists=… asset_create=… reader_create=… reader_status=…`
3. `first frame success=… pixelbuffer=…`
4. `feed timer started yes=…` and `timer ticks feed=1`
5. `VideoInjector CMSampleBuffer yes=…`
6. `host found class=… host_layer=… above=… container=… in_window=… slot=…` — `slot=viewfinder` or `slot=chrome` means the cover's superview is the one that also holds the shutter. `slot=preview` means that control was not in the window yet.
7. `cover attach container=… above=… host=… frame=… in_window=… live_hidden=… slot=…` — `in_window=1` means the cover stayed in the hierarchy. `live_hidden=1` means the preview layer was hidden or had no superlayer.
8. `preview connection blocked` — Camera tried to turn the preview connection back on and it stayed off.
9. `preview detached` — Camera tried to put the preview layer back in the tree and it was left out.
10. `timer ticks preview=… live=… layers=… latest=…`
11. `first frame to cover success=… reason=… width=… height=… status=…` — `success=1` and `reason=enqueued` means a sample reached the cover.

`[MyVCam C1-C] preview overlay attached` and `preview showing imported video` stay. `hook hit` is still only after a capture delegate runs. The viewfinder does not run it.

The arm64-only link is unchanged. There is no device install in this change.
