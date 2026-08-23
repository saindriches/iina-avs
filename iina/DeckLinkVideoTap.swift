//
//  DeckLinkVideoTap.swift
//  iina
//
//  Gets mpv's rendered picture out to the DeckLink feeder.
//
//  IINA renders through the libmpv OpenGL render API into its CAOpenGLLayer. This taps the same
//  render context for a SECOND pass into an offscreen FBO sized to the SDI mode, reads it back, and
//  publishes the pixels for the card's frame-completion thread to collect. Rendering at the mode's
//  own size means a 4K or 8K source is downscaled by mpv's own scaler on the way in, which is both
//  cheaper and better than reading back a full-size surface, and it sidesteps the exact-mode
//  matching that constrains FFmpeg's decklink muxer.
//
//  Threading: `capture` runs on IINA's GL thread (inside ViewLayer.draw, where the context is
//  current). `copyLatest` runs on whichever worker thread the active output path owns. They meet
//  only through `published` under `lock`, so no GL call ever happens off the GL thread.
//
//  Limitation: capture is driven by the display refresh, not the card clock, so the two rates are
//  reconciled by latest-frame-wins. Card-clocked rendering would need a shared GL context on a
//  dedicated thread, which would also make output independent of the window being drawn at all.
//

import Cocoa
import OpenGL.GL
import OpenGL.GL3

final class DeckLinkVideoTap {

  /// Size the SDI output wants. Set when routing starts; nil disables capture entirely.
  private var targetWidth = 0
  private var targetHeight = 0
  /// How far apart samples should be: the mode's frame rate, or its FIELD rate when weaving. With a
  /// 60 Hz panel feeding 23.98 SDI there is no point paying for a readback per screen refresh.
  private var sampleInterval: CFTimeInterval = 0
  /// When the next sample is ideally due. See `shouldSample`.
  private var nextSampleAt: CFTimeInterval = 0
  /// Smoothed interval between draw hooks, so the gate can tell a fast draw loop from a scarce one.
  private var hookIntervalEMA: CFTimeInterval = 0
  private var lastHookAt: CFTimeInterval = 0

  /// True interlace: the two fields of a frame must be DIFFERENT moments, 1/fieldRate apart, which
  /// is what a CRT's scan actually shows. PsF is the other case and needs none of this, because both
  /// its fields are one instant by definition.
  ///
  /// So when this is on we sample at the FIELD rate and keep alternate lines of each sample, then
  /// publish once a pair is complete. Line-dropping is the correct spatial sampling here: even lines
  /// are exactly where the first field's scan sits, odd lines the second's.
  private var weaveFields = false
  /// Which field is transmitted first, and so carries the earlier sample.
  private var upperFieldFirst = true

  /// The source frames already contain both fields, so hand them over untouched.
  ///
  /// Every other mode here BUILDS an interlaced frame out of progressive samples. This one must
  /// build nothing: the two moments are already interleaved in the rows, and anything that mixes
  /// rows destroys them. So no weaving, no cadence, no filter, and no vertical resampling upstream
  /// either, which is the one precondition the tap cannot enforce for itself.
  var sourceInterlaced = false

  /// Whether the frames mpv is handing over are themselves interlaced, whatever mode we are in.
  ///
  /// Not the same thing as `sourceInterlaced` above, which is a MODE. This is a FACT about the
  /// content, and the cadence needs it: the cadence's whole model is that one source frame is one
  /// instant, which is true of progressive material and false here, where the alternate lines of a
  /// single frame are already two instants. Pairing a field of one such frame with a field of the
  /// next welds two different pictures into one raster.
  ///
  /// mpv publishes it per frame and the controller polls it; nothing in the cadence path had ever
  /// been told.
  var sourceFramesInterlaced = false
  /// SD line placement, for 525-line only. Zero when it does not apply.
  ///
  /// DeckLink's NTSC raster is 720x486, the full BT.601 active picture, while almost every file is
  /// 720x480 because DV and MPEG-2 drop six lines. Fitting one to the other by SCALING resamples
  /// vertically and averages each line with the other field, which for a pass-through destroys the
  /// thing being passed through. Broadcast practice is to place the 480 lines in the 486 raster
  /// untouched and blank the rest, four lines at the top and two at the bottom.
  ///
  /// The offset has to be EVEN or every source line changes field, which inverts the field order
  /// silently. That is why centring is wrong here: six halves to three.
  private var placedHeight = 0
  private var placedTopOffset = 0

  /// Height mpv should render at, so it is never asked to scale into the taller raster.
  var renderHeightOverride: Int { placedHeight }

  func setLinePlacement(sourceHeight: Int, rasterHeight: Int) {
    lock.lock()
    defer { lock.unlock() }
    // Not a pass-through concept, which is how it was gated at first. Any interlaced raster has the
    // same problem: resampling 480 lines into 486 averages each line with its neighbour, and in an
    // interlaced raster the neighbour is the OTHER field, so the two moments are blended before
    // anything downstream can separate them. A 640x480 file into 525i was being scaled vertically
    // for exactly this reason, in the one mode that cares most.
    //
    // Only for a source whose active lines ARE the raster's, give or take a convention. Six lines is
    // 480 in 486; three hundred is a picture that wants scaling up, and placing it would leave it
    // small in the middle of a black frame. Sixteen is comfortably above every real convention and
    // far below any case where scaling is what was meant.
    guard sourceHeight > 0, sourceHeight < rasterHeight, rasterHeight - sourceHeight <= 16 else {
      placedHeight = 0
      placedTopOffset = 0
      return
    }
    placedHeight = sourceHeight
    let difference = rasterHeight - sourceHeight
    // Round the half up to the next even line: 6 becomes 4, which is the broadcast convention for
    // 480 in 486, and evenness is what keeps each line on the field it started on.
    placedTopOffset = ((difference / 2) + 1) & ~1
  }

  /// What the panel should say about it.
  var linePlacement: (height: Int, top: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (placedHeight, placedTopOffset)
  }

  /// Shift the picture one line, exchanging which rows land in which field. The only lever there is
  /// when the source was encoded with the opposite dominance to the raster, since the fields are
  /// already committed to their lines and nothing else can reorder them.
  var swapSourceFields = false
  /// 0 = waiting for the earlier field, 1 = waiting for the later one.
  private var fieldParity = 0

  // MARK: - film cadence (2:3 pulldown)

  /// Lay 23.976 film onto a 59.94-field raster as broadcast does, instead of resampling whatever
  /// the window happens to be showing.
  ///
  /// The rates do not divide: 59.94 fields over 23.976 frames is exactly 2.5 fields per frame, so
  /// each film frame has to occupy 3 fields then 2, forever. Sampling the display cannot produce
  /// that reliably, because our sample instants, mpv's presentation grid and the card's field clock
  /// are three different clocks; the cadence comes out approximately right but wanders, which is
  /// uneven judder.
  ///
  /// So generate it instead. Field slot i shows source frame floor(i * 0.4), which lands the two
  /// fields of the five output frames in a cycle as:
  ///
  ///     frame 0: (S0, S0)   clean
  ///     frame 1: (S0, S1)   two film frames in one raster, as telecine sends
  ///     frame 2: (S1, S2)   likewise
  ///     frame 3: (S2, S2)   clean
  ///     frame 4: (S3, S3)   clean
  ///
  /// which is 3:2:3:2 fields per film frame. Composition happens in `copyLatest`, on the card's own
  /// clock, so the cadence on the wire is exactly regular however ragged our capture was.
  ///
  /// It is also the cheaper path: four film frames per five output frames is 23.976 readbacks a
  /// second rather than 59.94, and the fields are assembled with the row copies the feeder was
  /// doing anyway.
  ///
  /// Needs a consumer that ticks at the OUTPUT rate, since the whole point is emitting more frames
  /// than the source has. Both paths now do: the scheduled feeder is bounded by the card's
  /// completions, and the sync displayer follows the card's hardware reference clock.
  private var filmCadence = false
  /// Frame rate mpv reports for the file. Zero when unknown.
  private var sourceFrameRate: Double = 0
  /// Field rate of the mode, for the cadence and the weaving checks. Only the FIELD rate while
  /// weaving; without weaving there is one sample per frame and this holds the frame rate, which is
  /// why anything wanting the frame rate must use `frameRate` and not halve this.
  private var fieldRate: Double = 0
  /// The mode's frame rate, always. Kept separately because deriving it from `fieldRate` is only
  /// correct in one of the two cases, and getting that wrong halved the pass-through sample rate.
  private var frameRate: Double = 0

  /// Film frames waiting to be shown, oldest first, and buffers to read the next one back into.
  ///
  /// A QUEUE rather than a single slot, because the scheduled worker does not call the frame
  /// provider at the card's rate. It fills every free buffer it can get back to back, so provider
  /// calls arrive in bursts of up to poolSize minus the card's queue depth, four in practice. With
  /// one slot a burst found a fresh film frame for its first call and nothing for the rest, so the
  /// cycle held three times running and then idled: the cadence stopped being 3:2 and stuttered.
  /// Consumption still averages the card's rate, so a queue this deep simply lets a burst take real
  /// frames and the pattern survive.
  private var filmReady = [[UInt8]]()
  private var filmSpare = [[UInt8]]()
  /// How deep the queue is allowed to get, which is bought entirely in latency.
  ///
  /// Four is what the SCHEDULED worker needs, because it fills every free buffer back to back and
  /// its bursts reach that. The card-paced path has no bursts at all, one provider call per output
  /// frame, so four there is three frames of delay for nothing: measured at 164 ms against 33 ms for
  /// the modes that do not queue. Sized to the consumer instead of to the worst consumer.
  private var filmQueueDepth = 4
  /// Bounds for the adaptive depth, and how long a clean run has to be before it gives one back.
  private var filmQueueFloor = 2
  private static let filmQueueCeiling = 4
  /// Slow average of queue occupancy, for telling a sudden dip from a steady drain.
  private var occupancyEMA: Double = 0
  private static let cleanRunToShrink = 1800   // roughly a minute of output frames
  /// Lowest occupancy seen during the current clean run. Shrinking without knowing this was
  /// guesswork: giving a frame back when the queue had been touching empty simply bought the next
  /// hold, which is a plausible reading of holds arriving steadily about once a minute.
  private var minOccupancySinceHold = Int.max
  private var framesSinceHold = 0

  /// Source frames consumed, and whether the count has been left odd by a hold.
  ///
  /// When the source arrives at the field rate, an output frame consumes exactly TWO moments: the
  /// earlier one to the rows the card sends first, the later one to the rows it sends second. A
  /// hold consumes one, so every pairing after it is offset by one and each moment lands on the
  /// OPPOSITE spatial field to the one it belongs on. For material whose successive frames are
  /// alternating original fields that is an inverted field order, and it persists until the next
  /// hold flips it back, which is exactly the once-a-minute rhythm this shows.
  ///
  /// Resetting the phase does not repair it: the phase says when to pull, not how many have been
  /// pulled. Parity has to be restored explicitly, by consuming one extra frame at the next chance.
  /// That costs a single dropped moment against an inversion that would otherwise last a minute.
  private var sourceConsumed = 0
  private var pairingNeedsCatchUp = false
  /// Which parity of the consumed count is the RIGHT one.
  ///
  /// Locking to even was wrong on its own: nothing here can know which of the two pairings the
  /// content wants, so a lock that always chooses even makes a wrong start permanent, where before
  /// it would at least have flipped back eventually. The choice belongs to whoever can see the
  /// picture, so Field Order selects it and the lock then holds whatever was selected.
  private var pairingParityTarget: Int { swapSourceFields ? 1 : 0 }
  /// Only meaningful when two source frames make one output frame. Other ratios have no fixed
  /// pairing parity to preserve, so forcing one would drop frames for nothing.
  private var pairingParityMatters: Bool { abs(cadenceRatioLocked - 1.0) < 0.02 }
  private var current = [UInt8]()
  private var previous = [UInt8]()
  /// Whether the one line shift is actually being applied, as opposed to merely asked for. The two
  /// differ whenever the chosen source order already matches the raster, and the status line was
  /// reporting the request rather than the result.
  var isSwappingFields: Bool { swapSourceFields }

  /// Frames handed to the card that were the same picture as the one before.
  ///
  /// Nothing counted these on the low latency path, so a repeat was invisible in the stats. It is
  /// the expected cost of two unlocked clocks: our capture follows the Mac's display and mpv, the
  /// card follows its own crystal, and 0.1% between them is a duplicate every seventeen seconds or
  /// so. Harmless in PsF, where it is one frame of hesitation in progressive content, and obvious
  /// in a real field-rate picture, where it stalls two fields of genuine motion.
  private(set) var duplicatesOut = 0
  /// Bumped whenever a genuinely new picture is published, so the consumer can tell a fresh frame
  /// from the same one handed out twice.
  private var publishSerial = 0
  private var lastHandedSerial = -1

  /// Times the cycle wanted a film frame and had none. Should sit at zero: anything else means
  /// capture is not keeping up with the card and the cadence is being held rather than run.
  private(set) var cadenceHolds = 0
  /// Fractional position between source frames, advanced one field slot at a time.
  ///
  /// Field slot i shows source frame floor(i * ratio). Keeping the fraction and watching it wrap is
  /// the same thing without an unbounded counter, and it generalises: at 0.4 it reproduces exactly
  /// the 2:3 table this replaced, at 0.834 the 5:6 that 50p into 59.94i needs, at 1.0 a new frame
  /// every field, which is plain field-rate interlace.
  private var cadenceAcc: Double = 0

  /// The source rate to plan against, which is not always the one mpv reports.
  ///
  /// A soft telecined file holds 23.976 progressive frames plus flags saying which occupy three
  /// field times, and container-fps commonly reports the DISPLAY rate those flags produce, 29.97,
  /// rather than the 23.976 frames actually delivered. Believing that makes the cadence plan a flat
  /// 2:2 for a stream that needs 3:2, and the frames that never arrive come out as holds: repeats
  /// at irregular intervals, which is worse judder than the clean 24p file it should have matched.
  ///
  /// The draw loop cannot lie about this. It runs when mpv has a new frame, so its rate is the
  /// number of distinct moments actually on offer, and we can never build more than that however
  /// many the container claims. Taking the lower of the two is therefore correct by construction
  /// rather than a heuristic.
  ///
  /// Guarded on both sides: only believed when it is materially lower and not absurdly so, since a
  /// window that is occluded or a machine that is briefly busy should not rewrite the cadence.
  private var effectiveSourceRateLocked: Double {
    guard sourceFrameRate > 0 else { return sourceFrameRate }
    guard hookIntervalEMA > 0 else { return sourceFrameRate }
    // Not until the draw loop has been running long enough to be worth believing.
    //
    // This is what produced a session that never had the right field order. On a RE-ARM the average
    // draw interval carries whatever the window was doing while it started, so the observed rate
    // reads far too low; the ratio was then latched from it and stayed wrong for the whole session.
    // A trace caught it at 0.4041 instead of a half, which is 24.2 fps for a 29.97 file, and at
    // that ratio the wrap lands on the leading step and every frame mixes two moments. Restarting
    // re-latched it, which is why another restart appeared to fix it.
    //
    // Ten seconds of draws is plenty to tell soft telecine from a window that has just woken up,
    // and the reported rate is the right answer in the meantime.
    guard hookCalls >= 300 else { return sourceFrameRate }
    let observed = 1.0 / hookIntervalEMA
    guard observed < sourceFrameRate * 0.95, observed > sourceFrameRate * 0.2 else {
      return sourceFrameRate
    }
    return observed
  }

  /// What the panel should show when the two disagree, so the reason is visible rather than magic.
  var reportedVersusObserved: (reported: Double, effective: Double) {
    lock.lock()
    defer { lock.unlock() }
    return (sourceFrameRate, effectiveSourceRateLocked)
  }

  /// Source frames per field slot, never above 1: a source cannot supply more distinct moments than
  /// it has frames. Caller holds `lock`.
  private var cadenceRatioLocked: Double { cadenceRatioCache }

  /// Latched, and snapped to the simple fraction it is obviously trying to be.
  ///
  /// Two faults, both visible in a trace. It was recomputed from a LIVE measurement on every step,
  /// so the ratio jittered and the accumulator wandered into arbitrary phases: 0.3066 and 0.4223
  /// were recorded, nowhere near the half this content means. And the raw quotient is never exact,
  /// because mpv reports 29.970029830932617 for a 30000/1001 file while the card's field rate is
  /// the exact double, giving 0.4999999976 instead of a half.
  ///
  /// Every cadence worth having is a simple fraction: a half, two fifths for film, five twelfths
  /// for 25p, one for a matched source. So find the small fraction the measurement is within a
  /// thousandth of and use that instead. The accumulator then lands exactly where the arithmetic
  /// says, which is what stops the wrap sliding onto the wrong step.
  private var cadenceRatioCache: Double = 1
  private func refreshCadenceRatioLocked() {
    guard fieldRate > 0 else { cadenceRatioCache = 1; return }
    let raw = min(1.0, effectiveSourceRateLocked / fieldRate)
    for denominator in 1...12 {
      let numerator = (raw * Double(denominator)).rounded()
      guard numerator >= 1 else { continue }
      let candidate = numerator / Double(denominator)
      // Tight on purpose. This exists to remove float slop, not to round a rate to a neater one:
      // at a thousandth it would pull 25p onto five twelfths and 50p onto five sixths, which are
      // the 60 Hz fractions, and against a 59.94 field rate that is a real error of a part in a
      // thousand rather than a tidying up. A hundred-thousandth catches the quotient noise and
      // nothing else.
      if abs(raw - candidate) < 1e-5 { cadenceRatioCache = min(1.0, candidate); return }
    }
    cadenceRatioCache = raw
  }

  /// Whether the cadence can run: asked for, weaving, and a source no faster than the field rate.
  ///
  /// This used to demand exactly 2/5, which is film and nothing else. Every rate below the field
  /// rate has the same problem and the same answer, so the ratio is simply computed now. 50p into
  /// 59.94i is the case that showed it up: it fell out of the film test, took the whole-frame
  /// fallback, and published 50 frames a second at a card taking 29.97, so twenty of them a second
  /// were silently never shown and which twenty was arbitrary.
  private var cadenceEngagedLocked: Bool {
    guard !sourceInterlaced, filmCadence, weaveFields, sourceFrameRate > 0, fieldRate > 0 else { return false }
    return effectiveSourceRateLocked <= fieldRate * 1.01
  }

  /// One source frame makes exactly one output frame, so both fields are the same moment.
  ///
  /// The pivot for two separate rules, which is why it is named once rather than tested twice: it is
  /// the only ratio where the phase has to be anchored to the frame boundary, and the only one where
  /// a frame carrying two moments is a fault rather than the cadence doing its job.
  private var cadenceIsOneToOne: Bool { abs(cadenceRatioLocked - 0.5) <= 0.001 }

  /// Advance one field slot. True when the slot crosses into the next source frame.
  private func stepCadenceSlot() -> Bool {
    cadenceAcc += cadenceRatioLocked
    // Tolerance, because the ratio is a quotient of two measured rates and lands a hair under the
    // exact fraction it means. mpv reports 29.970029830932617 for a 30000/1001 file, rounded
    // through a float somewhere, and the card's field rate is the exact double: the ratio is then
    // 0.4999999976 rather than a half, two steps sum to 0.9999999953, and the trailing step MISSES
    // its wrap. The wrap slides onto the next frame's leading step and stays there, so every frame
    // afterwards pairs two different moments. Measured in a trace: 1162 mixed frames in one run,
    // ending only when a hold happened to reset the phase.
    //
    // A part in a million is far below any real cadence difference and far above the slop.
    guard cadenceAcc >= 1.0 - 1e-6 else { return false }
    cadenceAcc -= 1.0
    return true
  }

  // MARK: - trace ring

  /// One record per interesting moment, kept in a fixed ring so the minutes BEFORE an event survive.
  ///
  /// Cumulative counters say a thing happened; they cannot say what the state was when it did. The
  /// faults left here are transitions, so what is needed is the sequence around one, and the only
  /// person who can see the event is looking at a CRT with a second or two of reaction time. Hence
  /// a ring plus a button: press after it happens and the window leading up to it is already
  /// captured.
  ///
  /// Always on. One array store per frame, no allocation, nothing to enable and forget.
  struct TraceRecord {
    var time: Double = 0
    var kind: UInt8 = 0        // 1 compose, 2 capture, 3 handout
    var flags: UInt8 = 0       // 1 hold, 2 mixed, 4 dup, 8 catch-up, 16 pulled on leading step
    var queue: UInt16 = 0
    var phase: Float = 0
    var consumed: Int32 = 0
    var fieldA: Int32 = 0      // source index into the field sent FIRST
    var fieldB: Int32 = 0
    /// Speed trim in ppm at the time of the record, so the servo is visible next to what it is
    /// steering. Without it a queue excursion cannot be told from the correction chasing it.
    var trimPPM: Int32 = 0
  }
  private var trace = [TraceRecord](repeating: TraceRecord(), count: 8192)
  private var traceHead = 0

  /// Set by the controller each tick, purely so the trace can show it.
  var reportedTrimPPM: Int32 = 0

  private func record(kind: UInt8, flags: UInt8, fieldA: Int32 = -1, fieldB: Int32 = -1) {
    trace[traceHead % trace.count] = TraceRecord(
      time: CACurrentMediaTime(), kind: kind, flags: flags,
      queue: UInt16(min(filmReady.count, Int(UInt16.max))), phase: Float(cadenceAcc),
      consumed: Int32(truncatingIfNeeded: sourceConsumed), fieldA: fieldA, fieldB: fieldB,
      trimPPM: reportedTrimPPM)
    traceHead &+= 1
  }

  /// Oldest first, as CSV. Taken under the lock so it cannot tear against the GL or feeder threads.
  /// Oldest first, fixed width so a row never wraps and the columns line up when read as text.
  ///
  /// Still comma separated, so awk and spreadsheets take it, but padded: a trace is read by eye far
  /// more often than by a parser. Five separate zero-or-one columns for the flags were both wide
  /// and hard to scan, so they collapse to one letter each.
  ///
  /// Ordered the way a frame travels: when it happened, what happened, how deep the queue was,
  /// where the cadence phase sat, and which source frames landed in which field. The trim comes
  /// last because it is context for the rest rather than part of the event.
  ///
  /// Taken under the lock so it cannot tear against the GL or feeder threads.
  func traceCSV() -> String {
    lock.lock()
    defer { lock.unlock() }
    var out = "       t, knd, flg,  q,  phase, consumed, fldA, fldB,  trim\n"
    let total = min(traceHead, trace.count)
    let first = traceHead >= trace.count ? traceHead % trace.count : 0
    let base = total > 0 ? trace[first].time : 0
    for i in 0..<total {
      let r = trace[(first + i) % trace.count]
      let kind = ["?", "cmp", "cap", "out"][Int(min(r.kind, 3))]
      // h hold, m mixed, d duplicate, c catch-up, L pull landed on the leading step
      var flags = ""
      if r.flags & 1 != 0 { flags += "h" }
      if (r.flags >> 1) & 1 != 0 { flags += "m" }
      if (r.flags >> 2) & 1 != 0 { flags += "d" }
      if (r.flags >> 3) & 1 != 0 { flags += "c" }
      if (r.flags >> 4) & 1 != 0 { flags += "L" }
      if flags.isEmpty { flags = "-" }
      let a = r.fieldA < 0 ? "-" : String(r.fieldA)
      let b = r.fieldB < 0 ? "-" : String(r.fieldB)
      out += String(format: "%8.3f, %3@, %3@, %2d, %6.4f, %8d, %4@, %4@, %5d\n",
                    r.time - base, kind as NSString, flags as NSString, Int(r.queue), r.phase,
                    Int(r.consumed), a as NSString, b as NSString, Int(r.trimPPM))
    }
    return out
  }

  /// Frames whose two fields came from DIFFERENT source frames.
  ///
  /// Counted only AT half the field rate, where one source frame per output frame means both fields
  /// are the same moment, so anything else means the phase has slipped and frames are being built
  /// from two different moments: for already-interlaced content that mixes two combed frames and
  /// reads exactly like an inverted field order. There it must be zero.
  ///
  /// Below a half two moments in one raster is the cadence working, not a fault, so those are left
  /// out rather than reported as a fault that needs no fixing.
  private(set) var mixedFrames = 0
  /// Output frames in a row that took no source frame. Only interesting when it runs longer than
  /// the ratio allows, which is the tell for a stalled cadence. See where it is checked.
  private var framesWithoutPull = 0
  /// Frames discarded because the queue was full. See the comment where it is incremented.
  private(set) var queueDrops = 0

  /// Move on to the next source frame, or record that there was not one to move to.
  private func pullCadenceFrame() {
    guard !filmReady.isEmpty else {
      cadenceHolds += 1
      record(kind: 1, flags: 1)
      // Do NOT refund the phase here. Adding a whole frame of it makes the very next slot re-wrap,
      // which moves the pull from the trailing step to the leading one: the frame then pairs two
      // different source moments, consumes two frames instead of one, drains the queue and causes
      // the next hold. Measured, that ran to 1794 holds and 2137 mixed frames out of 4151 sent.
      // The accumulator counts SLOTS, not frames, so 1.0 was the wrong unit to give back. Leaving
      // the phase alone costs a repeated frame and nothing else.
      // Grow. A hold means the cushion was too thin for how unevenly this source arrives: 50p on a
      // 60 Hz panel is held for one refresh then two, so its frames land with a field of jitter
      // either way, and two frames of queue cannot cover that. Sizing by measurement beats sizing
      // by guess, since the right depth depends on the source and the panel, not on us.
      // Grow only for a DIP, never for a DRAIN. Buffer is the cure for jitter and the wrong
      // medicine for a rate deficit: mpv follows the Mac's audio clock and the card follows its own
      // crystal, and a trace measured the queue sliding from 6 to 1 over 137 seconds, a deficit of
      // about a tenth of a percent. Against that, more buffer only postpones the same hold while
      // making the latency permanently worse, which is how this reached two hundred milliseconds.
      // A hold caused by a deficit is one repeated frame every half minute or so and is the honest
      // price; a hold caused by jitter is worth a frame of cushion.
      if occupancyEMA >= 1.5 {
        filmQueueDepth = min(Self.filmQueueCeiling, filmQueueDepth + 1)
      }
      if pairingParityMatters, sourceConsumed % 2 != pairingParityTarget {
        pairingNeedsCatchUp = true
      }
      // Re-anchoring the phase is right for an ISOLATED hold, where the cycle has genuinely lost
      // the source and would otherwise stay offset until someone toggled a setting. It is wrong
      // when holds are chronic, which was the case here at more than one a second: resetting that
      // often is its own disruption, on top of the starvation causing it.
      let isolated = framesSinceHold > 60
      framesSinceHold = 0
      minOccupancySinceHold = Int.max
      guard isolated else { return }
      // A hold means the cycle has lost its relationship with the source: it wanted the next frame
      // and there was not one. Carrying on leaves the phase wherever the stall happened to put it,
      // and since nothing pulls it back, a single hold can leave the pairing offset for good. That
      // is why re-arming the tap fixed the field order and why ANY setting that re-arms it worked,
      // the interline filter included, in either direction. Re-anchor here instead, so the cycle
      // recovers by itself rather than waiting for someone to toggle something.
      //
      // Only where one frame makes one frame, for the same reason the frame-start anchor is. There
      // an offset phase inverts the field order and the reset is free, since the two steps sum to
      // exactly one and land back where they started. Below a half nothing is inverted, because two
      // moments in a raster IS the pattern, so the reset fixes nothing and throws away whatever
      // phase had accumulated: measured on 23.98p, a hold discarded 0.6 of a slot and the next pull
      // came a frame late, leaving one source frame across five fields where 2:3 allows three.
      // Leaving the phase alone through a hold costs the one repeat the starvation already forced
      // and no more.
      if cadenceIsOneToOne { cadenceAcc = 0 }
      fieldParity = 0
      return
    }
    // A clean run means the cushion is larger than it needs to be, and every frame of it is latency
    // nobody asked for. Give one back, slowly, so it settles at the least that works.
    framesSinceHold += 1
    minOccupancySinceHold = min(minOccupancySinceHold, filmReady.count)
    // Fast on purpose. These coefficients used to give a time constant near seven seconds, which
    // put a second pole in the clock servo's loop: an integrating plant plus a laggy sensor
    // oscillates, and the predicted period, sqrt(gain over tau), came out around eighty seconds.
    // A trace showed exactly that, the queue swinging between one and two frames while the trim
    // swung between zero and fourteen hundred ppm, over an eighty-five second cycle.
    //
    // Half a second instead. The sensor then contributes no meaningful lag, the loop is a plain
    // integrator under proportional control, and that cannot oscillate at any stable gain. It is
    // still slow next to the queue it watches, so it does not pass frame-to-frame noise through.
    occupancyEMA = occupancyEMA * 0.94 + Double(filmReady.count) * 0.06
    // Only give a frame back with evidence that it was spare: the queue has to have kept something
    // in hand for the whole run. A run that merely avoided holding says nothing, since it may have
    // been reaching empty every time and getting away with it.
    // Never ran DRY is the evidence that matters, not "kept two in hand". Requiring more than one
    // never came true in practice, because a healthy queue touches one routinely: measured over
    // four thousand frames, depth one occurred 780 times and zero only four. So the depth grew on
    // every hold, reached the ceiling, and stayed there, which is around two hundred milliseconds
    // of latency that nothing could give back.
    if framesSinceHold >= Self.cleanRunToShrink, filmQueueDepth > filmQueueFloor,
       minOccupancySinceHold >= 1 {
      filmQueueDepth -= 1
      framesSinceHold = 0
      minOccupancySinceHold = Int.max
    }
    filmSpare.append(previous)
    previous = current
    current = filmReady.removeFirst()
    sourceConsumed &+= 1
  }

  var cadenceEngaged: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cadenceEngagedLocked
  }

  /// Weaving asked for on a source that cannot supply a moment per field.
  ///
  /// The draw loop runs when mpv has a new frame, so a 24 fps file offers 24 samples a second
  /// however fast the display refreshes. Pairing consecutive samples then puts two moments 41ms
  /// apart into fields that are meant to be 16.7ms apart, which is not interlace, just mangled
  /// timing. There are only 24 distinct moments a second in the source, so no amount of sampling
  /// can invent field-rate motion.
  ///
  /// The answer without the cadence is whole frames at the output rate: both fields one instant,
  /// which is PsF, sampled so that the drop or repeat is regular. It is strictly worse than the
  /// cadence, which keeps every source moment by spreading them over the fields, so it only applies
  /// when the cadence is off. Caller holds `lock`.
  private var weaveStarvedLocked: Bool {
    guard !sourceInterlaced, weaveFields, !cadenceEngagedLocked, sourceFrameRate > 0, fieldRate > 0 else { return false }
    return sourceFrameRate < fieldRate * 0.9
  }

  /// How long a captured picture waits inside the tap before the card can be handed it.
  ///
  /// Two contributions, both exact rather than guessed. The PBO ping-pong hides its GPU stall by
  /// mapping the PREVIOUS readback, which is one whole capture interval by construction. The
  /// cadence queue holds whatever it holds, at the source rate. Everything downstream of here is
  /// the card's and is measured from the driver.
  var pipelineDelay: Double {
    lock.lock()
    defer { lock.unlock() }
    var delay = 0.0
    if !immediateReadback { delay += sampleInterval }
    if cadenceEngagedLocked, sourceFrameRate > 0 {
      delay += Double(filmReady.count) / sourceFrameRate
    }
    return delay
  }

  /// Source frame rate as last reported, for the panel to judge the capture rate against.
  var sourceRate: Double {
    lock.lock()
    defer { lock.unlock() }
    return sourceFrameRate
  }

  /// Smoothed queue occupancy, which is the integral of the production error and therefore the
  /// only signal that already knows about every clock in the chain at once.
  var queueOccupancy: Double {
    lock.lock()
    defer { lock.unlock() }
    return occupancyEMA
  }

  /// Frames consumed by the cadence, cumulative. With `capturedFrames` this gives production and
  /// consumption over any window, which is the rate error measured rather than inferred.
  var consumedFrames: Int {
    lock.lock()
    defer { lock.unlock() }
    return sourceConsumed
  }

  /// The depth the queue is currently allowed to reach, so a servo can aim at something reachable.
  var queueDepthNow: Int {
    lock.lock()
    defer { lock.unlock() }
    return filmQueueDepth
  }

  var weaveStarved: Bool {
    lock.lock()
    defer { lock.unlock() }
    return weaveStarvedLocked
  }

  /// Apply a pairing change NOW rather than at the next hold.
  ///
  /// The parity target was only consulted when a hold happened, so flipping the field order did
  /// nothing until one did, and whether it then helped was down to which parity the count happened
  /// to be on. A control whose effect arrives minutes later, at random, is worse than no control.
  func requestParityRealign() {
    lock.lock()
    if pairingParityMatters, sourceConsumed % 2 != pairingParityTarget {
      pairingNeedsCatchUp = true
    }
    lock.unlock()
  }

  /// Whether the two fields of an output frame can hold DIFFERENT moments.
  ///
  /// They cannot at a ratio of exactly a half, and only there. One source frame per output frame
  /// with the phase anchored to the frame boundary means the pull always lands on the trailing
  /// step, so both fields come from the same frame and there is nothing for an order to reorder.
  ///
  /// BELOW a half is not the same thing, which is the mistake this used to make. Fewer source
  /// frames than output frames on AVERAGE does not put their boundaries on the output frame's
  /// boundaries: a boundary falls between the two fields with probability r, so exactly that
  /// fraction of frames pairs two moments. Simulated over the ratios that matter, mixed frames come
  /// out at 0.3003 for 18p, 0.4000 for 23.976p film, 0.4167 for 25p, and zero only at a half. A
  /// trace of an 18p file measured 91 of 291 built frames carrying two moments, which is 31%.
  ///
  /// So on film, the commonest cadence there is, the field order control was disabled on the 40% of
  /// frames where it is the only thing deciding which moment goes out first.
  ///
  /// An interlaced source makes it true at EVERY ratio, a half included: both fields come from one
  /// frame there, but that frame's alternate lines are two instants of its own, and which of them
  /// goes out first is precisely what the control decides.
  var cadencePairsDistinctMoments: Bool {
    lock.lock()
    defer { lock.unlock() }
    guard cadenceEngagedLocked else { return false }
    return sourceFramesInterlaced || !cadenceIsOneToOne
  }

  /// Distinct source moments in each output frame, or nil when it varies frame to frame.
  ///
  /// The question "is this really interlace" reduces to this number, and until now nothing answered
  /// it. One means the raster is a progressive frame carried in two fields, which is PsF whatever
  /// the mode is called. Two means the fields are separate instants and the output is interlace in
  /// the sense a CRT was built for. Nil is the telecine middle ground, where some frames carry two
  /// and some carry one, and quoting either would be a lie.
  ///
  /// Pass-through returns nil because the tap cannot see it: the two moments are inside the decoded
  /// frame as alternate lines, and only the decoder knows whether they are there. The controller
  /// answers that case from mpv.
  var momentsPerOutputFrame: Int? {
    lock.lock()
    defer { lock.unlock() }
    if sourceInterlaced { return nil }
    guard cadenceEngagedLocked else {
      // Without the cadence, either each capture is a field of its own (two draws, two moments) or
      // the starved fallback publishes whole frames (one).
      return (weaveFields && !weaveStarvedLocked) ? 2 : 1
    }
    // Always two on an interlaced source: every output frame is one source frame's own field pair,
    // and the cadence no longer splits it. That is the one configuration here where True Interlace
    // is interlace in the sense a CRT was built for, rather than PsF wearing its name.
    if sourceFramesInterlaced { return 2 }
    // One only AT a half, where the anchor pins every pull to the trailing step. Below it the
    // count varies frame to frame, at the ratio itself: 3 frames in 10 carry two moments at 18p and
    // 2 in 5 do on film. Quoting one there names the commonest frame and hides the other kind.
    if cadenceIsOneToOne { return 1 }
    if cadenceRatioLocked >= 1.0 - 0.001 { return 2 }
    return nil
  }

  /// Recompute the latched ratio. Safe to call repeatedly: it snaps, so a settled source gives the
  /// same answer every time.
  func refreshCadenceRatio() {
    lock.lock()
    refreshCadenceRatioLocked()
    updateSampleIntervalLocked()
    lock.unlock()
  }

  /// mpv's reported frame rate for the current file, which can change when the file does.
  func updateSourceFrameRate(_ fps: Double) {
    lock.lock()
    if abs(fps - sourceFrameRate) > 0.001 {
      sourceFrameRate = fps
      // This is what decides whether weaving runs at all, so a change to it can switch the mode
      // mid-pair. Start the next pair cleanly rather than half way through the previous one.
      fieldParity = 0
      refreshCadenceRatioLocked()
      updateSampleIntervalLocked()
      nextSampleAt = 0        // the sample rate changed with it, so restart the phase
    }
    lock.unlock()
  }

  // MARK: - test patterns

  /// Which pattern to draw, and how strongly.
  ///
  /// Drawn OVER the captured picture rather than instead of it, so `testOpacity` can dissolve
  /// between the two. That matters most for the geometry pattern: a safe-area box is only useful
  /// against the shot it is meant to contain, and on a CRT the overscan you are measuring is the
  /// overscan of real content. At full opacity it replaces, which is what the level and colour
  /// patterns want.
  var testPattern: DeckLinkTestPattern = .off
  var testOpacity: Double = 1.0
  /// Advances once per field written, or per source frame with the cadence running.
  private var testStep = 0

  /// 10-bit components into the packed 2:10:10:10 word the capture format uses. Alpha is set but
  /// nothing downstream reads it.
  private func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
    let clamp = { (v: Int) -> UInt32 in UInt32(max(0, min(1023, v))) }
    return (3 << 30) | (clamp(r) << 20) | (clamp(g) << 10) | clamp(b)
  }

  /// Write one pixel, mixing with what the capture put there.
  ///
  /// The lerp is done per 10-bit field with an integer weight, so the whole thing stays a handful
  /// of shifts and multiplies. Opaque short-circuits to a plain store, which is the common case.
  private func plot(_ dst: UnsafeMutablePointer<UInt32>, _ index: Int, _ colour: UInt32, _ weight: Int) {
    if weight >= 256 { dst[index] = colour; return }
    let under = dst[index]
    let inv = 256 - weight
    var out: UInt32 = 3 << 30
    for shift in [20, 10, 0] {
      let a = Int((under >> UInt32(shift)) & 0x3FF)
      let b = Int((colour >> UInt32(shift)) & 0x3FF)
      out |= UInt32((a * inv + b * weight) >> 8) << UInt32(shift)
    }
    dst[index] = out
  }

  /// Whether a readback has to go through `store` rather than straight into the published frame.
  ///
  /// The fast path exists to skip a whole-frame copy when there is genuinely nothing to do, and its
  /// test was "not assembling", which missed everything else `store` is responsible for. With Low
  /// Latency on, and that is the normal setting, PsF and pass-through took the fast path and lost:
  /// the test pattern, which is why it appeared to work only in True Interlace; the one-line field
  /// order shift, which the panel offers in pass-through and describes in its tooltip; and the row
  /// placement that puts 480 lines inside a 486 raster, which is very likely the NTSC picture
  /// sitting off centre until any toggle that happens to force this branch the other way.
  ///
  /// So the question is not "am I assembling" but "is anything I am responsible for going to
  /// happen". Caller holds `lock`.
  private var readbackNeedsStore: Bool {
    if weaveFields || interlineFilter { return true }
    if testPattern != .off { return true }
    if sourceInterlaced, placedHeight > 0 || swapSourceFields { return true }
    return false
  }

  /// Draw the selected pattern over rows of the buffer that this sample owns.
  ///
  /// `startRow`/`everyOtherRow` are the field being written, so a pattern lands only on the lines
  /// this sample is responsible for and weaving still works underneath it.
  private func drawTestPattern(_ base: UnsafeMutableRawPointer, width w: Int, height h: Int,
                               startRow: Int, everyOtherRow: Bool) {
    guard testPattern != .off, w > 0, h > 0 else { return }
    let dst = base.assumingMemoryBound(to: UInt32.self)
    let weight = max(0, min(256, Int(testOpacity * 256.0)))
    let stride = everyOtherRow ? 2 : 1

    // Row range this sample owns, as a helper so each pattern can stay a few lines.
    func forEachRow(_ body: (Int, UnsafeMutablePointer<UInt32>) -> Void) {
      var y = startRow
      while y < h { body(y, dst.advanced(by: y * w)); y += stride }
    }

    switch testPattern {
    case .off:
      return

    case .fieldOrder:
      // A bar advancing a fixed step every field. Nothing else separates a wrong field order from a
      // dropped field, a repeated frame or a wandering cadence: they all just look like bad motion.
      // Even sweep is correct, a back-step every other field is swapped fields, a stall and jump is
      // repetition. See the release notes for build 20.
      let barWidth = max(8, w / 60)
      let travel = max(1, w / 48)
      let x0 = (testStep * travel) % max(1, w - barWidth)
      let ground = rgb(64, 64, 64)
      let mark = rgb(1023, 1023, 1023)
      forEachRow { _, row in
        for x in 0..<w { plot(row, x, (x >= x0 && x < x0 + barWidth) ? mark : ground, weight) }
      }

    case .geometry:
      // Crosshatch, centre cross, a circle and the two safe-area boxes. On a CRT this is the one
      // that earns its keep: geometry and linearity are adjustable and drift, the circle shows
      // whether the pixel aspect survived the chain, and the boxes show how much the tube is
      // actually eating. Overlaid at partial opacity it can be judged against real content.
      let line = rgb(1023, 1023, 1023)
      let boxAction = rgb(1023, 900, 0)
      let boxTitle = rgb(1023, 300, 300)
      let stepX = max(16, w / 16), stepY = max(16, h / 12)
      let cx = w / 2, cy = h / 2
      let radius = min(w, h) / 2 - 2
      // 90% action safe, 80% title safe, the usual broadcast pair.
      let a0x = w / 20, a1x = w - w / 20, a0y = h / 20, a1y = h - h / 20
      let t0x = w / 10, t1x = w - w / 10, t0y = h / 10, t1y = h - h / 10
      forEachRow { y, row in
        let onActionEdge = (y == a0y || y == a1y - 1)
        let onTitleEdge = (y == t0y || y == t1y - 1)
        // Circle: solve for x at this row, and mark both sides.
        let dy = y - cy
        let inCircle = abs(dy) <= radius
        let halfChord = inCircle ? Int((Double(radius * radius - dy * dy)).squareRoot()) : 0
        for x in 0..<w {
          if x % stepX == 0 || y % stepY == 0 || x == cx || y == cy {
            plot(row, x, line, weight)
          }
          if inCircle, abs(abs(x - cx) - halfChord) < 1 { plot(row, x, line, weight) }
          if (onActionEdge && x >= a0x && x < a1x) || (x == a0x || x == a1x - 1) && y >= a0y && y < a1y {
            plot(row, x, boxAction, weight)
          }
          if (onTitleEdge && x >= t0x && x < t1x) || (x == t0x || x == t1x - 1) && y >= t0y && y < t1y {
            plot(row, x, boxTitle, weight)
          }
        }
      }

    case .twitter:
      // Single-line detail, which is exactly what interline twitter destroys: on an interlaced CRT
      // each of these lines is drawn by only one field, so it flickers at half the field rate.
      // Turning the Interline Filter on should visibly calm it, and this is the honest way to see
      // what that filter costs in vertical resolution.
      let bright = rgb(1023, 1023, 1023)
      let dark = rgb(0, 0, 0)
      forEachRow { y, row in
        let colour = (y % 2 == 0) ? bright : dark
        // Left half single-line, right half two-line pairs, so the difference is visible together.
        let paired = ((y / 2) % 2 == 0) ? bright : dark
        for x in 0..<w { plot(row, x, x < w / 2 ? colour : paired, weight) }
      }

    case .greyscale:
      // An eleven step staircase over a black-level strip. The strip is what sets brightness on a
      // CRT: raise it until the lightest of the three patches is just visible and the darkest is
      // not. There is no sub-black patch, deliberately, because SMPTE mapping happens in the packer
      // and nothing generated here can land below the black point to begin with.
      let steps = 11
      let bandTop = h * 2 / 3
      forEachRow { y, row in
        if y < bandTop {
          let level = (y * 0) + 0   // staircase varies with x only
          _ = level
          for x in 0..<w {
            let stepIndex = min(steps - 1, x * steps / w)
            let v = stepIndex * 1023 / (steps - 1)
            plot(row, x, rgb(v, v, v), weight)
          }
        } else {
          for x in 0..<w {
            // black, +2%, +4%, repeating across the width
            let patch = (x * 6) / w
            let v = [0, 20, 41, 0, 20, 41][min(5, patch)]
            plot(row, x, rgb(v, v, v), weight)
          }
        }
      }

    case .colourBars:
      // 75% bars, the standard reference for chroma and for checking that 4:4:4 and the levels
      // setting are doing what they claim.
      let c = 767
      let bars = [rgb(c, c, c), rgb(c, c, 0), rgb(0, c, c), rgb(0, c, 0),
                  rgb(c, 0, c), rgb(c, 0, 0), rgb(0, 0, c), rgb(0, 0, 0)]
      forEachRow { _, row in
        for x in 0..<w { plot(row, x, bars[min(bars.count - 1, x * bars.count / w)], weight) }
      }
    }
  }

  /// Vertical low-pass before the lines are split into fields.  /// Vertical low-pass before the lines are split into fields.
  ///
  /// A CRT draws alternate lines in alternate fields, so any detail that lives on a single line
  /// appears at the field rate rather than the frame rate and shimmers: interline twitter, worst on
  /// titles and hard horizontal edges. Broadcast practice band-limits vertically before interlacing,
  /// which is what this does. It costs real vertical resolution, so it is opt-in and off by default,
  /// and it never applies to a progressive raster where there is nothing to twitter.
  private var interlineFilter = false

  private var fbo: GLuint = 0
  private var texture: GLuint = 0
  /// The GL context `fbo`/`texture`/`pbos` were created in. Handles are only meaningful there.
  private var glContext: CGLContextObj?
  private var allocatedWidth = 0
  private var allocatedHeight = 0
  /// Ping-ponged pixel buffer objects: glReadPixels into one (returns immediately, the GPU fills it
  /// in the background) while mapping the one filled last time. Costs one frame of latency and
  /// removes the pipeline stall that a synchronous readback causes.
  /// A square-pixel staging buffer, shaped like the SOURCE, for anamorphic rasters.
  ///
  /// mpv cannot letterbox correctly into a raster whose pixel count is not its shape, and it has no
  /// way to be told the difference. Giving it a canvas of the source's own shape means it fills that
  /// edge to edge and adds no bars of its own, which leaves every geometric decision here, where the
  /// raster's real shape is known. One extra blit, on SD, which is nothing.
  private var canvasFBO: GLuint = 0
  private var canvasTexture: GLuint = 0
  private var canvasWidth = 0
  private var canvasHeight = 0
  private var pbos: [GLuint] = [0, 0]
  private var pboIndex = 0
  private var pboPrimed = false

  // MARK: - geometry

  /// How a picture of a different shape is mapped onto the SDI raster.
  var scaling: DeckLinkScaling = .fit

  /// The source's shape as it is meant to be seen, its own pixel aspect included. 0 when unknown.
  var sourceAspect: Double = 0

  /// The shape the raster is meant to be SEEN as, or 0 to take the pixel grid at its word.
  ///
  /// Set for anamorphic rasters only, which in practice means SD. See the controller for how it is
  /// resolved; here it is simply the target shape.
  var displayAspect: Double = 0

  /// The shape the raster is SEEN as, which is not the shape it is counted in.
  ///
  /// Taking the count as the answer is right for HD by coincidence, since 1920x1080 and 1280x720 both
  /// count 16:9, and wrong for every SD mapping: 720x486 counts 1.481, so a 4:3 picture was being
  /// boxed against a target shape that exists on no monitor. Filling the whole raster IS the
  /// anamorphic answer there.
  private func rasterShape(width w: Int, height h: Int) -> Double {
    displayAspect > 0 ? displayAspect : (h > 0 ? Double(w) / Double(h) : 0)
  }

  /// Where a source of `sourceAspect` lands in a target of `targetAspect`, in TOP-DOWN pixels.
  ///
  /// Both aspects are passed rather than inferred, because the two ends of a blit can each be either
  /// square-pixel or anamorphic and only the caller knows which: the same raster is the TARGET when
  /// a picture is being mapped onto it and the SOURCE when it is previewed to the window, and an
  /// implicit rule that suits one of those is silently wrong for the other.
  ///
  /// Both blits used to ignore this entirely and just stretch corner to corner, which is wrong in
  /// both directions: a 4:3 window went out as a 16:9 raster stretched, and a 16:9 raster came back
  /// into a 4:3 window squeezed on the x axis. Fullscreen made the second worse again, because the
  /// window then carries the DISPLAY's shape rather than the video's.
  ///
  /// `fill` deliberately returns a rectangle larger than the target; the blit clips it, which is the
  /// crop. `stretch` returns the target, which is the old behaviour.
  private func destinationRect(sourceAspect: Double, targetAspect: Double,
                              width w: Int, height h: Int)
      -> (left: Int, top: Int, right: Int, bottom: Int) {
    let full = (left: 0, top: 0, right: w, bottom: h)
    guard sourceAspect > 0, targetAspect > 0, w > 0, h > 0, scaling != .stretch else { return full }
    if abs(sourceAspect - targetAspect) < 0.001 { return full }

    // Wider than the target: fit puts bars top and bottom, fill overflows left and right.
    //
    // Expressed as a RATIO of the raster rather than from the source's own pixel count, so it is
    // correct when the raster's count and its shape disagree. The two forms are identical whenever
    // they agree, which is every HD case, so nothing there moves.
    let widerThanTarget = sourceAspect > targetAspect
    let matchWidth = (scaling == .fit) == widerThanTarget
    if matchWidth {
      let scaledHeight = Int((Double(h) * targetAspect / sourceAspect).rounded())
      let offset = (h - scaledHeight) / 2
      return (left: 0, top: offset, right: w, bottom: offset + scaledHeight)
    }
    let scaledWidth = Int((Double(w) * sourceAspect / targetAspect).rounded())
    let offset = (w - scaledWidth) / 2
    return (left: offset, top: 0, right: offset + scaledWidth, bottom: h)
  }

  /// Blit a source rectangle into a destination, flipping Y and honouring `scaling`.
  ///
  /// The destination Y range is inverted because GL reads from the bottom while the card and the
  /// window both want the top first. Bars are cleared to black rather than left as whatever the
  /// previous frame put there.
  private func blitPreservingAspect(sourceWidth sw: Int, sourceHeight sh: Int,
                                    destWidth dw: Int, destHeight dh: Int,
                                    sourceAspect: Double? = nil, targetAspect: Double? = nil) {
    let rect = destinationRect(sourceAspect: sourceAspect ?? (sh > 0 ? Double(sw) / Double(sh) : 0),
                               targetAspect: targetAspect ?? (dh > 0 ? Double(dw) / Double(dh) : 0),
                               width: dw, height: dh)
    if rect.left > 0 || rect.top > 0 || rect.right < dw || rect.bottom < dh {
      glClearColor(0, 0, 0, 1)
      glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
    }
    glBlitFramebuffer(0, 0, GLint(sw), GLint(sh),
                      GLint(rect.left), GLint(dh - rect.top),
                      GLint(rect.right), GLint(dh - rect.bottom),
                      GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR))
  }

  /// Read pixels back synchronously instead of through the PBO ping-pong. The ping-pong hides the
  /// GPU stall by mapping the previous capture, which costs a full frame of delay: negligible
  /// behind the scheduled queue, dominant without it. A direct HD readback is a couple of
  /// milliseconds, affordable on the GL thread.
  var immediateReadback = false

  private let lock = NSLock()
  /// Whether the most recent store finished a frame. Always true when not weaving. The card should
  /// only be asked to display on a complete frame.
  private(set) var frameComplete = true
  /// The frame being assembled. Weaving writes one field of it per capture, so between the two it is
  /// half this pair and half the last one, and it must never be what the card reads.
  private var working = [UInt8]()
  /// The most recent WHOLE frame, and the only thing `copyLatest` hands out.
  private var published = [UInt8]()
  /// Landing area for a readback, so weaving can merge into `working` without destroying the field
  /// already sitting there.
  private var scratch = [UInt8]()
  private var hasFrame = false

  private(set) var capturedFrames = 0
  /// Whole frames handed to the feeder. Below the mode's frame rate means the feeder is repeating.
  private(set) var publishedFrames = 0
  /// Times the GL hook was entered, counted before any rate gating. Against `capturedFrames` this
  /// separates "the draw loop is not running often enough" from "we are discarding samples".
  private(set) var hookCalls = 0

  var isActive: Bool { targetWidth > 0 && targetHeight > 0 }

  // MARK: - lifecycle

  func activate(width: Int, height: Int, fps: Double,
                weaveFields: Bool = false, upperFieldFirst: Bool = true,
                interlineFilter: Bool = false,
                filmCadence: Bool = false, sourceFrameRate: Double = 0,
                queueDepth: Int = 4) {
    lock.lock()
    targetWidth = width
    targetHeight = height
    self.weaveFields = weaveFields
    self.upperFieldFirst = upperFieldFirst
    self.interlineFilter = interlineFilter
    self.filmCadence = filmCadence
    filmQueueDepth = max(1, queueDepth)
    filmQueueFloor = filmQueueDepth
    occupancyEMA = Double(filmQueueDepth)
    framesSinceHold = 0
    minOccupancySinceHold = Int.max
    self.sourceFrameRate = sourceFrameRate
    fieldRate = weaveFields ? fps * 2.0 : fps
    frameRate = fps
    fieldParity = 0
    cadenceAcc = 0
    traceHead = 0        // a re-arm starts a new session; old records would read as this one's
    sourceConsumed = 0
    pairingNeedsCatchUp = false
    // Keep the last picture across a re-arm when the raster has not changed. Re-allocating zeroed
    // buffers meant every settings change put black on the monitor until the next capture arrived,
    // and the feeder's own black fill covered the gap before that. The geometry check is what makes
    // it safe: a genuine mode change reallocates and starts from black, as it must.
    let sameRaster = published.count == width * height * 4 && hasFrame
    working = [UInt8](repeating: 0, count: width * height * 4)
    if !sameRaster {
      published = [UInt8](repeating: 0, count: width * height * 4)
    }
    filmReady.removeAll()
    filmSpare.removeAll()
    cadenceHolds = 0
    if filmCadence {
      // The two a dirty output frame needs, plus enough spares that a burst never has to allocate
      // 8 MB on the GL thread mid-playback.
      // Seed the cadence from the last picture too, so re-arming it does not blank the monitor
      // while the first film frames arrive.
      current = sameRaster ? published : [UInt8](repeating: 0, count: width * height * 4)
      previous = current
      for _ in 0...filmQueueDepth {
        filmSpare.append([UInt8](repeating: 0, count: width * height * 4))
      }
    } else {
      current = []; previous = []
    }
    hasFrame = sameRaster
    frameComplete = !weaveFields
    capturedFrames = 0
    publishedFrames = 0
    mixedFrames = 0
    framesWithoutPull = 0
    queueDrops = 0
    duplicatesOut = 0
    publishSerial = 0
    lastHandedSerial = -1
    hookCalls = 0
    nextSampleAt = 0
    hookIntervalEMA = 0
    lastHookAt = 0
    refreshCadenceRatioLocked()
    updateSampleIntervalLocked()
    lock.unlock()
  }

  /// How often to read back. The cadence wants ONE sample per film frame, since it builds the
  /// fields itself; weaving without it wants one per field; anything else one per frame.
  /// Caller holds `lock`.
  private func updateSampleIntervalLocked() {
    let rate: Double
    if sourceInterlaced {
      // One capture per output frame: each source frame IS an output frame here.
      rate = frameRate
    } else if cadenceEngagedLocked {
      // One capture per source frame: the cadence spreads them across the fields itself.
      rate = effectiveSourceRateLocked
    } else if weaveStarvedLocked {
      // Whole frames, sampled at the OUTPUT rate rather than the source's.
      //
      // Sampling at the source rate was wrong in both directions. Above the output rate it handed
      // the card more frames than it could show, so which ones survived was down to whenever the
      // card happened to ask: 50p produced 50 published frames a second at a card taking 29.97, and
      // the twenty that went missing were an arbitrary twenty. Below it, the card was left to
      // repeat whatever it still had. Sampling at the output rate makes the drop or the repeat
      // regular, which is the ordinary frame-rate conversion this case should have been doing.
      rate = frameRate
    } else {
      rate = fieldRate
    }
    sampleInterval = rate > 0 ? 1.0 / rate : 0
  }

  /// Whether this draw is the one to sample, keeping the long-run rate at `sampleInterval`.
  ///
  /// A plain "no sooner than X since the last one" cannot do this job. Set tight, it discards a draw
  /// whenever the display refresh jitters early, and at the field rate the window for that is only a
  /// hair wider than the refresh itself: measured, it was losing 5 draws of every 60, which is a
  /// field pair that never completed roughly four times a second. Set loose, it settles at some
  /// multiple of the wanted rate on a fast panel.
  ///
  /// So track when the next sample is DUE and take whichever draw lands nearest it. Half an interval
  /// of slack is what makes it jitter-immune, and it still halves cleanly on a display running at
  /// twice the rate we need.
  ///
  /// Caller is on the GL thread.
  private func shouldSample(at now: CFTimeInterval) -> Bool {
    guard sampleInterval > 0 else { return true }

    if lastHookAt > 0 {
      let dt = now - lastHookAt
      if dt > 0, dt < 1.0 { hookIntervalEMA = hookIntervalEMA > 0 ? hookIntervalEMA * 0.9 + dt * 0.1 : dt }
    }
    lastHookAt = now

    // When draws arrive no faster than samples are wanted, every draw is a new picture and gating
    // can only throw one away. Telecined material is the case that needs this: mpv presents those
    // frames for two field times and then three, so the draws are UNEVEN even though their average
    // is right, and a gate built on an even cadence samples twice inside a long frame and misses a
    // short one. That is what makes the output rate wander on exactly this content.
    if hookIntervalEMA > 0, hookIntervalEMA >= sampleInterval * 0.95 {
      nextSampleAt = now + sampleInterval   // keep the phase sane if draws speed up again
      return true
    }
    guard nextSampleAt > 0 else {          // first sample of the session sets the phase
      nextSampleAt = now + sampleInterval
      return true
    }
    guard now >= nextSampleAt - sampleInterval / 2 else { return false }
    // Advance from whichever is later, so a stall resets the phase rather than being followed by a
    // burst of samples catching up on a schedule that has fallen behind real time.
    nextSampleAt = max(now, nextSampleAt) + sampleInterval
    return true
  }

  /// Row the current field starts on. The earlier sample has to land in the field the card transmits
  /// first, or the two moments come out in the wrong order and motion tears backwards.
  private func fieldStartRow() -> Int {
    let earlierIsEven = upperFieldFirst
    return (fieldParity == 0) == earlierIsEven ? 0 : 1
  }

  /// Copy one row through a vertical [1 2 1]/4 filter of the source rows either side of it.
  ///
  /// Works directly on the packed 2:10:10:10 words. Each component is shifted down BEFORE being
  /// added so the three terms can never carry out of their own 10-bit field, which is what makes
  /// this a handful of integer ops per pixel instead of an unpack, three multiplies and a repack.
  /// The two masks drop the bits that a shift walks across a field boundary. Alpha is discarded,
  /// which is fine: nothing downstream reads it.
  private func filteredRow(_ src: UnsafePointer<UInt32>, _ dst: UnsafeMutablePointer<UInt32>,
                           width w: Int, y: Int, height h: Int) {
    let m1: UInt32 = 0x1FF7_FDFF   // valid bits per field after >> 1
    let m2: UInt32 = 0x0FF3_FCFF   // valid bits per field after >> 2
    let above = (y > 0 ? y - 1 : y) * w
    let below = (y + 1 < h ? y + 1 : y) * w
    let here = y * w
    for x in 0..<w {
      let a = (src[above + x] >> 2) & m2
      let b = (src[here + x] >> 1) & m1
      let c = (src[below + x] >> 2) & m2
      dst[x] = a &+ b &+ c
    }
  }

  /// Take a readback into the working frame, and publish it once it is whole.
  ///
  /// Progressive copies the whole frame and publishes it immediately. Weaving writes only the rows
  /// of the field this sample belongs to and publishes when the second field of the pair lands, so
  /// the feeder can never pick up a frame that is half this pair and half the last one.
  ///
  /// An earlier version seeded the missing field from the same sample, to guarantee the feeder
  /// always had something current. That is wrong for a feeder running on its own clock: it samples
  /// between the two fields as often as not, and a seeded frame is a PsF frame, so the output
  /// alternated between true field pairs and frozen ones. Repeating the last WHOLE frame is the
  /// honest failure: it costs judder when we cannot keep up, rather than corrupting the motion of
  /// frames we could.
  ///
  /// Caller holds `lock`.
  private func store(from src: UnsafeRawPointer, width w: Int, height h: Int) {
    let rowBytes = w * 4

    // The cadence assembles fields itself, on the card's clock, so a capture is simply the next
    // film frame. Filter here rather than per field: it is the same work over four fifths as many
    // frames.
    if cadenceEngagedLocked {
      var buffer = filmSpare.popLast() ?? [UInt8](repeating: 0, count: rowBytes * h)
      if buffer.count != rowBytes * h { buffer = [UInt8](repeating: 0, count: rowBytes * h) }
      buffer.withUnsafeMutableBytes { raw in
        guard let dstBase = raw.baseAddress else { return }
        if interlineFilter {
          let srcWords = src.assumingMemoryBound(to: UInt32.self)
          let dstWords = dstBase.assumingMemoryBound(to: UInt32.self)
          for y in 0..<h { filteredRow(srcWords, dstWords.advanced(by: y * w), width: w, y: y, height: h) }
        } else {
          memcpy(dstBase, src, rowBytes * h)
        }
        // One step per FILM frame, so the cadence's own beat shows rather than a smooth sweep.
        drawTestPattern(dstBase, width: w, height: h, startRow: 0, everyOtherRow: false)
      }
      if testPattern != .off { testStep += 1 }
      filmReady.append(buffer)
      record(kind: 2, flags: 0)
      // Bound the queue. Dropping the OLDEST keeps latency fixed and loses the frame furthest from
      // what should be on screen, which only happens if the card has stopped consuming.
      while filmReady.count > filmQueueDepth {
        filmSpare.append(filmReady.removeFirst())
        // The mirror image of a hold: production outran consumption by one frame and the oldest is
        // discarded. Counted because holds and drops are the only places a rate difference becomes
        // visible; the produced and consumed totals cannot show it, being equal by construction.
        queueDrops &+= 1
      }
      hasFrame = true
      frameComplete = true
      capturedFrames += 1
      return
    }

    // Pass-through: copy the frame as it came, optionally shifted a line. Every row moves, so the
    // fields the encoder wrote are the fields the card transmits.
    if sourceInterlaced {
      working.withUnsafeMutableBytes { raw in
        guard let dstBase = raw.baseAddress else { return }
        if placedHeight > 0, !placementAppliedInGL {
          // mpv rendered into the top `placedHeight` rows of the target, so move them down to the
          // placement line and blank the rest. Field Order still adds its one line on top, which is
          // the escape hatch if the chain wants the opposite parity.
          memset(dstBase, 0, rowBytes * h)
          let shift = placedTopOffset + (swapSourceFields ? 1 : 0)
          for y in 0..<placedHeight {
            let target = y + shift
            guard target >= 0, target < h else { continue }
            memcpy(dstBase.advanced(by: target * rowBytes), src.advanced(by: y * rowBytes), rowBytes)
          }
        } else if swapSourceFields {
          // One line down: row 0 takes source row 1, so what was the upper field becomes the lower.
          // The last row has nothing above it to take and keeps what it had, which is one line of
          // the wrong field at the very bottom of the raster, past anything a tube shows.
          for y in 0..<h {
            let from = min(h - 1, y + 1)
            memcpy(dstBase.advanced(by: y * rowBytes), src.advanced(by: from * rowBytes), rowBytes)
          }
        } else {
          memcpy(dstBase, src, rowBytes * h)
        }
        // Per FIELD here, unlike everywhere else in this function, because pass-through is the one
        // path whose two fields are genuinely two different moments: an interlaced source carries
        // them as alternate lines inside the frame we just copied. A pattern painted across both at
        // once steps once per frame and therefore cannot show field order, a dropped field, or a
        // swapped pair, which is the entire reason the field-order pattern exists. Two calls, a step
        // apart, put the sweep back on the grid the content is actually on.
        if testPattern != .off {
          let firstRow = upperFieldFirst ? 0 : 1
          drawTestPattern(dstBase, width: w, height: h, startRow: firstRow, everyOtherRow: true)
          testStep += 1
          drawTestPattern(dstBase, width: w, height: h, startRow: 1 - firstRow, everyOtherRow: true)
          testStep += 1
        }
      }
      frameComplete = true
      // Record it. Only the cadence branch did, so in this mode and the weave below the trace held
      // handouts and nothing else, and a handout repeat could not be told from phase jitter: the
      // captures that were overwritten before the card asked for them left no trace of having
      // existed. Two captures between one handout is over-production; none between two handouts is
      // the repeat. Both are visible now, and the difference is the whole diagnosis.
      record(kind: 2, flags: 0)
      swap(&working, &published)
      hasFrame = true
      publishSerial &+= 1
      capturedFrames += 1
      publishedFrames += 1
      return
    }

    // Fall back to whole frames when the source cannot supply a moment per field. Pairing samples
    // that are a source frame apart is not interlace, and the test pattern shows exactly what it
    // costs: whole frames repeated, which reads as a step backwards at every frame boundary.
    let weaving = weaveFields && !weaveStarvedLocked

    working.withUnsafeMutableBytes { raw in
      guard let dstBase = raw.baseAddress else { return }
      let srcWords = src.assumingMemoryBound(to: UInt32.self)
      let dstWords = dstBase.assumingMemoryBound(to: UInt32.self)

      // One row, through the filter or straight across.
      func copyRow(_ y: Int) {
        if interlineFilter {
          filteredRow(srcWords, dstWords.advanced(by: y * w), width: w, y: y, height: h)
        } else {
          memcpy(dstBase.advanced(by: y * rowBytes), src.advanced(by: y * rowBytes), rowBytes)
        }
      }

      guard weaving else {
        // Weaving can suspend and resume while running, because the starved test depends on a
        // source rate that is polled and can change under a seek or a file change. Leaving the
        // parity wherever it stopped meant weaving could resume mid-pair, which assembles every
        // later pair the wrong way round and inverts the field order until something happens to
        // flip it back. Resuming from a known phase is the whole fix.
        fieldParity = 0
        if interlineFilter {
          for y in 0..<h { copyRow(y) }
        } else {
          memcpy(dstBase, src, rowBytes * h)   // untouched fast path
        }
        drawTestPattern(dstBase, width: w, height: h, startRow: 0, everyOtherRow: false)
        return
      }

      // Only this field's rows. The other half of `working` still holds the frame published two
      // pairs ago and is overwritten by this pair's second sample before anything sees it.
      let first = fieldStartRow()
      var y = first
      while y < h { copyRow(y); y += 2 }
      // One step per FIELD, so a swapped order shows as a back-step every other one.
      drawTestPattern(dstBase, width: w, height: h, startRow: first, everyOtherRow: true)
    }
    if testPattern != .off { testStep += 1 }
    // A capture here is one FIELD while weaving and one frame otherwise, so this is also how the
    // trace shows which of the two is actually running.
    record(kind: 2, flags: 0)
    if weaving { fieldParity ^= 1 }
    // Parity back at 0 means the second field of the pair has just landed.
    frameComplete = !weaving || fieldParity == 0
    capturedFrames += 1
    guard frameComplete else { return }

    // O(1): an Array is one reference to its storage, so this hands the feeder the frame just
    // finished and takes back the one it had, to assemble the next pair in.
    swap(&working, &published)
    hasFrame = true
    publishSerial &+= 1
    publishedFrames += 1
  }

  /// GL teardown has to happen on the GL thread, so this only marks the tap inactive; the FBO is
  /// released on the next capture call or when the layer goes away.
  func deactivate() {
    lock.lock()
    targetWidth = 0
    targetHeight = 0
    // `hasFrame` is deliberately left alone. copyLatest already refuses to hand anything out once
    // the size guard fails, and keeping it lets a re-arm at the same raster carry the last picture
    // over instead of flashing black.
    lock.unlock()
  }

  /// The canvas to render into, or nil to render straight at the raster as before.
  ///
  /// Wanted only where the raster's pixel count is not its shape, which is SD, and only when the
  /// picture is being scaled at all: with a line placement in force the source is already the
  /// raster's own height and goes across 1:1, and putting a resample in front of that would blend
  /// the very lines the placement exists to keep apart.
  ///
  /// Its height is the raster's, so the vertical scale is 1:1 and only the horizontal one does work.
  /// Caller holds `lock`.
  private func canvasGeometryLocked(rasterW w: Int, rasterH h: Int) -> (width: Int, height: Int)? {
    guard displayAspect > 0, sourceAspect > 0, w > 0, h > 0 else { return nil }
    // A placement fixes the height at the source's own active lines, and the blit then puts them
    // where they belong. That is what makes the vertical 1:1: a 640x480 source gets a canvas of
    // exactly 640x480, so mpv resamples nothing at all and only the horizontal stretch to 720 is
    // ever done, which is what anamorphic asks for and all it asks for.
    let boxHeight = placedHeight > 0 ? placedHeight : h
    let width = Int((Double(boxHeight) * sourceAspect).rounded())
    guard width >= 16, width <= 8192 else { return nil }
    return (width, boxHeight)
  }

  /// Whether the GL blit already put the picture on its placement lines, so `store` must not do it
  /// again. Two mechanisms for one job is how a thing gets applied twice.
  private var placementAppliedInGL = false

  /// Same two-format fallback as the raster's own framebuffer, for the same reason.
  private func ensureCanvasFramebuffer(width: Int, height: Int) -> Bool {
    if canvasFBO != 0, canvasWidth == width, canvasHeight == height { return true }
    releaseCanvasResources()
    for internalFormat in [GL_RGB10_A2, GL_RGBA8] {
      glGenTextures(1, &canvasTexture)
      glBindTexture(GLenum(GL_TEXTURE_2D), canvasTexture)
      glTexImage2D(GLenum(GL_TEXTURE_2D), 0, internalFormat, GLsizei(width), GLsizei(height), 0,
                   GLenum(GL_BGRA), GLenum(GL_UNSIGNED_INT_2_10_10_10_REV), nil)
      glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
      glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
      glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
      glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
      glGenFramebuffers(1, &canvasFBO)
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), canvasFBO)
      glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                             GLenum(GL_TEXTURE_2D), canvasTexture, 0)
      if glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) {
        canvasWidth = width
        canvasHeight = height
        return true
      }
      releaseCanvasResources()
    }
    return false
  }

  private func releaseCanvasResources() {
    if canvasTexture != 0 { glDeleteTextures(1, &canvasTexture); canvasTexture = 0 }
    if canvasFBO != 0 { glDeleteFramebuffers(1, &canvasFBO); canvasFBO = 0 }
    canvasWidth = 0
    canvasHeight = 0
  }

  /// Must be called with the GL context current (ViewLayer teardown).
  func releaseGLResources() {
    if texture != 0 { glDeleteTextures(1, &texture); texture = 0 }
    if fbo != 0 { glDeleteFramebuffers(1, &fbo); fbo = 0 }
    if pbos[0] != 0 || pbos[1] != 0 { glDeleteBuffers(2, &pbos); pbos = [0, 0] }
    releaseCanvasResources()
    forgetGLResources()
  }

  /// Drop every handle without touching GL, for when the objects belong to a context that is no
  /// longer current and must not be deleted through this one.
  private func forgetGLResources() {
    texture = 0
    fbo = 0
    canvasTexture = 0
    canvasFBO = 0
    canvasWidth = 0
    canvasHeight = 0
    pbos = [0, 0]
    pboPrimed = false
    pboIndex = 0
    allocatedWidth = 0
    allocatedHeight = 0
  }

  // MARK: - capture (GL thread)

  /// Scale the frame IINA has just rendered into our SDI-sized buffer and read it back.
  /// Call from ViewLayer.draw, after the on-screen render, with the GL context current.
  ///
  /// A single GPU blit of the existing render, rather than a second full mpv render pass at SDI
  /// size: the latter is better quality but costs enough to drag the display loop down and starve
  /// both the window and the card. The trade is that the SDI picture is only as good as the
  /// window-sized render, so a small window means a softer output; `renderForOutput` is the
  /// alternative when SDI quality matters more.
  func capture(renderContext: OpaquePointer, sourceFBO: GLuint,
               sourceWidth: Int, sourceHeight: Int) {
    lock.lock()
    let w = targetWidth, h = targetHeight
    lock.unlock()
    guard w > 0, h > 0 else { return }
    hookCalls += 1

    guard shouldSample(at: CACurrentMediaTime()) else { return }
    guard ensureFramebuffer(width: w, height: h) else { return }
    // This path has no canvas, so whatever the other one last did about placement does not hold.
    lock.lock(); placementAppliedInGL = false; lock.unlock()

    // Save the caller's binding and viewport; ViewLayer keeps rendering into its own FBO after us.
    var prevDrawFBO: GLint = 0
    var prevViewport: [GLint] = [0, 0, 0, 0]
    glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &prevDrawFBO)
    glGetIntegerv(GLenum(GL_VIEWPORT), &prevViewport)

    // Scale IINA's rendered frame into ours, keeping its shape. The window is sized to the video,
    // so its aspect is the video's; stretching it to the raster is what sent 4:3 out as a squashed
    // 16:9. In fullscreen the window carries the display's shape instead, bars included, so fitting
    // that is still geometrically right even though it doubles the bars.
    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), sourceFBO)
    glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
    glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), fbo)
    glViewport(0, 0, GLsizei(w), GLsizei(h))   // glClear obeys the viewport's scissor-free bounds
    blitPreservingAspect(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                         destWidth: w, destHeight: h,
                         targetAspect: rasterShape(width: w, height: h))

    readBackCurrentFBO(width: w, height: h)

    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(prevDrawFBO))
    glViewport(prevViewport[0], prevViewport[1], GLsizei(prevViewport[2]), GLsizei(prevViewport[3]))
    // Swallow any error we caused rather than letting it surface in IINA's own draw path.
    while glGetError() != GLenum(GL_NO_ERROR) {}
  }

  /// Render mpv once at the SDI mode's resolution, read that back for the card, and blit the same
  /// result to the window as a preview. One render at the resolution that matters, so the SDI feed
  /// is native quality and the window shows an upscaled copy when it is larger than the mode.
  ///
  /// Returns false if it could not take over, in which case the caller should render normally.
  func renderForOutput(renderContext: OpaquePointer, screenFBO: GLuint,
                       screenWidth: Int, screenHeight: Int) -> Bool {
    lock.lock()
    let w = targetWidth, h = targetHeight
    let canvas = canvasGeometryLocked(rasterW: w, rasterH: h)
    let aspect = sourceAspect
    let placeTop = placedTopOffset
    let placeHeight = placedHeight
    lock.unlock()
    guard w > 0, h > 0, ensureFramebuffer(width: w, height: h) else { return false }
    hookCalls += 1

    var prevViewport: [GLint] = [0, 0, 0, 0]
    glGetIntegerv(GLenum(GL_VIEWPORT), &prevViewport)

    // Render at the canvas when there is one, and stretch it onto the raster afterwards. mpv is
    // given a target of the source's own shape, so it fills it and never adds a bar we would have to
    // reason around; the shape of the raster is then entirely this code's business.
    let useCanvas = canvas != nil && ensureCanvasFramebuffer(width: canvas!.width, height: canvas!.height)
    let renderFBO = useCanvas ? canvasFBO : fbo
    let renderWidth = useCanvas ? canvas!.width : w

    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), renderFBO)
    glViewport(0, 0, GLsizei(renderWidth), GLsizei(useCanvas ? canvas!.height : h))
    if placedHeight > 0 {
      glClearColor(0, 0, 0, 1)   // the rows outside the placement must be blanking, not last frame
      glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
    }

    // Unflipped, so the bottom-up glReadPixels below lands top-down for the card. The screen blit
    // afterwards flips it back for display.
    var flip: CInt = 0
    // 10, matching the RGB10_A2 target: this is what mpv dithers to, so leaving it at 8 threw the
    // extra bits away before they were ever written.
    var depth: CInt = 10
    // Render into only the rows the source actually has, when placing rather than scaling. mpv
    // fills the region it is given, so asking for the source height is what keeps it 1:1.
    lock.lock(); placementAppliedInGL = useCanvas && placeHeight > 0; lock.unlock()
    let renderHeight = useCanvas ? canvas!.height : (placeHeight > 0 ? placeHeight : h)
    var data = mpv_opengl_fbo(fbo: Int32(renderFBO), w: Int32(renderWidth), h: Int32(renderHeight),
                              internal_format: 0)
    withUnsafeMutablePointer(to: &data) { dataPtr in
      withUnsafeMutablePointer(to: &flip) { flipPtr in
        withUnsafeMutablePointer(to: &depth) { depthPtr in
          var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: .init(dataPtr)),
            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: .init(flipPtr)),
            mpv_render_param(type: MPV_RENDER_PARAM_DEPTH, data: .init(depthPtr)),
            mpv_render_param()
          ]
          mpv_render_context_render(renderContext, &params)
        }
      }
    }

    // Field spacing has to match the card's, or the two moments woven into a frame are however far
    // apart the display happened to refresh. Only gates the readback: the window still draws every
    // time.
    //
    // This used to gate the weaving case alone, which left whole frames read back at the display's
    // rate rather than the mode's: on a 60 Hz panel driving 1080i59.94 that was 60 readbacks a
    // second for a card consuming 29.97, and the same setting through the other capture path gated
    // at 29.97, so one checkbox changed the rate for no reason anyone could see. Producing faster
    // than the card consumes buys nothing but heat, and the work it wastes is what the filter and
    // the field-rate weave need: measured, the filter alone cost three draws a second.
    // Canvas onto raster: one blit, source shaped like the picture and destination shaped like the
    // signal, which is exactly what anamorphic means. `destinationRect` decides where it lands, and
    // for Fill it deliberately returns a rectangle larger than the raster so the blit clips it,
    // which is the crop. Y is converted rather than flipped: mpv rendered unflipped into the canvas,
    // so both buffers already agree, and a rect measured top-down becomes a GL range measured up.
    if useCanvas {
      // Fit or crop inside the BOX the placement defines, then move the whole box onto its lines.
      // The 480 placed lines are the picture, and the six spare ones are blanking a tube never
      // shows, so the box is what carries the display shape and the full raster is not.
      let box = placeHeight > 0 ? placeHeight : h
      let inner = destinationRect(sourceAspect: aspect,
                                  targetAspect: rasterShape(width: w, height: h),
                                  width: w, height: box)
      let rect = (left: inner.left, top: inner.top + placeTop,
                  right: inner.right, bottom: inner.bottom + placeTop)
      glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), fbo)
      glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), canvasFBO)
      glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
      glViewport(0, 0, GLsizei(w), GLsizei(h))
      if rect.left > 0 || rect.top > 0 || rect.right < w || rect.bottom < h {
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
      }
      glBlitFramebuffer(0, 0, GLint(canvas!.width), GLint(canvas!.height),
                        GLint(rect.left), GLint(h - rect.bottom),
                        GLint(rect.right), GLint(h - rect.top),
                        GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR))
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
    }

    if shouldSample(at: CACurrentMediaTime()) {
      readBackCurrentFBO(width: w, height: h)
    }

    // Preview to the window from the same render. Y is inverted here because the SDI render is
    // unflipped and the screen expects the on-screen orientation.
    //
    // Always FIT, whatever the SDI mapping is set to. What we hold is a finished raster of the
    // mode's shape, and IINA sizes its window to the VIDEO, so stretching one into the other
    // squeezed the preview on the x axis whenever the two differed. The preview's job is to show
    // what is going out, which means keeping its shape.
    let previewScaling = scaling
    scaling = .fit
    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), fbo)
    glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
    glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), screenFBO)
    glViewport(0, 0, GLsizei(screenWidth), GLsizei(screenHeight))
    blitPreservingAspect(sourceWidth: w, sourceHeight: h,
                         destWidth: screenWidth, destHeight: screenHeight,
                         sourceAspect: rasterShape(width: w, height: h))
    scaling = previewScaling

    // Leave the viewport describing the SCREEN, not whatever it was on entry. Restoring the value
    // read at the top perpetuated a wrong one: mpv sets the viewport to the raster size while
    // rendering into our target, so if the entry value had already been corrupted, every later pass
    // faithfully restored the corruption.
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), screenFBO)
    glViewport(0, 0, GLsizei(screenWidth), GLsizei(screenHeight))
    _ = prevViewport
    while glGetError() != GLenum(GL_NO_ERROR) {}
    return true
  }


  /// Read the currently bound framebuffer into the published buffer via ping-ponged PBOs.
  private func readBackCurrentFBO(width w: Int, height h: Int) {
    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), fbo)
    glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
    glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)

    if immediateReadback {
      glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), 0)   // straight to client memory, no PBO
      lock.lock()
      if published.count == w * h * 4 {
        if readbackNeedsStore {
          // Anything that transforms the readback needs a separate source: weaving keeps half of the
          // previous field, and the filter reads neighbouring rows, so writing into the published
          // buffer as we go would consume data we still need. Untransformed output skips this.
          if scratch.count != w * h * 4 { scratch = [UInt8](repeating: 0, count: w * h * 4) }
          scratch.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
              glReadPixels(0, 0, GLsizei(w), GLsizei(h), GLenum(GL_BGRA),
                           GLenum(GL_UNSIGNED_INT_2_10_10_10_REV), base)
              store(from: base, width: w, height: h)
            }
          }
        } else {
          // Nothing to assemble, so read straight into the published frame and skip the copy.
          published.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
              glReadPixels(0, 0, GLsizei(w), GLsizei(h), GLenum(GL_BGRA),
                           GLenum(GL_UNSIGNED_INT_2_10_10_10_REV), base)
            }
          }
          hasFrame = true
          // Recorded here too, because this branch never reaches `store`, and a trace of a mode that
          // takes it would otherwise hold handouts and no captures at all.
          record(kind: 2, flags: 0)
          publishSerial &+= 1
          capturedFrames += 1
          publishedFrames += 1
        }
      }
      lock.unlock()
      return
    }

    let byteCount = w * h * 4
    let writeIndex = pboIndex
    let readIndex = 1 - pboIndex
    pboIndex = readIndex

    // Kick off this frame's readback; it does not block.
    glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), pbos[writeIndex])
    glReadPixels(0, 0, GLsizei(w), GLsizei(h), GLenum(GL_BGRA),
                 GLenum(GL_UNSIGNED_INT_2_10_10_10_REV), nil)

    // Collect the one issued last time, which the GPU has had a full frame to finish.
    if pboPrimed {
      glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), pbos[readIndex])
      if let mapped = glMapBuffer(GLenum(GL_PIXEL_PACK_BUFFER), GLenum(GL_READ_ONLY)) {
        lock.lock()
        if working.count == byteCount {   // guard a deactivate() that landed mid-render
          store(from: mapped, width: w, height: h)
        }
        lock.unlock()
        glUnmapBuffer(GLenum(GL_PIXEL_PACK_BUFFER))
      }
    } else {
      pboPrimed = true
    }
    glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), 0)
  }

  private func ensureFramebuffer(width: Int, height: Int) -> Bool {
    // GL object names belong to the context that created them, and every player window has its own.
    // The route can now move between windows, and it moves without changing the SDI size, so the
    // size check alone would keep reusing an FBO name from the window we just left. Bound in the new
    // context that name refers to nothing, which is why a second window rendered a torn overlay to
    // both the preview and the card instead of simply taking over.
    let current = CGLGetCurrentContext()
    if current != glContext {
      // Abandon rather than delete: these names index the OLD context's objects, and deleting them
      // while a different context is current would either do nothing or destroy an unrelated object
      // that happens to share the number. They die with their context.
      forgetGLResources()
      glContext = current
    }
    if fbo != 0 && allocatedWidth == width && allocatedHeight == height { return true }
    releaseGLResources()

    // RGB10_A2, not RGBA8. The card's 10-bit formats were being fed 8-bit data promoted into
    // 10-bit words, so selecting "10-bit" bought nothing but a wider container. Same 32 bits per
    // pixel, so every size calculation downstream is unchanged.
    //
    // If the driver will not render to it, fall back to RGBA8 rather than losing output entirely.
    // Nothing downstream has to know: `glReadPixels` converts from the attachment's internal format
    // to whatever external format is asked for, so reading 2:10:10:10 off an 8-bit attachment still
    // yields correctly scaled values in the 10-bit domain. Only the precision is lost, not the
    // format contract.
    var complete = false
    for internalFormat in [GL_RGB10_A2, GL_RGBA8] {
      releaseGLResources()
      glGenTextures(1, &texture)
      glBindTexture(GLenum(GL_TEXTURE_2D), texture)
      glTexImage2D(GLenum(GL_TEXTURE_2D), 0, internalFormat, GLsizei(width), GLsizei(height), 0,
                   GLenum(GL_BGRA), GLenum(GL_UNSIGNED_INT_2_10_10_10_REV), nil)
      glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
      glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)

      glGenFramebuffers(1, &fbo)
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
      glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                             GLenum(GL_TEXTURE_2D), texture, 0)
      let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
      if status == GLenum(GL_FRAMEBUFFER_COMPLETE) {
        complete = true
        if internalFormat == GL_RGBA8 {
          Logger.log("DeckLink: 10-bit offscreen target unavailable, falling back to 8-bit",
                     level: .warning)
        }
        break
      }
      Logger.log("DeckLink: offscreen framebuffer incomplete for internal format \(internalFormat) (status \(status))",
                 level: .warning)
    }
    guard complete else {
      Logger.log("DeckLink: could not create an offscreen framebuffer", level: .error)
      releaseGLResources()
      return false
    }
    glGenBuffers(2, &pbos)
    for pbo in pbos {
      glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), pbo)
      glBufferData(GLenum(GL_PIXEL_PACK_BUFFER), width * height * 4, nil, GLenum(GL_STREAM_READ))
    }
    glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), 0)
    pboPrimed = false
    pboIndex = 0

    allocatedWidth = width
    allocatedHeight = height
    return true
  }

  // MARK: - consume (DeckLink thread)

  /// Build one output frame's two fields straight into the feeder's buffer.
  ///
  /// Called once per output frame, from the card's completion thread, which is why the cadence is
  /// regular: the slot counter advances on the card's clock rather than on ours.
  ///
  /// Each field takes the source frame its slot lands on, and the slot counter is stepped twice per
  /// output frame. Where two consecutive slots fall in different source frames the raster carries
  /// two moments, which is what telecine sends and what a CRT scans. At 0.4 that is the 2:3 of
  /// film; at 0.834 it is the 5:6 of 50p into a 59.94 field raster; at 1.0 every field is its own
  /// frame. Nothing here is specific to any of them.
  ///
  /// No more row copies than a plain frame needs, so the cadence costs nothing here.
  /// Caller holds `lock`.
  private func composeCadenceFrame(into destination: UnsafeMutableRawPointer,
                                   width: Int, height: Int, stride: Int) {
    // The first field is whatever the current slot sits on. Held as a local because the step below
    // may move `current` on, and this frame still needs the moment it had.
    // Put the pairing back on an even count before building anything, so the two moments land on
    // the fields they belong to. One frame goes by to buy it.
    if pairingNeedsCatchUp, !filmReady.isEmpty {
      pullCadenceFrame()
      pairingNeedsCatchUp = false
    }

    // Anchor the phase to the frame boundary when one source frame makes one output frame.
    //
    // At a ratio of a half the accumulator never drifts, so its phase has TWO stable positions: the
    // wrap on the trailing step, which is correct, and the wrap on the leading step, which pairs two
    // moments in every frame and never recovers. A trace caught the second one running for an entire
    // session, phase alternating 0.8104 and 0.3104, mixed and leadstep on 4090 of 4096 frames, with
    // the ratio itself perfectly correct and consumption at one frame each. The wrap tolerance fixed
    // slipping INTO that state; nothing could get out of it.
    //
    // Where one frame feeds one output frame, the pull belongs at the END of the frame by
    // definition, so a leading-step wrap is not a phase to preserve but an error to clear. Resetting
    // costs a single frame once, against an inversion that otherwise lasts as long as playback.
    //
    // Only AT a half, not at or below it. Below a half the two steps sum to less than one, so
    // zeroing the accumulator throws away progress that no later step gives back: the frame ends at
    // 2r, the next frame's test fires again for any r at or above a third, and the wrap is
    // pre-empted forever. Consumption then stops completely while the queue fills, which measured
    // as three frozen runs of 70, 32 and 31 frames in one 137 second trace, the ratio sitting at
    // 0.4731 with five frames queued. Simulated over the ratios that matter: 0.4 for 23.98p, 0.4004
    // for 24p and 0.4171 for 25p all pull ZERO frames under the wider test and the correct 2r per
    // frame under this one.
    //
    // Ratios either side of a half are left alone. Above, a leading-step wrap is legitimate, since
    // those frames are supposed to carry two moments; below, it is the telecine pattern itself, the
    // 2:3 of film, and there is nothing to correct.
    if cadenceIsOneToOne, cadenceAcc + cadenceRatioLocked >= 1.0 - 1e-6 {
      cadenceAcc = 0
    }

    let firstSource = current
    let consumedBefore = sourceConsumed
    if stepCadenceSlot() { pullCadenceFrame() }

    // Both fields from ONE source frame when the frames are already interlaced.
    //
    // The cadence assumes a source frame is one instant, so pairing this frame's earlier field with
    // the NEXT frame's later field is the correct way to sample motion. On interlaced material the
    // assumption is false and the result is wrong in a way that dwarfs any judder: the two moments
    // are ALREADY the alternate lines of a single frame, so a split takes frame N's top field and
    // frame N+1's bottom field and transmits them as one picture. Motion then runs forward, back,
    // forward, once for every source boundary that lands between two fields. Measured on 50i into
    // 1080i59.94, ratio 0.4171, that is 257 of 620 frames.
    //
    // Taking both fields from the one frame reproduces the encoder's own pair exactly, since the
    // blit splits rows 0,2,4 and 1,3,5 of a frame that already holds them that way. The rate
    // difference then shows up as whole frames repeating, which is judder and is unavoidable at
    // 25 into 29.97, rather than as two pictures welded together.
    //
    // The pull still happens on its own schedule; only its USE is deferred to the next frame, so
    // consumption and phase are untouched. At any ratio below a half one slot pair can wrap only
    // once, so nothing is skipped either.
    let pairedAcrossFrames = !sourceFramesInterlaced && sourceConsumed != consumedBefore
    let secondSource = pairedAcrossFrames ? current : firstSource
    // Counted only where it is a fault. Below a half a leading-step pull is the telecine pattern
    // itself: at 0.4 the pull falls on the leading step of 160 frames in every 400, which is the 2:3
    // of film and exactly what the cadence exists to produce. Counting those would put a four figure
    // number next to the word mixed on ordinary film content and bury the case that matters.
    // The trace flag below is NOT gated, so the per-frame truth is still in the ring either way.
    if pairedAcrossFrames, cadenceIsOneToOne { mixedFrames += 1 }
    // The leading-step pull is the tell for a slipped phase: at or below half the field rate it
    // should never happen, because the wrap belongs on the trailing step. On interlaced source it
    // cannot be set at all now, which is what makes its absence the confirmation in a trace.
    record(kind: 1, flags: pairedAcrossFrames ? 0b10010 : 0,
           fieldA: Int32(truncatingIfNeeded: consumedBefore),
           fieldB: Int32(truncatingIfNeeded: sourceConsumed))

    let rowBytes = width * 4
    // The earlier moment has to land in the field the card transmits first.
    let firstStart = upperFieldFirst ? 0 : 1

    func blit(_ source: [UInt8], startingAt start: Int) {
      guard source.count == rowBytes * height else { return }
      source.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var y = start
        while y < height {
          memcpy(destination.advanced(by: y * stride), base.advanced(by: y * rowBytes), rowBytes)
          y += 2
        }
      }
    }
    blit(firstSource, startingAt: firstStart)
    blit(secondSource, startingAt: 1 - firstStart)

    // Step on to the next output frame's first slot, so `current` is already right when it arrives.
    if stepCadenceSlot() { pullCadenceFrame() }

    // A stalled cadence is a silent duplicate, and nothing else here could see it.
    //
    // The handout path counts a repeat by comparing serials, but the cadence path returns before it
    // on the grounds that it builds a new frame every time. That is only true while the phase keeps
    // moving. A phase that stops advancing rebuilds the same source frame indefinitely, and it
    // measured as three runs of 70, 32 and 31 output frames in one trace, all of them reported as
    // new, with frames waiting in the queue the whole time.
    //
    // Frames that take nothing are normal below a half: at 0.4 one source frame spans two output
    // frames, which is the 3 in 3:2. So the test is the RUN, against what the ratio allows. With 2r
    // pulls per frame the gap between pulls cannot exceed ceil(1 / 2r) frames, so anything longer is
    // the cadence stuck rather than the cadence spread out. At a half the allowance is zero, since
    // every frame there takes exactly one.
    //
    // Only while the queue has something to take: with an empty queue a repeat is starvation, which
    // is a hold and is already counted as one.
    if sourceConsumed == consumedBefore {
      framesWithoutPull += 1
      let gap = cadenceRatioLocked > 0 ? (1.0 / (2.0 * cadenceRatioLocked)).rounded(.up) : 1.0
      if Double(framesWithoutPull) > gap - 1, !filmReady.isEmpty {
        duplicatesOut += 1
        record(kind: 1, flags: 0b100)
      }
    } else {
      framesWithoutPull = 0
    }
  }

  /// Copy the most recent captured frame into the feeder's buffer.
  /// Returns false when nothing has been captured yet, which tells the feeder to repeat.
  func copyLatest(into destination: UnsafeMutableRawPointer,
                  width: Int, height: Int, stride: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard hasFrame, width == targetWidth, height == targetHeight else { return false }

    if cadenceEngagedLocked, current.count == width * height * 4 {
      composeCadenceFrame(into: destination, width: width, height: height, stride: stride)
      publishedFrames += 1
      return true   // a repeat inside the cadence is caught where it is built, not by serial here
    }

    if publishSerial == lastHandedSerial {
      duplicatesOut += 1
      record(kind: 3, flags: 0b100)
    } else {
      lastHandedSerial = publishSerial
      record(kind: 3, flags: 0)
    }

    guard published.count == width * height * 4 else { return false }
    let rowBytes = width * 4
    published.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      if stride == rowBytes {
        memcpy(destination, base, rowBytes * height)
      } else {
        for y in 0..<height {
          memcpy(destination.advanced(by: y * stride), base.advanced(by: y * rowBytes), rowBytes)
        }
      }
    }
    return true
  }
}
