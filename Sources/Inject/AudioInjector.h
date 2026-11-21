//
//  AudioInjector.h
//  MyVCam
//
//  Latest-audio source for the capture delegate hook. There are no hooks in
//  this class.
//
//  Responsibility: turn one local media file into 16-bit interleaved PCM that
//  matches the camera's microphone format, then hand the capture delegate a
//  replacement audio sample buffer with the camera buffer's timing.
//
//  Source selection:
//    1. the sidecar cloned-voice file, when the picker stored one;
//    2. otherwise the first audio track of the picked video.
//  A file with no audio track leaves the camera microphone untouched.
//
//  Decoding is lazy. The first audio callback tells this object the camera's
//  AudioStreamBasicDescription; the whole track is decoded once on a private
//  serial queue into memory (capped), and later callbacks read that memory in
//  a loop. Nothing is decoded on the capture queue.
//
//  LAYERING: no imports of MyVCamManager, MediaReader, VideoInjector, or the
//  picker. Tweak.x owns this object and passes URLs in.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioInjector : NSObject

+ (instancetype)sharedInjector;

/// Stores the two candidate sources. The sidecar audio file wins when it
/// exists; otherwise the video's own audio track is used. Cheap and
/// idempotent: when the resolved file, its size, and its modification date
/// are unchanged this returns without dropping the decoded PCM.
- (void)setSidecarURL:(nullable NSURL *)sidecarURL videoURL:(nullable NSURL *)videoURL;

/// Drops the decoded PCM, the source list, and any in-flight prepare result.
- (void)reset;

/// Caller owns the result (CF_RETURNS_RETAINED) and must CFRelease it.
/// NULL means the caller should keep the camera microphone sample.
/// NULL is returned while the first decode is still running, when the origin
/// is not audio, when the microphone format cannot be matched (float,
/// big-endian, non-interleaved, or more than two channels), and when the
/// source has no audio track.
/// The returned buffer uses the origin format description and the origin
/// presentation time and duration, so the receiver's timeline is unchanged.
- (CMSampleBufferRef _Nullable)copySampleBufferMatchingOrigin:(CMSampleBufferRef)origin
    CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
