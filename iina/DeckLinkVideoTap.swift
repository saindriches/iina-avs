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
//  only through `buffer` under `lock`, so no GL call ever happens off the GL thread.
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
  /// Capture no faster than the mode's frame rate: with a 60 Hz panel feeding 23.98 SDI there is
  /// no point paying for a readback per screen refresh.
  private var minInterval: CFTimeInterval = 0
  private var lastCaptureAt: CFTimeInterval = 0

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

  /// Vertical low-pass before the lines are split into fields.
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

  /// Read pixels back synchronously instead of through the PBO ping-pong. The ping-pong hides the
  /// GPU stall by mapping the previous capture, which costs a full frame of delay: negligible
  /// behind the scheduled queue, dominant without it. A direct HD readback is a couple of
  /// milliseconds, affordable on the GL thread.
  var immediateReadback = false

  private let lock = NSLock()
  private var buffer = [UInt8]()
  /// Landing area for a readback, so weaving can merge into `buffer` without destroying the field
  /// already sitting there.
  private var scratch = [UInt8]()
  private var hasFrame = false

  private(set) var capturedFrames = 0

  var isActive: Bool { targetWidth > 0 && targetHeight > 0 }

  // MARK: - lifecycle

  func activate(width: Int, height: Int, fps: Double,
                weaveFields: Bool = false, upperFieldFirst: Bool = true,
                interlineFilter: Bool = false) {
    lock.lock()
    targetWidth = width
    targetHeight = height
    self.weaveFields = weaveFields
    self.upperFieldFirst = upperFieldFirst
    self.interlineFilter = interlineFilter
    fieldParity = 0
    // Sample at the FIELD rate when weaving, since each field is its own moment. `fps` is the frame
    // rate the card reports, so 1080i59.94 arrives here as 29.97 and must be captured at 59.94.
    let sampleRate = weaveFields ? fps * 2.0 : fps
    minInterval = sampleRate > 0 ? (1.0 / sampleRate) * 0.9 : 0   // 0.9 so jitter never starves the card
    buffer = [UInt8](repeating: 0, count: width * height * 4)
    hasFrame = false
    capturedFrames = 0
    lastCaptureAt = 0
    lock.unlock()
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

  /// Take a readback into the published buffer. Whole frame when progressive; every other line, and
  /// publish only on the second of a pair, when weaving. Caller holds `lock`.
  private func store(from src: UnsafeRawPointer, width w: Int, height h: Int) {
    let rowBytes = w * 4
    buffer.withUnsafeMutableBytes { raw in
      guard let dstBase = raw.baseAddress else { return }
      let srcWords = src.assumingMemoryBound(to: UInt32.self)
      let dstWords = dstBase.assumingMemoryBound(to: UInt32.self)
      // Rows this call is responsible for: every other one when weaving, all of them otherwise.
      let first = weaveFields ? fieldStartRow() : 0
      let step = weaveFields ? 2 : 1
      guard interlineFilter else {
        guard weaveFields else {
          memcpy(dstBase, src, rowBytes * h)
          return
        }
        var y = first
        while y < h {
          memcpy(dstBase.advanced(by: y * rowBytes), src.advanced(by: y * rowBytes), rowBytes)
          y += 2
        }
        return
      }
      var y = first
      while y < h {
        filteredRow(srcWords, dstWords.advanced(by: y * w), width: w, y: y, height: h)
        y += step
      }
    }
    guard weaveFields else {
      hasFrame = true
      capturedFrames += 1
      return
    }
    fieldParity ^= 1
    if fieldParity == 0 {   // the pair is complete, so the frame is now two distinct moments
      hasFrame = true
      capturedFrames += 1
    }
  }

  /// GL teardown has to happen on the GL thread, so this only marks the tap inactive; the FBO is
  /// released on the next capture call or when the layer goes away.
  func deactivate() {
    lock.lock()
    targetWidth = 0
    targetHeight = 0
    hasFrame = false
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
    let w = targetWidth, h = targetHeight, interval = minInterval
    lock.unlock()
    guard w > 0, h > 0 else { return }

    let now = CACurrentMediaTime()
    guard now - lastCaptureAt >= interval else { return }
    lastCaptureAt = now

    guard ensureFramebuffer(width: w, height: h) else { return }

    // Save the caller's binding and viewport; ViewLayer keeps rendering into its own FBO after us.
    var prevDrawFBO: GLint = 0
    var prevViewport: [GLint] = [0, 0, 0, 0]
    glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &prevDrawFBO)
    glGetIntegerv(GLenum(GL_VIEWPORT), &prevViewport)

    // Scale IINA's rendered frame into ours. The destination Y range is inverted (dstY0 = h,
    // dstY1 = 0) to undo the on-screen pass's FLIP_Y, so that glReadPixels, which reads bottom-up,
    // hands back rows top-down as the card wants.
    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), sourceFBO)
    glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
    glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), fbo)
    glBlitFramebuffer(0, 0, GLint(sourceWidth), GLint(sourceHeight),
                      0, GLint(h), GLint(w), 0,
                      GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR))

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
    // time, and progressive output is unaffected because `minInterval` gating stays off for it.
    var takeIt = true
    if weaveFields {
      let now = CACurrentMediaTime()
      takeIt = now - lastCaptureAt >= minInterval
      if takeIt { lastCaptureAt = now }
    }
    if takeIt { readBackCurrentFBO(width: w, height: h) }

    // Preview to the window from the same render. Y is inverted here because the SDI render is
    // unflipped and the screen expects the on-screen orientation.
    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), fbo)
    glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
    glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), screenFBO)
    glBlitFramebuffer(0, 0, GLint(w), GLint(h),
                      0, GLint(screenHeight), GLint(screenWidth), 0,
                      GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR))

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
      if buffer.count == w * h * 4 {
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
          buffer.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
              glReadPixels(0, 0, GLsizei(w), GLsizei(h), GLenum(GL_BGRA),
                           GLenum(GL_UNSIGNED_INT_2_10_10_10_REV), base)
            }
          }
          hasFrame = true
          capturedFrames += 1
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
        if buffer.count == byteCount {   // guard a deactivate() that landed mid-render
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

  /// Copy the most recent captured frame into the feeder's buffer.
  /// Returns false when nothing has been captured yet, which tells the feeder to repeat.
  func copyLatest(into destination: UnsafeMutableRawPointer,
                  width: Int, height: Int, stride: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard hasFrame, width == targetWidth, height == targetHeight,
          buffer.count == width * height * 4 else { return false }
    let rowBytes = width * 4
    buffer.withUnsafeBytes { raw in
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
