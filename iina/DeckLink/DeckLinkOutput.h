//
//  DeckLinkOutput.h
//  iina
//
//  Routing decoded video to a Blackmagic DeckLink / UltraStudio device.
//
//  The Blackmagic SDK is a C++ COM-style API, so the implementation is Objective-C++ and this
//  header deliberately exposes only plain Objective-C types: it is imported by the bridging header,
//  and Swift cannot see the C++ interfaces.
//
//  Nothing Blackmagic is linked or shipped. DeckLinkAPIDispatch.cpp CFBundle-loads
//  /Library/Frameworks/DeckLinkAPI.framework at runtime, which the user's Desktop Video install
//  provides; with no Desktop Video installed, `devices` simply returns an empty array.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Pixel format offered to the device. The SDK supports more than this; these are the ones the
/// feeder can currently pack. Note FFmpeg's decklink muxer can only ever emit the first two, which
/// is a large part of why this talks to the SDK directly rather than going through libavdevice.
typedef NS_ENUM(NSInteger, DeckLinkPixelFormat) {
  DeckLinkPixelFormat8BitYUV = 0,   ///< '2vuy', 4:2:2 8-bit
  DeckLinkPixelFormat10BitYUV,      ///< 'v210', 4:2:2 10-bit
  DeckLinkPixelFormat10BitRGB,      ///< 'r210', 4:4:4 10-bit, SMPTE levels
};

/// SDI link configuration. 4:4:4 and the higher bit depths need more bandwidth than a single HD-SDI
/// link carries, which is what dual and quad link are for; the device rejects combinations it cannot
/// carry, so the menu offers only what it accepts.
typedef NS_ENUM(NSInteger, DeckLinkSDILink) {
  DeckLinkSDILinkSingle = 0,
  DeckLinkSDILinkDual,
  DeckLinkSDILinkQuad,
};

/// Video range of the signal we generate. Single-link HD-SDI to a broadcast monitor wants SMPTE.
typedef NS_ENUM(NSInteger, DeckLinkVideoRange) {
  DeckLinkVideoRangeSMPTE = 0,      ///< legal / studio levels
  DeckLinkVideoRangeFull,
};

/// An output-capable device, as enumerated from the driver.
@interface DeckLinkDevice : NSObject
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSString *modelName;
/// Stable-ish identity for restoring a selection across launches and hot-plug.
@property (nonatomic, readonly, copy) NSString *identifier;
@end

/// One output display mode of a device. `width`/`height`/`fps` come from the driver, and the
/// `supports*` flags are answered by DoesSupportVideoMode rather than assumed.
@interface DeckLinkMode : NSObject
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) double fps;
/// True when the mode is transmitted as interlaced or PsF rather than progressive. A CRT master
/// monitor on single-link HD-SDI generally wants one of these.
@property (nonatomic, readonly) BOOL isInterlacedOrPsF;
/// True only for a genuinely interlaced raster (upper or lower field first), false for PsF. PsF
/// carries whole progressive frames in an interlaced raster; a truly interlaced mode expects each
/// field to be a distinct moment in time.
@property (nonatomic, readonly) BOOL isInterlaced;
/// Which field is transmitted first, and therefore which one carries the EARLIER time sample.
@property (nonatomic, readonly) BOOL upperFieldFirst;
@property (nonatomic, readonly) BOOL supports8BitYUV;
@property (nonatomic, readonly) BOOL supports10BitYUV;
@property (nonatomic, readonly) BOOL supports10BitRGB;
@end

/// What the attached device can actually be asked to do, probed once per device rather than assumed:
/// these are IDeckLinkConfiguration capabilities, and they differ a lot between models.
@interface DeckLinkCapabilities : NSObject
@property (nonatomic, readonly) BOOL supports444SDI;
@property (nonatomic, readonly) BOOL supportsLevelA;
@property (nonatomic, readonly) BOOL supportsDualLink;
@property (nonatomic, readonly) BOOL supportsQuadLink;
@end

/// Fills one frame. Called on a worker thread owned by the active output path, never on the card's
/// completion thread and never on the main thread. Return NO to emit the previous frame again (a
/// repeat is always better than starving the scheduler, which shows as a dropped frame).
///
/// The buffer is BGRA, 8 bits per component, `stride` bytes per row, `width` x `height` as
/// requested by the active mode. Packing to the wire format happens inside the feeder.
typedef BOOL (^DeckLinkFrameProvider)(void *buffer, NSInteger width, NSInteger height,
                                      NSInteger stride);

@interface DeckLinkOutput : NSObject

/// Output-capable devices currently attached. Empty when Desktop Video is not installed.
+ (NSArray<DeckLinkDevice *> *)devices;

/// Output modes for a device, in driver order.
+ (NSArray<DeckLinkMode *> *)modesForDeviceAtIndex:(NSInteger)deviceIndex
    NS_SWIFT_NAME(modes(forDeviceAt:));

/// True once Desktop Video is present and the API could be dispatched at all.
+ (BOOL)isDriverAvailable;

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSInteger activeWidth;
@property (nonatomic, readonly) NSInteger activeHeight;
@property (nonatomic, readonly) double activeFPS;

/// Frames scheduled, and how many the device reported late or dropped. Surfaced so the UI can be
/// honest about whether playout is actually keeping up rather than just claiming it is.
@property (nonatomic, readonly) NSInteger scheduledFrames;
@property (nonatomic, readonly) NSInteger lateFrames;
@property (nonatomic, readonly) NSInteger droppedFrames;
/// How many times the scheduler had to jump forward because it had fallen behind the card. Each
/// resync leaves a short hole in the schedule (the card holds its last frame), so a number that
/// keeps climbing is itself the explanation for a stuttering picture.
@property (nonatomic, readonly) NSInteger resyncCount;
/// Frames re-sent because the worker had nothing new packed. A repeat keeps the schedule contiguous
/// and is invisible, so a high repeat count is a far better outcome than a resync.
@property (nonatomic, readonly) NSInteger repeatCount;

/// Open the device and begin scheduled playback. `provider` is retained for the session.
/// Returns NO and populates `error` if the device is busy or rejects the mode/format pair.
/// Configuration capabilities of a device, or nil if it cannot be opened.
+ (nullable DeckLinkCapabilities *)capabilitiesForDeviceAtIndex:(NSInteger)deviceIndex
    NS_SWIFT_NAME(capabilities(forDeviceAt:));

- (BOOL)startWithDeviceIndex:(NSInteger)deviceIndex
                   modeIndex:(NSInteger)modeIndex
                 pixelFormat:(DeckLinkPixelFormat)pixelFormat
                       range:(DeckLinkVideoRange)range
                        link:(DeckLinkSDILink)link
                      use444:(BOOL)use444
                      levelA:(BOOL)levelA
                  lowLatency:(BOOL)lowLatency
                    provider:(nullable DeckLinkFrameProvider)provider
                       error:(NSError *_Nullable *_Nullable)error;

/// Low-latency mode only: a new frame is available from the provider; pack and show it at the next
/// output refresh. Cheap to call, coalesces bursts, no-op in scheduled mode or when stopped.
- (void)displayNow;

/// Stop playback and release the device. Safe to call when not running.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
