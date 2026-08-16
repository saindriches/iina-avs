//
//  DeckLinkOutput.mm
//  iina
//
//  Objective-C++ bridge to the Blackmagic DeckLink SDK. See DeckLinkOutput.h for why the public
//  interface is plain Objective-C.
//
//  The card generates the SDI signal in both output paths; what differs is how frames reach it.
//
//  Scheduled playback attaches an explicit display time to each frame and keeps a queue of them.
//  The queue absorbs jitter in the producer, so cadence is exact, and it is also what makes the
//  path cost several frames of delay. A worker thread does the pixel work; completions schedule
//  the next queued frame and hand the finished buffer back, which paces the worker indirectly
//  because it can only pack into buffers the card has released.
//
//  Immediate display (see SyncDisplayer) has no timestamps and no queue, so latency is pack time
//  plus refresh alignment. With no queue there is nothing to absorb producer jitter, so content
//  cadence is only as regular as the frames arriving from the tap.
//

#import "DeckLinkOutput.h"

#import "sdk/DeckLinkAPI.h"

#import <atomic>
#import <condition_variable>
#import <deque>
#import <mutex>
#import <thread>
#import <vector>

#pragma mark - helpers

static NSString *DLStringFromCF(CFStringRef s) {
  if (!s) return @"";
  return (__bridge_transfer NSString *)s;  // takes ownership; SDK getters return +1
}

static NSError *DLError(NSInteger code, NSString *msg) {
  return [NSError errorWithDomain:@"io.iina.decklink" code:code
                         userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static BMDPixelFormat DLBMDFormat(DeckLinkPixelFormat f) {
  switch (f) {
    case DeckLinkPixelFormat10BitYUV: return bmdFormat10BitYUV;
    case DeckLinkPixelFormat10BitRGB: return bmdFormat10BitRGB;
    case DeckLinkPixelFormat8BitYUV:
    default:                          return bmdFormat8BitYUV;
  }
}

static long DLRowBytes(BMDPixelFormat fmt, long w) {
  switch (fmt) {
    case bmdFormat8BitYUV:  return w * 2;
    case bmdFormat10BitYUV: return ((w + 47) / 48) * 128;   // v210 packs 6 pixels per 16 bytes
    case bmdFormat10BitRGB: return ((w + 63) / 64) * 256;   // r210 rows align to 64 pixels
    default:                return w * 4;
  }
}

/// Walk a device list to the Nth entry. Caller releases. Returns NULL when absent.
static IDeckLink *DLDeviceAt(NSInteger index) {
  IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
  if (!it) return NULL;
  IDeckLink *dl = NULL;
  NSInteger i = 0;
  while (it->Next(&dl) == S_OK) {
    if (i++ == index) { it->Release(); return dl; }
    dl->Release();
  }
  it->Release();
  return NULL;
}

/// A device only counts for us if it can output.
static IDeckLinkOutput *DLOutputFor(IDeckLink *dl) {
  IDeckLinkOutput *out = NULL;
  if (!dl || dl->QueryInterface(IID_IDeckLinkOutput, (void **)&out) != S_OK) return NULL;
  return out;
}

#pragma mark - colour packing
// Source is packed 10-bit BGRA, one little-endian uint32 per pixel (GL_BGRA +
// GL_UNSIGNED_INT_2_10_10_10_REV): B in bits 0-9, G in 10-19, R in 20-29, alpha in the top 2.
//
// It used to be BGRA8, and the 10-bit packers simply multiplied by four, so choosing a 10-bit
// output format widened the container without adding a single bit of picture. Everything here now
// works in the 0..1023 domain end to end. Matrix is BT.709; SMPTE range maps to Y 64..940 /
// C 64..960, full range keeps 0..1023. 4:2:2 averages chroma across each pair.

namespace {

struct Coeffs { double yScale, yOff, cScale, cOff; };

inline Coeffs coeffsFor(DeckLinkVideoRange range) {
  if (range == DeckLinkVideoRangeFull) return {1.0, 0.0, 1.0, 512.0};
  return {876.0 / 1023.0, 64.0, 896.0 / 1023.0, 512.0};
}

/// Unpack one 2:10:10:10 pixel and convert. Components come out in the 0..1023 domain.
inline void bgraToYCbCr(const uint8_t *p, const Coeffs &c, double &y, double &cb, double &cr) {
  uint32_t w;
  memcpy(&w, p, sizeof(w));
  const double b = double(w & 0x3ffu), g = double((w >> 10) & 0x3ffu), r = double((w >> 20) & 0x3ffu);
  y  = c.yOff + (0.2126 * r + 0.7152 * g + 0.0722 * b) * c.yScale;
  cb = c.cOff + (-0.1146 * r - 0.3854 * g + 0.5000 * b) * c.cScale;
  cr = c.cOff + (0.5000 * r - 0.4542 * g - 0.0458 * b) * c.cScale;
}

inline int clampTo(double v, int lo, int hi) {
  int i = int(v + 0.5);
  return i < lo ? lo : (i > hi ? hi : i);
}

void packUYVY(const uint8_t *src, long srcStride, uint8_t *dst, long dstStride,
              long w, long h, DeckLinkVideoRange range) {
  const Coeffs c = coeffsFor(range);
  // Clamp in the 10-bit domain and shift down at the end: 64..940 >> 2 lands exactly on 16..235.
  const int lo = (range == DeckLinkVideoRangeFull) ? 0 : 4, hi = 1019;
  for (long y = 0; y < h; y++) {
    const uint8_t *s = src + y * srcStride;
    uint8_t *d = dst + y * dstStride;
    for (long x = 0; x < w; x += 2) {
      double y0, cb0, cr0, y1, cb1, cr1;
      bgraToYCbCr(s + x * 4, c, y0, cb0, cr0);
      bgraToYCbCr(s + (x + 1 < w ? x + 1 : x) * 4, c, y1, cb1, cr1);
      d[x * 2 + 0] = uint8_t(clampTo((cb0 + cb1) / 2, lo, hi) >> 2);
      d[x * 2 + 1] = uint8_t(clampTo(y0, lo, hi) >> 2);
      d[x * 2 + 2] = uint8_t(clampTo((cr0 + cr1) / 2, lo, hi) >> 2);
      d[x * 2 + 3] = uint8_t(clampTo(y1, lo, hi) >> 2);
    }
  }
}

// v210: 6 pixels per 4 little-endian 32-bit words, 10 bits per component.
//   w0 = Cb0 | Y0<<10 | Cr0<<20      w1 = Y1  | Cb2<<10 | Y2<<20
//   w2 = Cr2 | Y3<<10 | Cb4<<20      w3 = Y4  | Cr4<<10 | Y5<<20
void packV210(const uint8_t *src, long srcStride, uint8_t *dst, long dstStride,
              long w, long h, DeckLinkVideoRange range) {
  const Coeffs c = coeffsFor(range);
  const int lo = (range == DeckLinkVideoRangeFull) ? 0 : 4, hi = 1019;
  // Note the two-argument form: `std::vector<int> Y(size_t(w))` is a function declaration.
  std::vector<int> Y(size_t(w), 0);
  std::vector<int> Cb(size_t((w + 1) / 2), 0);
  std::vector<int> Cr(size_t((w + 1) / 2), 0);
  for (long y = 0; y < h; y++) {
    const uint8_t *s = src + y * srcStride;
    for (long x = 0; x < w; x += 2) {
      double y0, cb0, cr0, y1, cb1, cr1;
      bgraToYCbCr(s + x * 4, c, y0, cb0, cr0);
      bgraToYCbCr(s + (x + 1 < w ? x + 1 : x) * 4, c, y1, cb1, cr1);
      Y[size_t(x)] = clampTo(y0, lo, hi);
      if (x + 1 < w) Y[size_t(x + 1)] = clampTo(y1, lo, hi);
      Cb[size_t(x / 2)] = clampTo((cb0 + cb1) / 2, lo, hi);
      Cr[size_t(x / 2)] = clampTo((cr0 + cr1) / 2, lo, hi);
    }
    uint32_t *d = (uint32_t *)(dst + y * dstStride);
    long wi = 0;
    for (long x = 0; x < w; x += 6) {
      auto yv = [&](long i) { return uint32_t(i < w ? Y[size_t(i)] : Y[size_t(w - 1)]); };
      auto cbv = [&](long i) { long k = i / 2; long m = (w + 1) / 2 - 1; return uint32_t(Cb[size_t(k > m ? m : k)]); };
      auto crv = [&](long i) { long k = i / 2; long m = (w + 1) / 2 - 1; return uint32_t(Cr[size_t(k > m ? m : k)]); };
      d[wi++] = cbv(x)     | (yv(x)     << 10) | (crv(x)     << 20);
      d[wi++] = yv(x + 1)  | (cbv(x + 2) << 10) | (yv(x + 2) << 20);
      d[wi++] = crv(x + 2) | (yv(x + 3) << 10) | (cbv(x + 4) << 20);
      d[wi++] = yv(x + 4)  | (crv(x + 4) << 10) | (yv(x + 5) << 20);
    }
  }
}

// r210: big-endian 32-bit words, 2 bits padding then R:G:B at 10 bits each, SMPTE levels 64..940.
void packR210(const uint8_t *src, long srcStride, uint8_t *dst, long dstStride,
              long w, long h, DeckLinkVideoRange range) {
  const bool smpte = (range != DeckLinkVideoRangeFull);
  for (long y = 0; y < h; y++) {
    const uint8_t *s = src + y * srcStride;
    uint8_t *d = dst + y * dstStride;
    for (long x = 0; x < w; x++) {
      uint32_t px;
      memcpy(&px, s + x * 4, sizeof(px));
      auto up = [&](uint32_t v) -> uint32_t {
        // 10-bit full range in; SMPTE compresses into 64..940, full range passes straight through.
        if (!smpte) return v > 1023u ? 1023u : v;
        int i = int(64.0 + double(v) * (940.0 - 64.0) / 1023.0 + 0.5);
        return uint32_t(i < 0 ? 0 : (i > 1023 ? 1023 : i));
      };
      const uint32_t b10 = px & 0x3ffu, g10 = (px >> 10) & 0x3ffu, r10 = (px >> 20) & 0x3ffu;
      const uint32_t word = (up(r10) << 20) | (up(g10) << 10) | up(b10);
      d[x * 4 + 0] = uint8_t((word >> 24) & 0xff);
      d[x * 4 + 1] = uint8_t((word >> 16) & 0xff);
      d[x * 4 + 2] = uint8_t((word >> 8) & 0xff);
      d[x * 4 + 3] = uint8_t(word & 0xff);
    }
  }
}

}  // namespace

/// Acquire the configuration interface. Caller releases. NULL if the device has none.
static IDeckLinkConfiguration *DLConfigFor(IDeckLink *dl) {
  IDeckLinkConfiguration *cfg = NULL;
  if (!dl || dl->QueryInterface(IID_IDeckLinkConfiguration, (void **)&cfg) != S_OK) return NULL;
  return cfg;
}

static BMDLinkConfiguration DLBMDLink(DeckLinkSDILink link) {
  switch (link) {
    case DeckLinkSDILinkDual: return bmdLinkConfigurationDualLink;
    case DeckLinkSDILinkQuad: return bmdLinkConfigurationQuadLink;
    case DeckLinkSDILinkSingle:
    default:                  return bmdLinkConfigurationSingleLink;
  }
}

/// Read a device capability. These are declared attributes, so asking costs nothing and touches no
/// setting; a device that does not answer is reported as not supporting the feature.
static BOOL DLAttrFlag(IDeckLinkProfileAttributes *attr, BMDDeckLinkAttributeID id) {
  bool value = false;
  if (!attr || attr->GetFlag(id, &value) != S_OK) return NO;
  return value ? YES : NO;
}

/// 4:4:4 has no attribute of its own, so ask the output whether it will take an RGB frame in some
/// mode. Full chroma on the wire needs an RGB pixel format to feed it; a device that cannot accept
/// one has no way to benefit from the flag.
static BOOL DLSupports444(IDeckLink *dl) {
  IDeckLinkOutput *out = NULL;
  if (dl->QueryInterface(IID_IDeckLinkOutput, (void **)&out) != S_OK || !out) return NO;
  bool supported = false;
  BMDDisplayMode actual = bmdModeUnknown;
  out->DoesSupportVideoMode(bmdVideoConnectionUnspecified, bmdModeHD1080i5994, bmdFormat10BitRGB,
                            bmdSupportedVideoModeDefault, &actual, &supported);
  out->Release();
  return supported ? YES : NO;
}

#pragma mark - model objects

@implementation DeckLinkDevice
- (instancetype)initWithIndex:(NSInteger)i display:(NSString *)d model:(NSString *)m {
  if ((self = [super init])) {
    _index = i; _displayName = [d copy]; _modelName = [m copy];
    _identifier = [[NSString alloc] initWithFormat:@"%@#%ld", m, (long)i];
  }
  return self;
}
@end

@implementation DeckLinkCapabilities
- (instancetype)initWith444:(BOOL)f444 levelA:(BOOL)la dual:(BOOL)dl quad:(BOOL)ql {
  if ((self = [super init])) {
    _supports444SDI = f444; _supportsLevelA = la; _supportsDualLink = dl; _supportsQuadLink = ql;
  }
  return self;
}
@end

@implementation DeckLinkMode
- (instancetype)initWithIndex:(NSInteger)i name:(NSString *)n width:(NSInteger)w height:(NSInteger)h
                          fps:(double)fps interlaced:(BOOL)il
                    trueInterlaced:(BOOL)tif upperFieldFirst:(BOOL)uff
                         yuv8:(BOOL)y8 yuv10:(BOOL)y10 rgb10:(BOOL)r10 {
  if ((self = [super init])) {
    _index = i; _name = [n copy]; _width = w; _height = h; _fps = fps;
    _isInterlacedOrPsF = il; _isInterlaced = tif; _upperFieldFirst = uff;
    _supports8BitYUV = y8; _supports10BitYUV = y10; _supports10BitRGB = r10;
  }
  return self;
}
@end

#pragma mark - the feeder

@class DeckLinkOutput;

namespace {

/// Frames we aim to keep queued ahead of the card. Deep enough to absorb scheduling jitter, shallow
/// enough that the added output delay stays small (~200ms at 29.97, ~100ms at 59.94). Preroll uses
/// the same number so playback starts at exactly the depth the resync guard maintains.
constexpr uint64_t kTargetDepth = 6;

class Feeder : public IDeckLinkVideoOutputCallback {
public:
  Feeder(IDeckLinkOutput *out, DeckLinkFrameProvider provider,
         long w, long h, BMDPixelFormat fmt, DeckLinkVideoRange range,
         BMDTimeValue frameDuration, BMDTimeScale timeScale,
         std::vector<IDeckLinkMutableVideoFrame *> pool)
      : out_(out), provider_(provider), w_(w), h_(h), fmt_(fmt), range_(range),
        frameDuration_(frameDuration), timeScale_(timeScale), srcStride_(w * 4) {
    src_.resize(size_t(srcStride_) * size_t(h), 0);
    for (auto *f : pool) free_.push_back(f);
  }

  ~Feeder() { stop(); }

  /// Fill the queue and hand the card its opening frames. Call before StartScheduledPlayback.
  void startAndPreroll() {
    worker_ = std::thread([this] { workerLoop(); });
    // Wait briefly for the worker to produce the opening frames. If the provider is not ready yet
    // this still proceeds: the card gets whatever exists and the queue fills as playback runs.
    for (int waited = 0; waited < 200; waited++) {
      { std::lock_guard<std::mutex> lk(m_); if (ready_.size() >= kTargetDepth) break; }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    for (uint64_t i = 0; i < kTargetDepth; i++) {
      IDeckLinkMutableVideoFrame *f = takeReady();
      if (!f) break;
      scheduleFrame(f);
    }
  }

  void stop() {
    if (!running_.exchange(false)) return;
    cvFree_.notify_all();
    if (worker_.joinable()) worker_.join();
  }

  /// Runs on the card's thread and must stay cheap: queue handling and the schedule call only, no
  /// pixel work. Packing here costs an 8 MB copy plus two million pixels converted, which overruns
  /// the frame budget; since scheduling is one-in-one-out the queue can only erode, so any overrun
  /// becomes a resync and a visible gap.
  HRESULT ScheduledFrameCompleted(IDeckLinkVideoFrame *completed,
                                  BMDOutputFrameCompletionResult r) override {
    if (r == bmdOutputFrameDisplayedLate) late_++;
    if (r == bmdOutputFrameDropped) dropped_++;
    if (!running_.load()) return S_OK;

    IDeckLinkMutableVideoFrame *done = static_cast<IDeckLinkMutableVideoFrame *>(completed);
    if (IDeckLinkMutableVideoFrame *next = takeReady()) {
      scheduleFrame(next);
      { std::lock_guard<std::mutex> lk(m_); free_.push_back(done); }
      cvFree_.notify_one();
    } else {
      // Keep the schedule contiguous, but the repeat MUST carry the newest content. `done` holds
      // the oldest picture in flight (it just finished displaying) while the card still has newer
      // frames queued, so re-sending it as-is puts old content after new and the picture jumps
      // backwards by roughly the queue depth. Refresh it from the last packed image first.
      repeats_++;
      {
        std::lock_guard<std::mutex> lk(m_);
        if (!lastWire_.empty()) {
          void *dst = NULL;
          done->GetBytes(&dst);
          const size_t n = std::min(lastWire_.size(),
                                    size_t(done->GetRowBytes()) * size_t(h_));
          if (dst && n) memcpy(dst, lastWire_.data(), n);
        }
      }
      scheduleFrame(done);
    }
    return S_OK;
  }

  HRESULT ScheduledPlaybackHasStopped() override { return S_OK; }
  HRESULT QueryInterface(REFIID, LPVOID *) override { return E_NOINTERFACE; }
  ULONG AddRef() override { return ++refs_; }
  ULONG Release() override { return --refs_; }

  uint64_t scheduled() const { return pumped_.load(); }
  int late() const { return late_.load(); }
  int dropped() const { return dropped_.load(); }
  int resyncs() const { return resyncs_.load(); }
  int repeats() const { return repeats_.load(); }

private:
  IDeckLinkMutableVideoFrame *takeReady() {
    std::lock_guard<std::mutex> lk(m_);
    if (ready_.empty()) return nullptr;
    IDeckLinkMutableVideoFrame *f = ready_.front();
    ready_.pop_front();
    return f;
  }

  /// Pixel work lives here, off the card's thread.
  void workerLoop() {
    while (running_.load()) {
      IDeckLinkMutableVideoFrame *f = nullptr;
      {
        std::unique_lock<std::mutex> lk(m_);
        cvFree_.wait(lk, [this] { return !free_.empty() || !running_.load(); });
        if (!running_.load()) return;
        f = free_.front();
        free_.pop_front();
      }

      bool filled = false;
      if (provider_) {
        @autoreleasepool { filled = provider_(src_.data(), w_, h_, srcStride_); }
      }
      if (!filled) {
        // No new picture. Don't burn a core packing the same frame over and over; hand it back and
        // wait roughly one frame. The card repeats meanwhile, which is what we want.
        { std::lock_guard<std::mutex> lk(m_); free_.push_back(f); }
        std::this_thread::sleep_for(std::chrono::microseconds(
            frameDuration_ && timeScale_ ? (1000000 * frameDuration_) / timeScale_ : 16000));
        continue;
      }

      void *dst = NULL;
      f->GetBytes(&dst);
      const long dstStride = f->GetRowBytes();
      switch (fmt_) {
        case bmdFormat10BitYUV: packV210(src_.data(), srcStride_, (uint8_t *)dst, dstStride, w_, h_, range_); break;
        case bmdFormat10BitRGB: packR210(src_.data(), srcStride_, (uint8_t *)dst, dstStride, w_, h_, range_); break;
        default:                packUYVY(src_.data(), srcStride_, (uint8_t *)dst, dstStride, w_, h_, range_); break;
      }
      {
        std::lock_guard<std::mutex> lk(m_);
        // Mirror the packed bytes so a repeat can be refreshed with the newest content (see the
        // completion handler). One extra copy per frame on this thread, well within budget.
        const size_t n = size_t(dstStride) * size_t(h_);
        if (lastWire_.size() != n) lastWire_.assign(n, 0);
        memcpy(lastWire_.data(), dst, n);
        ready_.push_back(f);
      }
    }
  }

  void scheduleFrame(IDeckLinkMutableVideoFrame *frame) {
    // The assign-time-then-schedule sequence must be atomic as a unit: index_ is read-modify-write
    // (fetch_add, then a possible store on resync), and preroll runs on the main thread while
    // completions arrive on the card's, so racing callers could hand out times out of sequence.
    std::lock_guard<std::mutex> guard(scheduleMutex_);

    // Never schedule into the past: with a plain incrementing counter, one slip behind the card's
    // clock makes every later frame late forever. If we have fallen behind, jump to kTargetDepth
    // frames ahead of where the card actually is.
    uint64_t n = index_.fetch_add(1);
    BMDTimeValue target = BMDTimeValue(n) * frameDuration_;
    BMDTimeValue streamTime = 0;
    double speed = 0;
    if (out_->GetScheduledStreamTime(timeScale_, &streamTime, &speed) == S_OK) {
      if (target - streamTime < frameDuration_) {
        n = uint64_t(streamTime / frameDuration_) + kTargetDepth;
        index_.store(n + 1);
        target = BMDTimeValue(n) * frameDuration_;
        resyncs_++;
      }
    }
    out_->ScheduleVideoFrame(frame, target, frameDuration_, timeScale_);
    pumped_++;
  }

  IDeckLinkOutput *out_;
  DeckLinkFrameProvider provider_;
  long w_, h_;
  BMDPixelFormat fmt_;
  DeckLinkVideoRange range_;
  BMDTimeValue frameDuration_;
  BMDTimeScale timeScale_;
  long srcStride_;
  std::vector<uint8_t> src_;

  std::mutex m_;
  std::mutex scheduleMutex_;   // orders time assignment + ScheduleVideoFrame
  std::condition_variable cvFree_;
  std::deque<IDeckLinkMutableVideoFrame *> free_, ready_;
  std::vector<uint8_t> lastWire_;   // newest packed frame, wire format; guarded by m_
  std::thread worker_;

  std::atomic<uint64_t> index_{0};       // next frame INDEX (jumps on resync)
  std::atomic<uint64_t> pumped_{0};      // frames actually handed to the card
  std::atomic<int> late_{0}, dropped_{0}, resyncs_{0}, repeats_{0};
  std::atomic<bool> running_{true};
  std::atomic<ULONG> refs_{1};
};

}  // namespace

namespace {

/// Immediate-display path: on each notify, pull the newest frame, pack it, and hand it to
/// DisplayVideoFrameSync, which shows it at the card's next output refresh. No scheduler, no queue,
/// no preroll, so latency is pack time plus refresh alignment.
///
/// The card still clocks the signal here. What is given up is the queue, and with it the tolerance
/// for a producer whose rate and phase are not locked to the card: a late or early frame becomes a
/// duplicate or a skip instead of being absorbed.
class SyncDisplayer {
public:
  SyncDisplayer(IDeckLinkOutput *out, DeckLinkFrameProvider provider,
                long w, long h, BMDPixelFormat fmt, DeckLinkVideoRange range,
                std::vector<IDeckLinkMutableVideoFrame *> pool)
      : out_(out), provider_(provider), w_(w), h_(h), fmt_(fmt), range_(range),
        pool_(std::move(pool)), srcStride_(w * 4) {
    src_.resize(size_t(srcStride_) * size_t(h), 0);
    thread_ = std::thread([this] { loop(); });
  }

  ~SyncDisplayer() { stop(); }

  void notify() {
    { std::lock_guard<std::mutex> lk(m_); pending_ = true; }
    cv_.notify_one();
  }

  void stop() {
    if (!running_.exchange(false)) return;
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
  }

  uint64_t displayed() const { return displayed_.load(); }

private:
  void loop() {
    while (running_.load()) {
      {
        std::unique_lock<std::mutex> lk(m_);
        cv_.wait(lk, [this] { return pending_ || !running_.load(); });
        if (!running_.load()) return;
        pending_ = false;   // coalesce: bursts collapse into one display of the newest frame
      }

      bool filled = false;
      if (provider_) {
        @autoreleasepool { filled = provider_(src_.data(), w_, h_, srcStride_); }
      }
      if (!filled) continue;

      // Rotate frames so we never write into the one the card may still be scanning out.
      IDeckLinkMutableVideoFrame *f = pool_[cursor_++ % pool_.size()];
      void *dst = NULL;
      f->GetBytes(&dst);
      const long dstStride = f->GetRowBytes();
      switch (fmt_) {
        case bmdFormat10BitYUV: packV210(src_.data(), srcStride_, (uint8_t *)dst, dstStride, w_, h_, range_); break;
        case bmdFormat10BitRGB: packR210(src_.data(), srcStride_, (uint8_t *)dst, dstStride, w_, h_, range_); break;
        default:                packUYVY(src_.data(), srcStride_, (uint8_t *)dst, dstStride, w_, h_, range_); break;
      }
      if (out_->DisplayVideoFrameSync(f) == S_OK) displayed_++;
    }
  }

  IDeckLinkOutput *out_;
  DeckLinkFrameProvider provider_;
  long w_, h_;
  BMDPixelFormat fmt_;
  DeckLinkVideoRange range_;
  std::vector<IDeckLinkMutableVideoFrame *> pool_;
  long srcStride_;
  std::vector<uint8_t> src_;
  size_t cursor_ = 0;
  std::mutex m_;
  std::condition_variable cv_;
  bool pending_ = false;
  std::thread thread_;
  std::atomic<uint64_t> displayed_{0};
  std::atomic<bool> running_{true};
};

}  // namespace

#pragma mark - DeckLinkOutput

@implementation DeckLinkOutput {
  IDeckLink *_device;
  IDeckLinkOutput *_output;
  IDeckLinkConfiguration *_config;
  Feeder *_feeder;
  SyncDisplayer *_sync;
  std::vector<IDeckLinkMutableVideoFrame *> _pool;
  std::mutex _lock;
  // These three back readonly properties whose getters are implemented below, so the compiler does
  // not synthesize storage for them. They hold the final tally after the feeder is torn down.
  NSInteger _scheduledFrames;
  NSInteger _lateFrames;
  NSInteger _droppedFrames;
  NSInteger _resyncCount;
  NSInteger _repeatCount;
}

+ (BOOL)isDriverAvailable {
  IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
  if (!it) return NO;
  it->Release();
  return YES;
}

+ (NSArray<DeckLinkDevice *> *)devices {
  NSMutableArray *result = [NSMutableArray array];
  IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
  if (!it) return result;   // no Desktop Video: an empty menu, not an error
  IDeckLink *dl = NULL;
  NSInteger i = 0;
  while (it->Next(&dl) == S_OK) {
    IDeckLinkOutput *out = DLOutputFor(dl);
    if (out) {                                  // skip capture-only devices
      CFStringRef d = NULL, m = NULL;
      dl->GetDisplayName(&d);
      dl->GetModelName(&m);
      [result addObject:[[DeckLinkDevice alloc] initWithIndex:i
                                                      display:DLStringFromCF(d)
                                                        model:DLStringFromCF(m)]];
      out->Release();
    }
    dl->Release();
    i++;
  }
  it->Release();
  return result;
}

+ (NSArray<DeckLinkMode *> *)modesForDeviceAtIndex:(NSInteger)deviceIndex {
  NSMutableArray *result = [NSMutableArray array];
  IDeckLink *dl = DLDeviceAt(deviceIndex);
  if (!dl) return result;
  IDeckLinkOutput *out = DLOutputFor(dl);
  if (!out) { dl->Release(); return result; }

  IDeckLinkDisplayModeIterator *modes = NULL;
  if (out->GetDisplayModeIterator(&modes) == S_OK && modes) {
    IDeckLinkDisplayMode *m = NULL;
    NSInteger i = 0;
    while (modes->Next(&m) == S_OK) {
      CFStringRef name = NULL;
      m->GetName(&name);
      BMDTimeValue dur = 0; BMDTimeScale ts = 0;
      m->GetFrameRate(&dur, &ts);
      const BMDFieldDominance fd = m->GetFieldDominance();
      const BOOL interlaced = (fd == bmdLowerFieldFirst || fd == bmdUpperFieldFirst ||
                               fd == bmdProgressiveSegmentedFrame);
      // PsF is excluded here: it is a progressive frame in an interlaced raster, so both its fields
      // are the same instant by definition. Only these two want field-rate temporal sampling.
      const BOOL trueInterlaced = (fd == bmdLowerFieldFirst || fd == bmdUpperFieldFirst);
      const BOOL upperFieldFirst = (fd == bmdUpperFieldFirst);
      // Ask the driver rather than assuming; support genuinely varies by mode (for example
      // 10-bit RGB is unavailable on the 50/60p UHD modes for bandwidth reasons).
      BOOL y8 = NO, y10 = NO, r10 = NO;
      BMDDisplayMode actual;
      bool ok = false;
      out->DoesSupportVideoMode(bmdVideoConnectionUnspecified, m->GetDisplayMode(), bmdFormat8BitYUV,
                                bmdSupportedVideoModeDefault, &actual, &ok);
      y8 = ok ? YES : NO;
      ok = false;
      out->DoesSupportVideoMode(bmdVideoConnectionUnspecified, m->GetDisplayMode(), bmdFormat10BitYUV,
                                bmdSupportedVideoModeDefault, &actual, &ok);
      y10 = ok ? YES : NO;
      ok = false;
      out->DoesSupportVideoMode(bmdVideoConnectionUnspecified, m->GetDisplayMode(), bmdFormat10BitRGB,
                                bmdSupportedVideoModeDefault, &actual, &ok);
      r10 = ok ? YES : NO;

      [result addObject:[[DeckLinkMode alloc] initWithIndex:i
                                                       name:DLStringFromCF(name)
                                                      width:m->GetWidth()
                                                     height:m->GetHeight()
                                                        fps:(dur ? double(ts) / double(dur) : 0.0)
                                                 interlaced:interlaced
                                             trueInterlaced:trueInterlaced
                                            upperFieldFirst:upperFieldFirst
                                                       yuv8:y8 yuv10:y10 rgb10:r10]];
      m->Release();
      i++;
    }
    modes->Release();
  }
  out->Release();
  dl->Release();
  return result;
}

+ (DeckLinkCapabilities *)capabilitiesForDeviceAtIndex:(NSInteger)deviceIndex {
  IDeckLink *dl = DLDeviceAt(deviceIndex);
  if (!dl) return nil;
  IDeckLinkProfileAttributes *attr = NULL;
  if (dl->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attr) != S_OK) attr = NULL;
  DeckLinkCapabilities *caps =
      [[DeckLinkCapabilities alloc] initWith444:DLSupports444(dl)
                                        levelA:DLAttrFlag(attr, BMDDeckLinkSupportsSMPTELevelAOutput)
                                          dual:DLAttrFlag(attr, BMDDeckLinkSupportsDualLinkSDI)
                                          quad:DLAttrFlag(attr, BMDDeckLinkSupportsQuadLinkSDI)];
  if (attr) attr->Release();
  dl->Release();
  return caps;
}

- (void)dealloc {
  [self stop];
}

- (BOOL)startWithDeviceIndex:(NSInteger)deviceIndex
                   modeIndex:(NSInteger)modeIndex
                 pixelFormat:(DeckLinkPixelFormat)pixelFormat
                       range:(DeckLinkVideoRange)range
                        link:(DeckLinkSDILink)link
                      use444:(BOOL)use444
                      levelA:(BOOL)levelA
                  lowLatency:(BOOL)lowLatency
                    provider:(DeckLinkFrameProvider)provider
                       error:(NSError **)error {
  std::lock_guard<std::mutex> guard(_lock);
  if (_output) { if (error) *error = DLError(1, @"already running"); return NO; }

  IDeckLink *dl = DLDeviceAt(deviceIndex);
  if (!dl) { if (error) *error = DLError(2, @"device not found"); return NO; }
  IDeckLinkOutput *out = DLOutputFor(dl);
  if (!out) { dl->Release(); if (error) *error = DLError(3, @"device cannot output"); return NO; }

  IDeckLinkDisplayMode *mode = NULL;
  IDeckLinkDisplayModeIterator *modes = NULL;
  if (out->GetDisplayModeIterator(&modes) == S_OK && modes) {
    IDeckLinkDisplayMode *m = NULL;
    NSInteger i = 0;
    while (modes->Next(&m) == S_OK) {
      if (i++ == modeIndex) { mode = m; break; }
      m->Release();
    }
    modes->Release();
  }
  if (!mode) {
    out->Release(); dl->Release();
    if (error) *error = DLError(4, @"display mode not found");
    return NO;
  }

  const BMDPixelFormat bmdFmt = DLBMDFormat(pixelFormat);
  bool supported = false;
  BMDDisplayMode actual;
  out->DoesSupportVideoMode(bmdVideoConnectionUnspecified, mode->GetDisplayMode(), bmdFmt,
                            bmdSupportedVideoModeDefault, &actual, &supported);
  if (!supported) {
    mode->Release(); out->Release(); dl->Release();
    if (error) *error = DLError(5, @"device rejects this mode and pixel format");
    return NO;
  }

  // Signal configuration must be set BEFORE enabling output: these change the wire format, and the
  // driver latches them when the output is enabled. Failures are not fatal, since a device that does
  // not implement a key simply cannot honour it; the menu only offers keys it accepted when probed.
  // The configuration object must stay alive for the whole session. Releasing it reverts every key
  // to the stored Desktop Video preference, so writing and releasing here left the card on its saved
  // settings and made this menu look inert. Held until stop, released after the output is disabled.
  _config = DLConfigFor(dl);
  if (_config) {
    _config->SetInt(bmdDeckLinkConfigSDIOutputLinkConfiguration, DLBMDLink(link));
    _config->SetFlag(bmdDeckLinkConfig444SDIVideoOutput, use444 ? true : false);
    _config->SetFlag(bmdDeckLinkConfigSMPTELevelAOutput, levelA ? true : false);
  }

  if (out->EnableVideoOutput(mode->GetDisplayMode(), bmdVideoOutputFlagDefault) != S_OK) {
    if (_config) { _config->Release(); _config = NULL; }
    mode->Release(); out->Release(); dl->Release();
    if (error) *error = DLError(6, @"could not open the device for output (in use by another app?)");
    return NO;
  }

  const long w = mode->GetWidth(), h = mode->GetHeight();
  BMDTimeValue frameDuration = 0; BMDTimeScale timeScale = 0;
  mode->GetFrameRate(&frameDuration, &timeScale);
  const double fps = frameDuration ? double(timeScale) / double(frameDuration) : 0.0;
  const long rowBytes = DLRowBytes(bmdFmt, w);

  // The pool must be LARGER than kTargetDepth. Preroll schedules kTargetDepth frames, and whatever
  // is left over is what the worker has to pack into; if the two were equal the worker would start
  // with nothing free, could never produce a frame, and every completion would repeat forever.
  const int poolSize = int(kTargetDepth) + 4;
  std::vector<IDeckLinkMutableVideoFrame *> pool;
  for (int i = 0; i < poolSize; i++) {
    IDeckLinkMutableVideoFrame *f = NULL;
    if (out->CreateVideoFrame(int32_t(w), int32_t(h), int32_t(rowBytes), bmdFmt,
                              bmdFrameFlagDefault, &f) != S_OK || !f) {
      for (auto *p : pool) p->Release();
      out->DisableVideoOutput();
      if (_config) { _config->Release(); _config = NULL; }
      mode->Release(); out->Release(); dl->Release();
      if (error) *error = DLError(7, @"could not allocate output frames");
      return NO;
    }
    pool.push_back(f);
  }

  _device = dl;
  _output = out;
  _pool = pool;
  _activeWidth = w;
  _activeHeight = h;
  _activeFPS = fps;

  if (lowLatency) {
    // Immediate display: no scheduler, no completion callback, no preroll. Three rotating frames
    // are plenty; DisplayVideoFrameSync replaces the on-air frame at the next refresh.
    std::vector<IDeckLinkMutableVideoFrame *> syncPool(pool.begin(), pool.begin() + 3);
    _sync = new SyncDisplayer(out, provider, w, h, bmdFmt, range, syncPool);
    mode->Release();
    _running = YES;
    return YES;
  }

  _feeder = new Feeder(out, provider, w, h, bmdFmt, range, frameDuration, timeScale, pool);
  out->SetScheduledFrameCompletionCallback(_feeder);

  // Preroll is pure output latency: every prerolled frame sits in the card's scheduler ahead of
  // the live picture. FFmpeg's muxer defaults to half a second, which is right for file playout but
  // wrong for monitoring, where the whole point is to see what is happening now. kTargetDepth is
  // the compromise (~200 ms at 29.97, ~100 ms at 59.94).
  _feeder->startAndPreroll();
  if (out->StartScheduledPlayback(0, timeScale, 1.0) != S_OK) {
    mode->Release();
    [self stopLocked];
    if (error) *error = DLError(8, @"could not start scheduled playback");
    return NO;
  }

  mode->Release();
  _running = YES;
  return YES;
}

- (void)stop {
  std::lock_guard<std::mutex> guard(_lock);
  [self stopLocked];
}

/// Teardown; caller holds _lock.
- (void)stopLocked {
  if (!_output) return;
  if (_sync) {
    _sync->stop();
    _scheduledFrames = NSInteger(_sync->displayed());
    delete _sync;
    _sync = NULL;
    _output->DisableVideoOutput();
  } else {
  if (_feeder) _feeder->stop();
  BMDTimeValue stopped = 0;
  _output->StopScheduledPlayback(0, &stopped, 1000);
  _output->SetScheduledFrameCompletionCallback(NULL);
  _output->DisableVideoOutput();
  }

  if (_feeder) {
    _scheduledFrames = NSInteger(_feeder->scheduled());
    _lateFrames = _feeder->late();
    _droppedFrames = _feeder->dropped();
    _resyncCount = _feeder->resyncs();
    _repeatCount = _feeder->repeats();
    delete _feeder;
    _feeder = NULL;
  }
  for (auto *p : _pool) p->Release();
  _pool.clear();
  _output->Release();
  _output = NULL;
  // After the output is disabled, not before: releasing this reverts the wire settings.
  if (_config) { _config->Release(); _config = NULL; }
  if (_device) { _device->Release(); _device = NULL; }
  _running = NO;
}

- (NSInteger)scheduledFrames {
  if (_sync) return NSInteger(_sync->displayed());
  return _feeder ? NSInteger(_feeder->scheduled()) : _scheduledFrames;
}

- (void)displayNow {
  if (_sync) _sync->notify();
}
- (NSInteger)lateFrames { return _feeder ? _feeder->late() : _lateFrames; }
- (NSInteger)droppedFrames { return _feeder ? _feeder->dropped() : _droppedFrames; }
- (NSInteger)resyncCount { return _feeder ? _feeder->resyncs() : _resyncCount; }
- (NSInteger)repeatCount { return _feeder ? _feeder->repeats() : _repeatCount; }

@end
