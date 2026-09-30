//
//  MediaReader.h
//  MyVCam
//
//  Stage 2.2 — local video file reader.
//
//  Responsibility: open a local file, decode its first video track, and vend
//  CVPixelBuffer frames through MyVCamFrameSource. Timing for the last frame
//  is exposed separately. This type does not build CMSampleBuffer values and
//  does not inject them.
//
//  LAYERING: do not import or call SampleBufferBuilder or VideoInjector.
//  MyVCamManager is the only caller that may pass these buffers onward.
//
//  Reference (idea only, not vendored): DiCoy local AVAssetReader path
//  (_setupVideoReaderForPath:). No audio, no looping clock, no hooks.
//

#import <Foundation/Foundation.h>
#import "MyVCamFrameSource.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const MyVCamMediaReaderErrorDomain;

typedef NS_ENUM(NSInteger, MyVCamMediaReaderErrorCode) {
    /// Kept from Stage 2.1. prepareWithError: no longer returns this.
    MyVCamMediaReaderErrorCodeNotImplemented = 1,
    /// The URL is missing, not a file URL, or the path does not exist.
    MyVCamMediaReaderErrorCodeInvalidURL = 2,
    /// The asset loaded and has no video track. Audio-only files fail here.
    MyVCamMediaReaderErrorCodeNoVideoTrack = 3,
    /// AVAsset or AVAssetReader could not load or start, or a sample had no image.
    MyVCamMediaReaderErrorCodeReaderFailed = 4,
};

@interface MediaReader : NSObject <MyVCamFrameSource>

- (instancetype)init NS_UNAVAILABLE;

/// Stores fileURL. Does not open the file. Call -prepareWithError: to decode.
- (instancetype)initWithFileURL:(NSURL *)fileURL NS_DESIGNATED_INITIALIZER;

@property (nonatomic, copy, readonly) NSURL *fileURL;

/// Failure from the latest prepare or copy. Nil after a successful prepare,
/// and nil when -copyNextPixelBuffer returns NULL because the track ended.
@property (nonatomic, strong, readonly, nullable) NSError *lastError;

@end

NS_ASSUME_NONNULL_END
