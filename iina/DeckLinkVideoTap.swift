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
  /// Field rate of the mode, so the cadence can check the source really is 2/5 of it.
  private var fieldRate: Double = 0

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
  private static let filmQueueDepth = 4
  private var current = [UInt8]()
  private var previous = [UInt8]()
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

  /// Source frames per field slot, never above 1: a source cannot supply more distinct moments than
  /// it has frames. Caller holds `lock`.
  private var cadenceRatioLocked: Double {
    guard fieldRate > 0 else { return 1 }
    return min(1.0, sourceFrameRate / fieldRate)
  }

  /// Whether the cadence can run: asked for, weaving, and a source no faster than the field rate.
  ///
  /// This used to demand exactly 2/5, which is film and nothing else. Every rate below the field
  /// rate has the same problem and the same answer, so the ratio is simply computed now. 50p into
  /// 59.94i is the case that showed it up: it fell out of the film test, took the whole-frame
  /// fallback, and published 50 frames a second at a card taking 29.97, so twenty of them a second
  /// were silently never shown and which twenty was arbitrary.
  private var cadenceEngagedLocked: Bool {
    guard filmCadence, weaveFields, sourceFrameRate > 0, fieldRate > 0 else { return false }
    return sourceFrameRate <= fieldRate * 1.01
  }

  /// Advance one field slot. True when the slot crosses into the next source frame.
  private func stepCadenceSlot() -> Bool {
    cadenceAcc += cadenceRatioLocked
    guard cadenceAcc >= 1.0 else { return false }
    cadenceAcc -= 1.0
    return true
  }

  /// Move on to the next source frame, or record that there was not one to move to.
  private func pullCadenceFrame() {
    guard !filmReady.isEmpty else { cadenceHolds += 1; return }
    filmSpare.append(previous)
    previous = current
    current = filmReady.removeFirst()
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
    guard weaveFields, !cadenceEngagedLocked, sourceFrameRate > 0, fieldRate > 0 else { return false }
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

  var weaveStarved: Bool {
    lock.lock()
    defer { lock.unlock() }
    return weaveStarvedLocked
  }

  /// mpv's reported frame rate for the current file, which can change when the file does.
  func updateSourceFrameRate(_ fps: Double) {
    lock.lock()
    if abs(fps - sourceFrameRate) > 0.001 {
      sourceFrameRate = fps
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
  private var pbos: [GLuint] = [0, 0]
  private var pboIndex = 0
  private var pboPrimed = false

  // MARK: - geometry

  /// How a picture of a different shape is mapped onto the SDI raster.
  var scaling: DeckLinkScaling = .fit

  /// Where a source of `sourceAspect` lands in a `w` x `h` target, in TOP-DOWN pixels.
  ///
  /// Both blits used to ignore this entirely and just stretch corner to corner, which is wrong in
  /// both directions: a 4:3 window went out as a 16:9 raster stretched, and a 16:9 raster came back
  /// into a 4:3 window squeezed on the x axis. Fullscreen made the second worse again, because the
  /// window then carries the DISPLAY's shape rather than the video's.
  ///
  /// `fill` deliberately returns a rectangle larger than the target; the blit clips it, which is the
  /// crop. `stretch` returns the target, which is the old behaviour.
  private func destinationRect(sourceAspect: Double, width w: Int, height h: Int)
      -> (left: Int, top: Int, right: Int, bottom: Int) {
    let full = (left: 0, top: 0, right: w, bottom: h)
    guard sourceAspect > 0, w > 0, h > 0, scaling != .stretch else { return full }
    let targetAspect = Double(w) / Double(h)
    if abs(sourceAspect - targetAspect) < 0.001 { return full }

    // Wider than the target: fit puts bars top and bottom, fill overflows left and right.
    let widerThanTarget = sourceAspect > targetAspect
    let matchWidth = (scaling == .fit) == widerThanTarget
    if matchWidth {
      let scaledHeight = Int((Double(w) / sourceAspect).rounded())
      let offset = (h - scaledHeight) / 2
      return (left: 0, top: offset, right: w, bottom: offset + scaledHeight)
    }
    let scaledWidth = Int((Double(h) * sourceAspect).rounded())
    let offset = (w - scaledWidth) / 2
    return (left: offset, top: 0, right: offset + scaledWidth, bottom: h)
  }

  /// Blit a source rectangle into a destination, flipping Y and honouring `scaling`.
  ///
  /// The destination Y range is inverted because GL reads from the bottom while the card and the
  /// window both want the top first. Bars are cleared to black rather than left as whatever the
  /// previous frame put there.
  private func blitPreservingAspect(sourceWidth sw: Int, sourceHeight sh: Int,
                                    destWidth dw: Int, destHeight dh: Int) {
    let rect = destinationRect(sourceAspect: sh > 0 ? Double(sw) / Double(sh) : 0,
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
                filmCadence: Bool = false, sourceFrameRate: Double = 0) {
    lock.lock()
    targetWidth = width
    targetHeight = height
    self.weaveFields = weaveFields
    self.upperFieldFirst = upperFieldFirst
    self.interlineFilter = interlineFilter
    self.filmCadence = filmCadence
    self.sourceFrameRate = sourceFrameRate
    fieldRate = weaveFields ? fps * 2.0 : fps
    fieldParity = 0
    cadenceAcc = 0
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
      for _ in 0...Self.filmQueueDepth {
        filmSpare.append([UInt8](repeating: 0, count: width * height * 4))
      }
    } else {
      current = []; previous = []
    }
    hasFrame = sameRaster
    frameComplete = !weaveFields
    capturedFrames = 0
    publishedFrames = 0
    hookCalls = 0
    nextSampleAt = 0
    updateSampleIntervalLocked()
    lock.unlock()
  }

  /// How often to read back. The cadence wants ONE sample per film frame, since it builds the
  /// fields itself; weaving without it wants one per field; anything else one per frame.
  /// Caller holds `lock`.
  private func updateSampleIntervalLocked() {
    let rate: Double
    if cadenceEngagedLocked {
      // One capture per source frame: the cadence spreads them across the fields itself.
      rate = sourceFrameRate
    } else if weaveStarvedLocked {
      // Whole frames, sampled at the OUTPUT rate rather than the source's.
      //
      // Sampling at the source rate was wrong in both directions. Above the output rate it handed
      // the card more frames than it could show, so which ones survived was down to whenever the
      // card happened to ask: 50p produced 50 published frames a second at a card taking 29.97, and
      // the twenty that went missing were an arbitrary twenty. Below it, the card was left to
      // repeat whatever it still had. Sampling at the output rate makes the drop or the repeat
      // regular, which is the ordinary frame-rate conversion this case should have been doing.
      rate = fieldRate / 2.0
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
      // Bound the queue. Dropping the OLDEST keeps latency fixed and loses the frame furthest from
      // what should be on screen, which only happens if the card has stopped consuming.
      while filmReady.count > Self.filmQueueDepth { filmSpare.append(filmReady.removeFirst()) }
      hasFrame = true
      frameComplete = true
      capturedFrames += 1
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
    if weaving { fieldParity ^= 1 }
    // Parity back at 0 means the second field of the pair has just landed.
    frameComplete = !weaving || fieldParity == 0
    capturedFrames += 1
    guard frameComplete else { return }

    // O(1): an Array is one reference to its storage, so this hands the feeder the frame just
    // finished and takes back the one it had, to assemble the next pair in.
    swap(&working, &published)
    hasFrame = true
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

  /// Must be called with the GL context current (ViewLayer teardown).
  func releaseGLResources() {
    if texture != 0 { glDeleteTextures(1, &texture); texture = 0 }
    if fbo != 0 { glDeleteFramebuffers(1, &fbo); fbo = 0 }
    if pbos[0] != 0 || pbos[1] != 0 { glDeleteBuffers(2, &pbos); pbos = [0, 0] }
    forgetGLResources()
  }

  /// Drop every handle without touching GL, for when the objects belong to a context that is no
  /// longer current and must not be deleted through this one.
  private func forgetGLResources() {
    texture = 0
    fbo = 0
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
                         destWidth: w, destHeight: h)

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
    lock.unlock()
    guard w > 0, h > 0, ensureFramebuffer(width: w, height: h) else { return false }
    hookCalls += 1

    var prevViewport: [GLint] = [0, 0, 0, 0]
    glGetIntegerv(GLenum(GL_VIEWPORT), &prevViewport)

    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
    glViewport(0, 0, GLsizei(w), GLsizei(h))

    // Unflipped, so the bottom-up glReadPixels below lands top-down for the card. The screen blit
    // afterwards flips it back for display.
    var flip: CInt = 0
    // 10, matching the RGB10_A2 target: this is what mpv dithers to, so leaving it at 8 threw the
    // extra bits away before they were ever written.
    var depth: CInt = 10
    var data = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(w), h: Int32(h), internal_format: 0)
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
                         destWidth: screenWidth, destHeight: screenHeight)
    scaling = previewScaling

    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), screenFBO)
    glViewport(prevViewport[0], prevViewport[1], GLsizei(prevViewport[2]), GLsizei(prevViewport[3]))
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
        if weaveFields || interlineFilter {
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
    let firstSource = current
    if stepCadenceSlot() { pullCadenceFrame() }
    let secondSource = current

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
      return true
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
