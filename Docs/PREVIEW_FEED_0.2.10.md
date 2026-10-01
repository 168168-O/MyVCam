# Live preview after 0.2.9

Device report: iPhone 12, iOS 15.3.1, Dopamine rootless. MyVCam 0.2.9-1+debug is installed. `/var/mobile/Documents/MyVCam/test.mp4` is on disk (~87MB). `mirror.status` records `euid=0 uid=0 copied=1 bytes=87195160 mode=100644 source_errno=0 copy_errno=0 dest=/var/jb/var/mobile/Library/MyVCam/test.mp4`. `postinst.log` records the copy, mirror one-shot exit 0, and bootstrap/enable/kickstart exit 0. No `disable` file. Camera stays up and Photo mode still shows the live preview. The mirror copy is not the failure. Paths, the mirror, and the rootless layout are unchanged.

0.2.10 keeps the same chain: `MyVCamManager` → `MediaReader` → `SampleBufferBuilder` → `VideoInjector`, and the C1 delegate hook. The filter is still `com.apple.camera` only. The tweak dylib and `myvcam-mirror` stay arm64 only. Step logs use `[MyVCam 0.2.10]`.

## First break

0.2.9's note treated `CAMPreviewView`'s layer as `AVCaptureVideoPreviewLayer` and inserted the cover above that view. Photo mode does not host the preview that way. `CAMPreviewView` owns a `CAMVideoPreviewView`. That view owns `previewLayerView` and a separate `AVCaptureVideoPreviewLayer`, added as a sublayer of `previewLayerView`. `layoutSubviews` updates that sublayer and `addSublayer:` moves it to the front of `previewLayerView`.

The 0.2.9 placement only uses the superview when the preview layer is the UIView's backing layer. For the sublayer host it inserts the cover at index 0 of `previewLayerView` and gives it the preview layer's `zPosition`. Index 0 is behind that layer, and the next layout brings the live layer to the front again. Opacity on the preview layer and `connection.enabled = NO` do not stay in effect across that layout, and the preview image is not a normal sublayer that those properties reliably hide. The cover can be created, in the hierarchy, and fed frames, and Photo mode still shows the camera.

The delegate hook is not this break. The viewfinder never calls `captureOutput:didOutputSampleBuffer:fromConnection:`.

## What 0.2.10 changes

The cover is always the next subview of the host's superview, above `previewLayerView` (or above the view whose layer is the preview). It is not inserted into the view that contains the live layer. While the cover is up, that host's alpha stays 0 when the live layer is a sublayer, the preview opacity stays 0, and its connection stays disabled. The superview's own `layoutSubviews` runs that placement again after Camera's layout, so a later pass cannot leave the live view in front. Chrome that is already above the host stays above the cover. The cover does not take touches.

Copy, mirror, `test.mp4` paths, and the reader → pixel buffer → sample buffer → injector chain are unchanged.

These lines are the runtime order. The first one that is missing, or that says `0`, is the break:

1. `init runs=1` — the tweak constructor ran inside Camera.
2. `MediaReader open path=… exists=… asset_create=… reader_create=… reader_status=…` — the path that was opened, whether the file was there, whether `AVURLAsset` and `AVAssetReader` were created, and the reader status (`none`, `reading`, `failed`, `cancelled`).
3. `first frame success=… pixelbuffer=…` — the first decode, and whether that sample held a `CVPixelBuffer`.
4. `feed timer started yes=…`
5. `VideoInjector CMSampleBuffer yes=…`
6. `hook hit yes=1` and `sample replaced yes=…` — only after a capture delegate runs. The viewfinder does not run it.
7. `overlay create=… view=… layer=… added_to=… hierarchy=…` — the cover, the superview it was added to, and whether it is in the hierarchy. `added_to` is that superview, not `previewLayerView`.

`[MyVCam C1-C] preview overlay attached` also logs `host_layer=0` when the live layer is a sublayer. `[MyVCam C1-C] preview layout hooked class=…` is the superview class whose layout now re-places the cover.

The arm64-only link is unchanged. There is no device install in this change.
