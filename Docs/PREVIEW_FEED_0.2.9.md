# Live preview after 0.2.8

Device report: 0.2.8 installed. `mirror.status` records `copied=1 bytes=87195160 dest=/var/jb/var/mobile/Library/MyVCam/test.mp4`. Filza shows that file. Camera stays up and the viewfinder is still the live camera. The mirror copy is not the failure. Paths, the mirror, and the rootless layout are unchanged.

0.2.9 keeps the same chain: `MyVCamManager` → `MediaReader` → `SampleBufferBuilder` → `VideoInjector`, and the C1 delegate hook. The filter is still `com.apple.camera` only. The tweak dylib and `myvcam-mirror` stay arm64 only. Step logs use `[MyVCam 0.2.9]`.

## First break

`CAMPreviewView`'s layer is `AVCaptureVideoPreviewLayer`. 0.2.8 inserted the display view at index 0 of that view. A subview of that view is a sublayer of the preview layer, and the live preview is composited above those sublayers. Frames can be decoded, stored, and enqueued, and Photo mode still shows the camera.

The hook is not this break. `captureOutput:didOutputSampleBuffer:fromConnection:` is not the viewfinder. The preview layer never calls it, so `hook hit yes=0` with a live picture is expected until some other Camera output uses that delegate.

## What 0.2.9 changes

The display view is inserted above the preview host, in that view's superview. It is not inserted into a view whose layer is `AVCaptureVideoPreviewLayer`. While the cover is attached, the preview layer's opacity stays 0 and its connection is disabled. Both are restored when the cover is removed. Enqueued frames stay IOSurface-backed and CoreAnimation-compatible.

Copy, mirror, test.mp4 paths, and the reader → pixel buffer → sample buffer → injector chain are unchanged.

These lines are the runtime order. The first one that is missing, or that says `0`, is the break:

1. `init runs=1` — the tweak constructor ran inside Camera.
2. `MediaReader open path=… exists=… asset_create=… reader_create=… reader_status=…` — the path that was opened, whether the file was there, whether `AVURLAsset` and `AVAssetReader` were created, and the reader status (`none`, `reading`, `failed`, `cancelled`).
3. `first frame success=… pixelbuffer=…` — the first decode, and whether that sample held a `CVPixelBuffer`.
4. `feed timer started yes=…`
5. `VideoInjector CMSampleBuffer yes=…`
6. `hook hit yes=1` and `sample replaced yes=…` — only after a capture delegate runs. The viewfinder does not run it.
7. `overlay create=… view=… layer=… added_to=… hierarchy=…` — the cover, the view it was added to, and whether it is in the hierarchy.

The arm64-only link is unchanged. There is no device install in this change.
