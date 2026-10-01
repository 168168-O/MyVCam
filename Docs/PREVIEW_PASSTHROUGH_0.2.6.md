# Live preview after 0.2.5

Device report: iPhone 12, iOS 15.3.1, Dopamine rootless, ElleKit. MyVCam 0.2.5 (`f2343a893019fe903a8e3ea6633af818605b202e`) loads. Camera no longer force-quits. The viewfinder still shows the live camera when `/var/mobile/Documents/MyVCam/test.mp4` is present. No new device run was used. This is from the 0.2.5 control flow.

0.2.6 keeps the same chain: `MyVCamManager` → `MediaReader` → `SampleBufferBuilder` → `VideoInjector`, and the C1 delegate hook. The filter is still `com.apple.camera` only. The dylib stays arm64 only.

## Root cause

### 1. The feed never starts unless 30 delegate callbacks are counted

`MyVCamC1C_ScheduleEnable` ran only from `MyVCamC1C_NotePassthrough`, and only when `gPassthroughCount` hit exactly 30. That counter incremented only inside `MyVCamC1A_Deliver`, and only when `gCaptureSessionRunning` was already YES and `gPhase` was warmup.

`gCaptureSessionRunning` was set in `-[AVCaptureSession startRunning]` **after** `%orig` returned. Callbacks delivered during `%orig` did not count. Every later `startRunning` reset the counter and bumped `gSessionGeneration`, which dropped a pending enable. Every `stopRunning` did the same and queued `[MyVCamManager stop]`, including the `stopRunning` Camera makes from inside `startRunning`.

The viewfinder does not use that callback. `AVCaptureVideoPreviewLayer` displays the session directly. It never calls `captureOutput:didOutputSampleBuffer:fromConnection:`. With no video-data-output delegate, the counter stays at 0, `attachMediaFileURL:` / `startWithError:` never run, and `VideoInjector` stays empty. The process does not crash. The preview stays the live camera.

### 2. A delegate swap would not change that preview anyway

C1-B only replaces the sample passed into the video-data-output delegate. The Camera viewfinder is the preview layer, so a successful swap still leaves the live image on screen. `copyLatestSampleBufferMatchingOrigin:` also returns NULL for any origin format other than `32BGRA`, `420f`, and `420v` (iOS 15 compressed formats on iPhone 12 are outside that set) and previously logged that once with no FourCC. The hook then keeps the camera sample.

## What 0.2.6 changes

- After `startRunning`'s original implementation returns, if the session is running, `com.myvcam.enable` attaches and starts on its next turn. It does not wait for delegate callbacks.
- A `startRunning` that finds the session already recorded does not reset the generation.
- `stopRunning` stops the feed only when the session was running and is not running afterwards, and not while `startRunning` is still on the stack.
- An unreadable `test.mp4` (including the `/private/var/...` spelling of the same path) logs `errno` and does not arm the timer. `/var/mobile/Documents/MyVCam/disable` still forces passthrough. Delete it and reopen Camera to re-enable.
- While the feed is running, each `AVCaptureVideoPreviewLayer` gets an `AVSampleBufferDisplayLayer` that enqueues `-[VideoInjector copyLatestSampleBuffer]`. That is the viewfinder path. The delegate hook still restamps a format-matched buffer from `com.myvcam.match` when one exists. A match miss logs the origin FourCC once and leaves that delegate sample alone.

The arm64-only link is unchanged. There is no device install in this change.
