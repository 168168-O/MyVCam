//
//  MyVCamPicker.h
//  Generic-injection helper: lets the user pick a video from Photos and
//  stores it inside the *host app's* sandbox:
//      <Documents>/MyVCam/test.mp4
//
//  Rationale: injected third-party apps cannot read
//  /var/mobile/Documents/MyVCam/test.mp4 (sandbox). PHPicker runs out of
//  process, so no NSPhotoLibraryUsageDescription is required in the host.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs a small draggable button on top of the host app's window.
/// Safe to call more than once; only the first call has an effect.
/// Must be called on the main thread.
void MyVCamPickerInstall(void);

/// Absolute path the tweak should read, or nil when no video was chosen.
/// Always inside the calling process' own container.
NSURL *_Nullable MyVCamPickerPreferredVideoURL(void);

NS_ASSUME_NONNULL_END
