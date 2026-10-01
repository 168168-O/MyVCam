# Live preview after 0.2.10

Device report: iPhone 12, iOS 15.3.1, Dopamine rootless. MyVCam 0.2.10 is installed. The Documents to jb Library copy is still the path that worked before. Camera stays up and Photo mode still shows the live preview, not `test.mp4`. No new device log was attached. This is from the 0.2.10 control flow.

0.2.11 keeps the same chain: `MyVCamManager` → `MediaReader` → `SampleBufferBuilder` → `VideoInjector`, and the C1 delegate hook. The filter is still `com.apple.camera` only. The tweak dylib and `myvcam-mirror` stay arm64 only. Step logs use `[MyVCam 0.2.11]`.

## Root cause

Photo mode does not draw the viewfinder through `captureOutput:didOutputSampleBuffer:fromConnection:`. The visible image is an `AVCaptureVideoPreviewLayer` that `CAMVideoPreviewView` keeps as a sublayer of `previewLayerView`. Layout calls `addSublayer:`, which moves that layer to the front of `previewLayerView`.

0.2.10 inserted the sample-buffer cover as the next sibling of `previewLayerView` and set that host's alpha to 0. That is still the wrong slot, for two reasons that stack:

1. The shutter and the top bar are not siblings of `previewLayerView`. They share a higher superview with the whole preview branch. Those chrome views are what actually paint over the camera. A cover inside the preview branch stays under the preview's video context. That context is not a normal sublayer: ancestor alpha and the preview layer's opacity do not keep it hidden, which is why 0.2.10 could attach a cover and still show the live camera.
2. The cover was not retained except by its superview, and `willMoveToSuperview:` treated removal as teardown. It cleared the cover and restored the live layer. Photo mode drops subviews it does not own, so a cover that lost that fight put the camera back. After 30 failed enqueues the same restore ran again. A display sample was also built only by copying CPU bytes. `MediaReader` already requests an IOSurface, and a buffer with no CPU base address never became a sample the cover could enqueue. The cover then had nothing to show even when it stayed up.

The delegate hook is not this break. The viewfinder never calls it.

## What 0.2.11 changes

The cover is inserted in the superview that also holds the chrome, immediately above the preview branch, which is the same slot the shutter uses to paint over the camera. Full-screen siblings and small reticles are not treated as chrome, so the climb does not stop on `previewLayerView`. It never inserts above the window's root view.

While that cover is on screen, the preview layer is forced hidden, its opacity stays 0, and its connection stays disabled. `setHidden:`, `setOpacity:`, and `layoutSublayers` keep Camera from turning the live layer back on after layout. Host alpha is still cleared on the immediate preview host. The photo output is a different connection.

The cover is retained in a set the preview layer does not own. Removal from a superview no longer restores the live image. The next tick puts the cover back. An enqueue failure flushes the display layer and leaves the cover up.

When the injector's latest pixel buffer is already an IOSurface, that buffer is wrapped into the display sample. A CPU copy is only the fallback. `DisplayImmediately` is unchanged.

Copy, mirror, `test.mp4` paths, and the reader → pixel buffer → sample buffer → injector chain are unchanged.

These lines are the runtime order. The first one that is missing, or that says `0` / `failed`, is the break:

1. `init runs=1` — the tweak constructor ran inside Camera.
2. `MediaReader open path=… exists=… asset_create=… reader_create=… reader_status=…` — the path that was opened.
3. `first frame success=… pixelbuffer=…` — the first decode.
4. `feed timer started yes=…` and `timer ticks feed=1` — the manager timer produced a frame.
5. `VideoInjector CMSampleBuffer yes=…`
6. `host found class=… host_layer=… above=… container=… in_window=…` — the preview host, the view the cover was placed above, and the chrome superview. `above` should not be `previewLayerView` when a bar or dial is on screen.
7. `cover attach container=… above=… host=… frame=… in_window=… live_hidden=…` — `in_window=1` means the cover stayed in the hierarchy.
8. `timer ticks preview=… live=… layers=… latest=…` — the preview timer, and whether `VideoInjector` had a buffer.
9. `first frame to cover success=… reason=… width=… height=… status=…` — `success=1` and `reason=enqueued` means a sample reached the cover. `reason=latest` means the injector had no buffer. `reason=not_ready` / `enqueue` means the display layer did not accept it.

`[MyVCam C1-C] preview overlay attached` and `preview showing imported video` stay. `hook hit` is still only after a capture delegate runs. The viewfinder does not run it.

The arm64-only link is unchanged. There is no device install in this change.
