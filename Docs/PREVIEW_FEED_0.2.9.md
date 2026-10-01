# Live preview after 0.2.8

Device report: 0.2.8 installed. `postinst` / `mirror.status` recorded `euid=0 copied=1 bytes=87195160 dest=/var/jb/var/mobile/Library/MyVCam/test.mp4 copy_errno=0`. Filza shows `test.mp4`, `postinst.log`, and `mirror.status` in that folder. Camera stays up and the viewfinder is still the live camera. The mirror copy is not the failure. No new device run was used.

0.2.9 keeps the same chain: `MyVCamManager` → `MediaReader` → `SampleBufferBuilder` → `VideoInjector`, and the C1 delegate hook. The filter is still `com.apple.camera` only. The tweak dylib and `myvcam-mirror` stay arm64 only. Diagnostic lines use `[MyVCam 0.2.9]`.

## Root cause

### 1. The cover was under the live image

`CAMPreviewView`'s layer is `AVCaptureVideoPreviewLayer`. 0.2.8 inserted the display view at index 0 of that view. A subview of that view is a sublayer of the preview layer, and this project already established that the live preview is composited above those sublayers. The imported frames can enqueue and the user still sees the camera.

0.2.7's loose `CALayer` sibling is not a `UIView`. UIKit keeps Photo mode's preview view above that layer, which is why a sibling layer stayed under the live image.

The hook does not change this. `captureOutput:didOutputSampleBuffer:fromConnection:` is not the viewfinder. The preview layer never calls it. A replaced sample still leaves the live image on screen.

### 2. The feed timer treated "not ready" as the end of the file

`copyNextSampleBuffer` can return `NULL` while `AVAssetReader` status is still `Reading`. 0.2.8 stored a nil `lastError` for that case, so the manager treated it as end of media. With no frame delivered yet, the feed cancelled its timer. The preview tick only keeps the cover up while the phase is live, so the cover was removed and the camera stayed on screen.

### 3. The decoder does not see the jbroot path Camera can `open()`

`open()` of `/var/jb/var/mobile/Library/MyVCam/test.mp4` can succeed inside Camera because Dopamine's extension covers this process. `AVAssetReader` and VideoToolbox reopen that URL outside the process. That service does not have the extension, so prepare fails, the timer never stays armed, and the cover never stays up. The bytes have to be decoded from a file inside Camera's container.

The mirror already tried to write that container file, and it searched `Data/System`. `com.apple.camera` is an application. Its container is `Data/Application`, so `container=` never pointed at a path Camera can read without the jbroot extension.

## What 0.2.9 changes

- The display view is inserted above the preview host view, in that view's superview. It is not inserted into a view whose layer is `AVCaptureVideoPreviewLayer`. While it is attached, the preview layer's opacity stays 0 and its capture connection is disabled, and both are restored when the cover is removed.
- Enqueued frames are IOSurface buffers marked CoreAnimation-compatible. A reader buffer whose base address stays NULL is locked through its IOSurface before the copy.
- `NULL` while the reader is still `Reading` is `MyVCamMediaReaderErrorCodeTryAgain`. The feed tick retries and does not cancel the timer. End of media is still a completed reader.
- If the opened path is outside Camera's home directory, `MediaReader` copies that fd into `Library/MyVCam/playback.mp4` in the container and decodes that URL. A matching size and mtime skips the copy. IOSurface output settings are tried first; a refusal falls back to CPU `32BGRA`.
- `myvcam-mirror` searches `Data/Application` before `Data/System` when it looks up `com.apple.camera`.

The arm64-only link is unchanged. There is no device install in this change.
