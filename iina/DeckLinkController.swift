//
//  DeckLinkController.swift
//  iina
//
//  Owns the DeckLink output session and the state the menu reflects. One shared instance: the card
//  is a single exclusive resource, so routing is an app-level setting rather than per-player.
//
//  The menu is built in MenuController (see `updateDeckLinkMenu`), following the same
//  repopulate-on-open idiom as the audio device menu.
//

import Cocoa
import OpenGL.GL

/// Persisted across launches so a chosen route survives a restart.
private struct Keys {
  static let deviceID = "decklink.deviceIdentifier"
  static let modeIndex = "decklink.modeIndex"
  static let pixelFormat = "decklink.pixelFormat"
  static let range = "decklink.range"
  static let releaseOnResignActive = "decklink.releaseOnResignActive"
  static let routingEnabled = "decklink.routingEnabled"
  static let renderAtOutputRes = "decklink.renderAtOutputResolution"
  static let lowLatency = "decklink.lowLatency"
  static let sdiLink = "decklink.sdiLink"
  static let use444 = "decklink.use444SDI"
  static let levelA = "decklink.levelA"
  static let fieldMode = "decklink.fieldMode"
  static let fieldOrder = "decklink.fieldOrder"
  static let interlineFilter = "decklink.interlineFilter"
  static let filmCadence = "decklink.filmCadence"
  static let scaling = "decklink.scaling"
  static let compensateAudio = "decklink.compensateAudio"
  static let testPattern = "decklink.testPattern"
  static let testOpacity = "decklink.testOpacity"
}

/// How the two fields of an interlaced frame are produced.
enum DeckLinkFieldMode: Int {
  /// Both fields are one instant: a progressive frame carried in an interlaced raster. Right for
  /// film and any progressive source, and what this output has always produced.
  case psf = 0
  /// Each field is its own moment, a field period apart, which is what a CRT's scan actually shows.
  /// Only buys anything when the source itself carries motion at the field rate.
  case trueInterlace = 1
  /// The source frames ALREADY hold two fields, woven together by whoever encoded them. Broadcast
  /// material published as progressive, and most bad rips of it, look like this: every frame combs
  /// on motion because its odd and even lines are different moments.
  ///
  /// Nothing needs building for these, and building anything is destructive. Pass the frame through
  /// untouched and the card splits it by row parity, which recovers exactly the fields that were
  /// encoded. mpv never hands out fields, only frames, so this is the only way to get genuinely
  /// interlaced content back out as interlace.
  case sourceInterlaced = 2
}

/// Patterns that answer a question the picture cannot.
enum DeckLinkTestPattern: Int {
  case off = 0
  /// A bar advancing one step per field: the only way to tell a wrong field order from a dropped
  /// field, a repeated frame or a wandering cadence, which all just look like bad motion.
  case fieldOrder = 1
  /// Crosshatch, centre cross, circle and the two safe-area boxes. Geometry and linearity on a CRT
  /// are adjustable and they drift; the circle shows whether the pixel aspect survived the chain,
  /// and the boxes show how much the tube is really eating.
  case geometry = 2
  /// Single-line detail, which is what interline twitter destroys. Shows what the Interline Filter
  /// buys and what it costs.
  case twitter = 3
  /// Staircase over a black-level strip, for setting brightness.
  case greyscale = 4
  /// 75% colour bars.
  case colourBars = 5
}

/// What to do when the picture and the SDI raster are not the same shape.
enum DeckLinkScaling: Int {
  /// Whole picture, bars where the shapes differ. What a broadcast chain expects, and the default.
  case fit = 0
  /// Fill the raster and lose what hangs over the edges.
  case fill = 1
  /// Distort to fill. Almost never right, but it is what this did before there was a choice, so it
  /// stays available.
  case stretch = 2
}

/// Which of the two fields the card transmits first, and so which one carries the earlier moment.
///
/// Only True Interlace is affected: PsF samples both fields at one instant, so their order cannot
/// be heard from. Getting it backwards makes motion advance two steps and fall back one, at the
/// field rate, which reads as a vibration on any pan.
enum DeckLinkFieldOrder: Int {
  /// Whatever the driver reports for the mode, which is right for a conforming chain.
  case auto = 0
  case upperFirst = 1
  case lowerFirst = 2
}

class DeckLinkController {

  static let shared = DeckLinkController()

  /// Posted whenever routing starts, stops, or fails, so any open menu/UI can refresh.
  static let stateDidChange = Notification.Name("iina.decklink.stateDidChange")

  private let output = DeckLinkOutput()
  /// Pulls mpv's rendered picture out of IINA's render context (see DeckLinkVideoTap).
  let tap = DeckLinkVideoTap()

  /// Device the user picked, by identifier rather than index: indices shift on hot-plug.
  private(set) var selectedDeviceID: String?
  private(set) var selectedModeIndex: Int
  private(set) var pixelFormat: DeckLinkPixelFormat
  private(set) var range: DeckLinkVideoRange

  /// Render at the SDI mode's resolution and treat the window as a preview of that, instead of
  /// rendering for the window and scaling down for the card. Better SDI quality and less total
  /// work, at the cost of the window showing an upscaled copy when it is larger than the mode.
  var renderAtOutputResolution: Bool {
    didSet { UserDefaults.standard.set(renderAtOutputResolution, forKey: Keys.renderAtOutputRes) }
  }

  /// SDI link configuration. 4:4:4 and high bit depths exceed what a single HD-SDI link carries, so
  /// dual or quad link is what makes them possible on smaller formats.
  private(set) var sdiLink: DeckLinkSDILink
  /// 4:4:4 on the wire instead of 4:2:2, so chroma is not subsampled. Pair it with a 10-bit RGB
  /// pixel format; on HD rasters it generally needs dual link for the bandwidth.
  private(set) var use444: Bool
  /// SMPTE Level A signalling for 3G-SDI. Level B is the default and more widely accepted; some
  /// monitors and routers want A.
  private(set) var levelA: Bool

  /// PsF or genuinely interlaced fields, for modes with an interlaced raster. Ignored by progressive
  /// modes. Defaults to PsF, which is what the output has always produced, so an existing setup is
  /// unchanged until this is asked for.
  private(set) var fieldMode: DeckLinkFieldMode

  /// Override for which field goes out first. Defaults to `auto`, so a chain that agrees with the
  /// driver behaves exactly as before.
  private(set) var fieldOrder: DeckLinkFieldOrder

  /// Vertical band-limit before lines are split into fields, against interline twitter on a CRT.
  /// Costs vertical resolution, so it is off unless asked for, and it is only offered on an
  /// interlaced raster.
  private(set) var interlineFilter: Bool

  /// Lay 23.976 film onto the 59.94-field raster as broadcast does, rather than resampling the
  /// window. See DeckLinkVideoTap's film cadence section for what it produces and why.
  ///
  /// Needs True Interlace. It used to need the scheduled path as well, because Low Latency asked
  /// for a frame whenever IINA pushed one, so the output rate was the SOURCE rate and a cadence
  /// that must emit five frames for every four had nowhere to put the extra one. Low Latency is now
  /// paced by the card's own clock, so both paths tick at the output rate and the cadence runs on
  /// either.
  private(set) var filmCadence: Bool

  /// How a picture of a different shape is mapped onto the SDI raster.
  private(set) var scaling: DeckLinkScaling

  /// True while the cadence is not merely asked for but running, which needs a source that really
  /// is 2/5 of the field rate. Surfaced so the panel can say so instead of leaving it ambiguous.
  var cadenceEngaged: Bool { tap.cadenceEngaged }

  /// True when weaving was asked for but the source cannot fill the field rate, so whole frames are
  /// going out instead. Surfaced because the fallback is otherwise indistinguishable from weaving
  /// that simply is not working.
  var weaveStarved: Bool { tap.weaveStarved }

  /// Times the cadence wanted a film frame and had none. Should stay at zero.
  var cadenceHolds: Int { tap.cadenceHolds }

  /// Frame rate of the file being shown, as the tap last saw it.
  var sourceFrameRate: Double { tap.sourceRate }

  /// What mpv reports against what the draw loop actually delivers. They disagree on soft telecined
  /// files, where container-fps is the display rate rather than the frames handed over.
  var sourceRates: (reported: Double, effective: Double) { tap.reportedVersusObserved }

  /// Height of the decoded video, and whether mpv is deinterlacing. Both matter only for
  /// `sourceInterlaced`, and both silently ruin it, which is why they are polled and reported.
  ///
  /// Any vertical resampling blends adjacent lines, and adjacent lines are the two different
  /// moments this mode exists to keep apart: a 2160p source scaled to a 1080 raster arrives with
  /// its fields already averaged together and nothing downstream can separate them again. A
  /// deinterlacer does the same thing deliberately.
  private(set) var sourceHeight = 0
  private(set) var sourceDeinterlacing = false

  /// True when the source can actually survive being passed through as fields.
  var sourceInterlaceClean: Bool {
    guard let mode = selectedMode else { return false }
    return sourceHeight == mode.height && !sourceDeinterlacing
  }

  /// Frames sitting in the card, from the driver.
  var bufferedFrames: Int { output.bufferedFrames }

  /// How far behind the window the SDI picture is, in seconds.
  ///
  /// Part measured, part exact arithmetic, no guessing: the tap knows what it is holding, the
  /// driver reports what the card is holding, and one more frame covers the one being scanned out.
  /// Which is why the scheduled path reads an order of magnitude higher than Low Latency; that
  /// queue is the whole difference between them.
  var estimatedLatency: Double {
    guard let mode = selectedMode, mode.fps > 0 else { return 0 }
    return tap.pipelineDelay + (Double(output.bufferedFrames) + 1.0) / mode.fps
  }

  /// The same figure, smoothed.
  ///
  /// The raw number steps by a whole frame whenever the queue gains or loses one, which at 24 fps
  /// is 42 ms: past the threshold below, so audio-delay would be rewritten every time the queue
  /// breathed. Averaging leaves the audio alone unless the latency has genuinely moved.
  private(set) var smoothedLatency: Double = 0

  /// Delay the audio to match, so lip sync holds on the reference monitor rather than on the Mac.
  ///
  /// The picture reaches the SDI monitor later than it reaches the window, but the audio does not,
  /// so anything watched on the monitor drifts by exactly the video latency. mpv's audio-delay is
  /// the right lever; positive delays audio, which is the direction needed here.
  private(set) var compensateAudio: Bool
  /// What audio-delay was before we touched it, so it can be handed back untouched.
  private var savedAudioDelay: Double?
  /// The value we last wrote, so the property observer can tell our write from the user's.
  private var audioDelayWeWrote: Double?

  /// Whether a change to audio-delay deserves an OSD. Ours do not: the compensation rewrites the
  /// value whenever the measured latency moves, and flashing "Audio Delay" over the video for a
  /// change the user did not make is just noise. Matching on the value rather than holding a flag
  /// keeps it self-limiting, since the observer arrives asynchronously and might not arrive at all.
  func shouldShowAudioDelayOSD(_ value: Double) -> Bool {
    if let ours = audioDelayWeWrote, abs(ours - value) < 0.0005 {
      audioDelayWeWrote = nil
      return false
    }
    return true
  }

  private func writeAudioDelay(_ value: Double, to mpv: MPVController) {
    audioDelayWeWrote = value
    mpv.setDouble(MPVOption.Audio.audioDelay, value)
  }

  /// Polls the routed player for its frame rate while output runs. On the main thread and once a
  /// second: mpv property reads must not happen on the GL thread, and the answer only changes when
  /// the file does.
  private var sourceRateTimer: Timer?

  // MARK: - which player feeds the card

  /// The player whose picture goes to the card. One card, one source: without this every open
  /// player's GL thread drove the output hooks, so two videos interleaved their frames on the wire
  /// and, in output-first mode, every window skipped its own render to show the SDI preview.
  ///
  /// Weak, so a closed player releases it and the next window to come forward takes over.
  private(set) weak var routedPlayer: PlayerCore?

  /// Follow the frontmost IINA window. Deliberately driven by window activation WITHIN IINA and not
  /// by app activation: switching between IINA's own windows should re-point the card, but IINA
  /// losing focus to another app should not, because that case belongs to `releaseWhenInactive`.
  func windowBecameMain(_ player: PlayerCore) {
    guard routedPlayer !== player else { return }
    routedPlayer = player
    // The old window's last frame is left in place rather than cleared: the new source overwrites it
    // within a frame or two, and blanking would put a black flash on the monitor at every switch.
    // The tap scales to the output mode, so a differently sized source needs no handling here.
    notifyChanged()
  }

  /// True when `player` is the one currently feeding the card. A player that has never been
  /// frontmost (or after the routed one closed) adopts the route rather than leaving the card idle.
  private func claimsRoute(_ player: PlayerCore) -> Bool {
    if let routed = routedPlayer { return routed === player }
    routedPlayer = player
    return true
  }

  /// Whether this player must render without display colour management, because its picture is
  /// going to the card. See `VideoView.setBypassColorManagementForDeckLink`.
  func bypassesColorManagement(for player: PlayerCore) -> Bool {
    output.isRunning && routedPlayer === player
  }

  private var capabilityCache: [String: DeckLinkCapabilities] = [:]

  /// Enumerating the hardware is not cheap and is not safe to do freely: every call builds a
  /// DeckLink iterator, connects to the driver core through IOKit, and then asks each of the forty
  /// modes three times whether it supports a pixel format. Doing that on a repeating timer, next to
  /// a running output, crashed the app in IOServiceGetMatchingServices and churned IOKit ports.
  ///
  /// So enumeration happens on state changes and is cached in between. Anything polling, the status
  /// line above all, must read these rather than ask the driver.
  private var deviceCache: [DeckLinkDevice]?
  /// Also an enumeration: it builds an iterator, which connects to the driver.
  private var driverAvailableCache: Bool?
  private var modeCache: [String: [DeckLinkMode]] = [:]
  /// Doubly optional: the outer nil means "not resolved yet", the inner one "no mode selected".
  private var selectedModeCache: DeckLinkMode??

  /// Drop what was read from the hardware, so the next read sees a device that has been plugged in
  /// or removed. Call from the event-rate paths (a panel or menu rebuild), never from a timer.
  func invalidateHardwareCaches() {
    // Never re-read the hardware while an output session is open. The crash this guards against had
    // a session live, packing frames on one thread, while the main thread built an iterator and
    // called ConnectToDriverCore; a dispatch worker then died in _dispatch_bug_kevent_vanished,
    // which is libdispatch aborting because a source's port was closed underneath it. Enumeration
    // tears down and rebuilds exactly those ports inside DeckLinkAPI. Doing it less often made it
    // rarer; not doing it during a session removes the window.
    //
    // The cost is that a card plugged in mid-session is not noticed until output stops, which is
    // the right trade: the card in use cannot change anyway.
    guard !output.isRunning else { return }
    deviceCache = nil
    driverAvailableCache = nil
    modeCache.removeAll()
    selectedModeCache = nil
  }

  /// What the selected device will actually accept, read from the hardware and then cached.
  var capabilities: DeckLinkCapabilities? {
    guard let device = selectedDevice else { return nil }
    if let cached = capabilityCache[device.identifier] { return cached }
    guard let caps = DeckLinkOutput.capabilities(forDeviceAt: device.index) else { return nil }
    capabilityCache[device.identifier] = caps
    return caps
  }

  /// Immediate display instead of scheduled playback: each captured frame goes to the card's next
  /// output refresh. Scheduled playback is a queue by design (readback, the ready queue, and the
  /// card's own depth), so it costs several frames of delay.
  ///
  /// The card clocks the SDI signal either way; what this gives up is the queue that absorbs jitter
  /// in the frames we produce. Our frames are driven by the display refresh and mpv's clock, neither
  /// locked to the card, so without that cushion a mismatch surfaces as an occasional duplicate or
  /// skip. Driving capture from the card's clock would remove the penalty rather than the queue.
  var lowLatency: Bool {
    didSet {
      UserDefaults.standard.set(lowLatency, forKey: Keys.lowLatency)
      restartIfNeeded()
    }
  }

  /// Release the device when IINA is not frontmost, so another app can take the card.
  var releaseWhenInactive: Bool {
    didSet {
      UserDefaults.standard.set(releaseWhenInactive, forKey: Keys.releaseOnResignActive)
      updateActivityObservers()
    }
  }

  /// What the user asked for, which is not the same as whether the device is currently open: the
  /// card can be unplugged, busy, or handed to another app while IINA is in the background. Intent
  /// is persisted so routing simply resumes, instead of making the user re-check the hardware and
  /// toggle it on at every launch.
  private(set) var routingEnabled: Bool

  /// Non-nil while a start attempt has failed, so the menu can say why instead of silently doing
  /// nothing. Cleared on the next successful start.
  private(set) var lastError: String?

  var isRunning: Bool { output.isRunning }
  var isDriverAvailable: Bool {
    if let cached = driverAvailableCache { return cached }
    let available = DeckLinkOutput.isDriverAvailable()
    driverAvailableCache = available
    return available
  }

  /// Frames the device reported late or dropped in this session. Surfaced so the UI can be honest
  /// about whether playout is keeping up.
  var lateFrames: Int { output.lateFrames }
  var droppedFrames: Int { output.droppedFrames }
  var scheduledFrames: Int { output.scheduledFrames }
  var resyncCount: Int { output.resyncCount }
  var repeatCount: Int { output.repeatCount }
  var capturedFrames: Int { tap.capturedFrames }
  var publishedFrames: Int { tap.publishedFrames }
  var hookCalls: Int { tap.hookCalls }

  private var wasRunningBeforeResign = false
  private var wasRunningBeforeSleep = false

  /// Token from ProcessInfo.beginActivity, held for as long as routing is live. Without it macOS
  /// applies App Nap once IINA is not frontmost: timers coalesce and background threads are
  /// throttled, so the tap stops producing frames and the monitor freezes until IINA is focused
  /// again. `.latencyCritical` is the option that marks this as time-sensitive media work.
  private var activityToken: NSObjectProtocol?

  private init() {
    let d = UserDefaults.standard
    selectedDeviceID = d.string(forKey: Keys.deviceID)
    selectedModeIndex = d.object(forKey: Keys.modeIndex) as? Int ?? -1
    pixelFormat = DeckLinkPixelFormat(rawValue: d.object(forKey: Keys.pixelFormat) as? Int ?? 0) ?? .format8BitYUV
    range = DeckLinkVideoRange(rawValue: d.object(forKey: Keys.range) as? Int ?? 0) ?? .SMPTE
    releaseWhenInactive = d.bool(forKey: Keys.releaseOnResignActive)
    routingEnabled = d.bool(forKey: Keys.routingEnabled)
    renderAtOutputResolution = d.bool(forKey: Keys.renderAtOutputRes)
    lowLatency = d.bool(forKey: Keys.lowLatency)
    sdiLink = DeckLinkSDILink(rawValue: d.object(forKey: Keys.sdiLink) as? Int ?? 0) ?? .single
    use444 = d.bool(forKey: Keys.use444)
    levelA = d.bool(forKey: Keys.levelA)
    fieldMode = DeckLinkFieldMode(rawValue: d.object(forKey: Keys.fieldMode) as? Int ?? 0) ?? .psf
    fieldOrder = DeckLinkFieldOrder(rawValue: d.object(forKey: Keys.fieldOrder) as? Int ?? 0) ?? .auto
    interlineFilter = d.bool(forKey: Keys.interlineFilter)
    // On unless explicitly turned off. It used to be a film-only trick worth opting into; now it is
    // simply the right way to put any source onto a field raster, and the alternative throws away
    // either moments or motion.
    filmCadence = d.object(forKey: Keys.filmCadence) as? Bool ?? true
    scaling = DeckLinkScaling(rawValue: d.object(forKey: Keys.scaling) as? Int ?? 0) ?? .fit
    compensateAudio = d.bool(forKey: Keys.compensateAudio)
    // Pattern is deliberately not persisted; coming back to a test card instead of a picture would
    // be its own bug report. The opacity is, since it is a preference rather than a state.
    tap.testOpacity = d.object(forKey: Keys.testOpacity) as? Double ?? 1.0
    updateActivityObservers()
    observeActivationForRestore()
    observeSleepWake()
  }

  // MARK: - enumeration

  var devices: [DeckLinkDevice] {
    if let cached = deviceCache { return cached }
    let list = DeckLinkOutput.devices()
    deviceCache = list
    return list
  }

  func modes(forDeviceID identifier: String?) -> [DeckLinkMode] {
    guard let device = device(withID: identifier) else { return [] }
    if let cached = modeCache[device.identifier] { return cached }
    let list = DeckLinkOutput.modes(forDeviceAt: device.index)
    modeCache[device.identifier] = list
    return list
  }

  func device(withID identifier: String?) -> DeckLinkDevice? {
    guard let identifier = identifier else { return nil }
    return devices.first { $0.identifier == identifier }
  }

  var selectedDevice: DeckLinkDevice? { device(withID: selectedDeviceID) }

  /// Cached, because the status line reads it every second and resolving it walks the driver.
  var selectedMode: DeckLinkMode? {
    if let cached = selectedModeCache { return cached }
    let resolved = modes(forDeviceID: selectedDeviceID).first { $0.index == selectedModeIndex }
    selectedModeCache = .some(resolved)
    return resolved
  }

  /// True when this mode can carry the currently chosen pixel format. Used to disable menu rows
  /// rather than let the user pick a combination the device will refuse.
  func mode(_ mode: DeckLinkMode, supports format: DeckLinkPixelFormat) -> Bool {
    switch format {
    case .format10BitYUV: return mode.supports10BitYUV
    case .format10BitRGB: return mode.supports10BitRGB
    default: return mode.supports8BitYUV
    }
  }

  // MARK: - selection
  /// With a single device attached, pick it rather than making the user select before any modes
  /// appear. Called when the menu opens; a no-op once anything has been chosen.
  func ensureDefaultSelection() {
    guard selectedDeviceID == nil else { return }
    let all = devices
    guard all.count == 1, let only = all.first else { return }
    selectDevice(only.identifier)
  }


  func selectDevice(_ identifier: String?) {
    guard identifier != selectedDeviceID else { return }
    selectedDeviceID = identifier
    UserDefaults.standard.set(identifier, forKey: Keys.deviceID)
    selectedModeCache = nil
    // Mode indices are per-device, so a device change invalidates the chosen mode.
    selectedModeIndex = -1
    UserDefaults.standard.set(-1, forKey: Keys.modeIndex)
    restartIfNeeded()
  }

  func selectMode(_ index: Int) {
    guard index != selectedModeIndex else { return }
    selectedModeIndex = index
    UserDefaults.standard.set(index, forKey: Keys.modeIndex)
    selectedModeCache = nil
    restartIfNeeded()
  }

  func selectPixelFormat(_ format: DeckLinkPixelFormat) {
    guard format != pixelFormat else { return }
    pixelFormat = format
    UserDefaults.standard.set(format.rawValue, forKey: Keys.pixelFormat)
    restartIfNeeded()
  }

  func selectSDILink(_ link: DeckLinkSDILink) {
    guard link != sdiLink else { return }
    sdiLink = link
    UserDefaults.standard.set(link.rawValue, forKey: Keys.sdiLink)
    restartIfNeeded()
  }

  func setUse444(_ on: Bool) {
    guard on != use444 else { return }
    use444 = on
    UserDefaults.standard.set(on, forKey: Keys.use444)
    restartIfNeeded()
  }

  func setFieldMode(_ mode: DeckLinkFieldMode) {
    guard mode != fieldMode else { return }
    fieldMode = mode
    UserDefaults.standard.set(mode.rawValue, forKey: Keys.fieldMode)
    reconfigureTapIfRunning()
  }

  func setFieldOrder(_ order: DeckLinkFieldOrder) {
    guard order != fieldOrder else { return }
    fieldOrder = order
    UserDefaults.standard.set(order.rawValue, forKey: Keys.fieldOrder)
    reconfigureTapIfRunning()
  }

  /// Which field carries the earlier moment, after any override.
  func upperFieldFirst(for mode: DeckLinkMode) -> Bool {
    switch fieldOrder {
    case .auto: return mode.upperFieldFirst
    case .upperFirst: return true
    case .lowerFirst: return false
    }
  }

  func setInterlineFilter(_ on: Bool) {
    guard on != interlineFilter else { return }
    interlineFilter = on
    UserDefaults.standard.set(on, forKey: Keys.interlineFilter)
    reconfigureTapIfRunning()
  }

  /// Replace the picture with a bar that steps once per field, so field order can be read off the
  /// monitor instead of inferred from how motion feels. Not persisted: it is a diagnostic, and
  /// coming back to a bar instead of a picture would be its own bug report.
  var testPattern: DeckLinkTestPattern {
    get { tap.testPattern }
    set { tap.testPattern = newValue; notifyChanged() }
  }

  /// How strongly the pattern is mixed over the picture. Below 1 the two are blended, which is what
  /// makes the geometry pattern useful: a safe-area box means something against the shot it is
  /// meant to contain.
  var testOpacity: Double {
    get { tap.testOpacity }
    set { tap.testOpacity = max(0.05, min(1.0, newValue)); notifyChanged() }
  }

  func setScaling(_ mode: DeckLinkScaling) {
    guard mode != scaling else { return }
    scaling = mode
    UserDefaults.standard.set(mode.rawValue, forKey: Keys.scaling)
    tap.scaling = mode   // takes effect on the next frame; no need to restart the device
    notifyChanged()
  }

  func setCompensateAudio(_ on: Bool) {
    guard on != compensateAudio else { return }
    compensateAudio = on
    UserDefaults.standard.set(on, forKey: Keys.compensateAudio)
    updateAudioCompensation()
    notifyChanged()
  }

  /// Hold the audio delay at the current video latency, or put back what was there before.
  ///
  /// Driven from the same one second tick as the source rate, and for the same reason: mpv property
  /// writes belong on the main thread, and the number moves slowly. Only rewritten when it has
  /// moved more than 5 ms, so the user can still nudge audio-delay themselves without a timer
  /// fighting them every second.
  private func updateAudioCompensation() {
    guard let player = routedPlayer, player.info.state.loaded, let mpv = player.mpv else { return }
    guard compensateAudio, output.isRunning else {
      if let saved = savedAudioDelay {
        writeAudioDelay(saved, to: mpv)
        savedAudioDelay = nil
      }
      return
    }
    if savedAudioDelay == nil { savedAudioDelay = mpv.getDouble(MPVOption.Audio.audioDelay) }
    let target = smoothedLatency
    if abs(mpv.getDouble(MPVOption.Audio.audioDelay) - target) > 0.005 {
      writeAudioDelay(target, to: mpv)
    }
  }

  func setFilmCadence(_ on: Bool) {
    guard on != filmCadence else { return }
    filmCadence = on
    UserDefaults.standard.set(on, forKey: Keys.filmCadence)
    reconfigureTapIfRunning()
  }

  /// Whether the cadence can be offered at all for the current setup.
  var filmCadenceAvailable: Bool {
    (selectedMode?.isInterlaced ?? false) && fieldMode == .trueInterlace
  }

  /// Frame rate of the file the routed player is showing, or 0 when there is nothing to ask.
  ///
  /// The state check is not optional. This runs on a timer, and the window it polls can close or
  /// quit underneath it; PlayerCore is explicit that reading a property from a core that has shut
  /// down is not permitted and can crash. Anything below `loaded` has no file to report anyway.
  private func routedSourceFrameRate() -> Double {
    guard let player = routedPlayer, player.info.state.loaded, let mpv = player.mpv else { return 0 }
    let fps = mpv.getDouble(MPVProperty.containerFps)
    return fps.isFinite && fps > 0 ? fps : 0
  }

  /// Read what would quietly break a field passthrough. Main thread, once a second, same as the
  /// rate: these only change when the file or a filter does.
  private func refreshSourceGeometry() {
    guard let player = routedPlayer, player.info.state.loaded, let mpv = player.mpv else {
      sourceHeight = 0
      sourceDeinterlacing = false
      return
    }
    sourceHeight = mpv.getInt(MPVProperty.videoParamsH)
    sourceDeinterlacing = mpv.getFlag(MPVOption.Video.deinterlace)
  }

  private func startSourceRateTimer() {
    sourceRateTimer?.invalidate()
    tap.updateSourceFrameRate(routedSourceFrameRate())
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      self.tap.updateSourceFrameRate(self.routedSourceFrameRate())
      self.refreshSourceGeometry()
      let now = self.estimatedLatency
      self.smoothedLatency = self.smoothedLatency > 0 ? self.smoothedLatency * 0.7 + now * 0.3 : now
      self.updateAudioCompensation()
    }
    RunLoop.main.add(timer, forMode: .common)
    sourceRateTimer = timer
  }

  private func stopSourceRateTimer() {
    sourceRateTimer?.invalidate()
    sourceRateTimer = nil
    updateAudioCompensation()   // output is going away, so give the audio delay back
  }

  func setLevelA(_ on: Bool) {
    guard on != levelA else { return }
    levelA = on
    UserDefaults.standard.set(on, forKey: Keys.levelA)
    restartIfNeeded()
  }

  func selectRange(_ newRange: DeckLinkVideoRange) {
    guard newRange != range else { return }
    range = newRange
    UserDefaults.standard.set(newRange.rawValue, forKey: Keys.range)
    restartIfNeeded()
  }

  // MARK: - session

  /// Whether a start is even possible right now. The menu uses this to keep the toggle disabled
  /// rather than offering an action that can only fail.
  var canStart: Bool { selectedDevice != nil && selectedMode != nil }

  /// User asked for output. Records the intent even if the attempt fails, so a device that is
  /// merely busy right now will be picked up by the next restore.
  @discardableResult
  func start() -> Bool {
    setRoutingEnabled(true)
    return startDevice()
  }

  @discardableResult
  private func startDevice() -> Bool {
    guard !output.isRunning else { return true }
    guard let device = selectedDevice, let mode = selectedMode else {
      lastError = "Choose a device and a video mode first."
      notifyChanged()
      return false
    }
    guard self.mode(mode, supports: pixelFormat) else {
      lastError = "\(mode.name) does not support the selected pixel format."
      notifyChanged()
      return false
    }

    // The tap must be live before the device opens: preroll asks the provider for frames straight
    // away, and an inactive tap fails copyLatest's size guard. Preroll would then schedule nothing,
    // and a feeder driven by completion callbacks cannot start from an empty queue.
    // The cadence needs the card to clock the consumer, so it is only offered off the low-latency
    // path. Asking for it elsewhere leaves ordinary weaving rather than half-applying it.
    armTap(for: mode)

    var ok = false
    do {
      try output.start(withDeviceIndex: device.index,
                       modeIndex: mode.index,
                       pixelFormat: pixelFormat,
                       range: range,
                       link: sdiLink,
                       use444: use444,
                       levelA: levelA,
                       lowLatency: lowLatency,
                       provider: frameProvider())
      ok = true
      lastError = nil
      beginBackgroundActivity()
      startSourceRateTimer()
    } catch {
      lastError = error.localizedDescription
      tap.deactivate()   // device never opened; nothing should keep capturing for it
    }
    notifyChanged()
    return ok
  }

  /// Point the tap at a mode and the current processing settings.
  ///
  /// Weave only when the raster is genuinely interlaced AND it was asked for: PsF rasters are one
  /// instant by definition, and a progressive mode must not be touched. The filter applies to any
  /// interlaced raster, PsF included, since a CRT scans alternate lines either way. The cadence
  /// additionally needs the card to clock the consumer, so it is off the low-latency path.
  private func armTap(for mode: DeckLinkMode) {
    let weave = mode.isInterlaced && fieldMode == .trueInterlace
    // Pass-through wants the frame exactly as decoded: no weaving, no cadence, and above all no
    // filter, since the filter averages the rows either side of each line and those rows are the
    // other field.
    tap.sourceInterlaced = mode.isInterlaced && fieldMode == .sourceInterlaced
    tap.swapSourceFields = fieldOrder == .lowerFirst
    // Immediate readback is synchronous, so it stalls the GL thread until the GPU is done. Weaving
    // already needs twice as many readbacks, and at field rate that stall is what stops the pair
    // completing in time, which the card then shows as a dropped field. Low Latency keeps its
    // immediate DISPLAY either way; only the readback falls back to the pipelined path, at the cost
    // of one field of delay that monitoring will never notice.
    tap.immediateReadback = lowLatency && !weave
    tap.scaling = scaling
    tap.activate(width: mode.width, height: mode.height, fps: mode.fps,
                 weaveFields: weave, upperFieldFirst: upperFieldFirst(for: mode),
                 interlineFilter: mode.isInterlacedOrPsF && interlineFilter
                                  && fieldMode != .sourceInterlaced,
                 filmCadence: weave && filmCadence,
                 sourceFrameRate: routedSourceFrameRate())
  }

  /// Re-arm the tap WITHOUT touching the device, for settings that only change how frames are built.
  ///
  /// Fields, field order, the filter and the cadence do not alter anything the card was opened with,
  /// so closing and reopening it for them was needless: the monitor dropped signal and re-synced,
  /// and the picture went black for as long as that took. The tap carries its last frame across a
  /// re-arm at the same raster, so this is now invisible on the monitor.
  private func reconfigureTapIfRunning() {
    guard output.isRunning, let mode = selectedMode else { notifyChanged(); return }
    armTap(for: mode)
    notifyChanged()
  }

  /// User asked to stop. Clears the intent, so it stays off across launches.
  func stop() {
    setRoutingEnabled(false)
    stopDevice()
  }

  private func stopDevice() {
    endBackgroundActivity()
    stopSourceRateTimer()
    guard output.isRunning else { return }
    // Stop the tap first so no capture races the device teardown.
    tap.deactivate()
    output.stop()
    notifyChanged()
  }

  /// Hand the card back before the machine sleeps, and take it again on wake.
  ///
  /// The DeckLink driver talks to hardware over an IOKit connection that does not survive a sleep
  /// cycle intact. Holding the device across sleep leaves us scheduling frames into a connection
  /// the driver has torn down, which is a good way to corrupt something rather than merely fail.
  /// Sleep is also exactly when a hardware output is least useful, so releasing costs nothing.
  private func observeSleepWake() {
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.wasRunningBeforeSleep = self.output.isRunning
      if self.output.isRunning { self.stopDevice() }
    }
    center.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
      guard let self = self, self.wasRunningBeforeSleep else { return }
      self.wasRunningBeforeSleep = false
      // The driver needs a moment to re-enumerate the device after wake; restoreIfNeeded is a
      // no-op if it is not back yet, and the activation and menu-open paths will retry.
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
        self?.restoreIfNeeded()
      }
    }
  }

  /// Hold off App Nap and timer coalescing while frames are going out to hardware.
  private func beginBackgroundActivity() {
    guard activityToken == nil else { return }
    activityToken = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .latencyCritical],
      reason: "DeckLink video output is active")
  }

  private func endBackgroundActivity() {
    guard let token = activityToken else { return }
    ProcessInfo.processInfo.endActivity(token)
    activityToken = nil
  }

  private func setRoutingEnabled(_ enabled: Bool) {
    guard enabled != routingEnabled else { return }
    routingEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Keys.routingEnabled)
  }

  /// Resume routing if the user left it on and the hardware can take it. Safe to call repeatedly:
  /// it is a no-op when routing is off, already running, or the device is not there. Called at
  /// launch, when the app becomes active, and whenever the menu opens, so a device plugged in after
  /// IINA started is picked up without the user toggling anything.
  func restoreIfNeeded() {
    guard routingEnabled, !output.isRunning, isDriverAvailable else { return }
    invalidateHardwareCaches()   // event rate, so a card plugged in since last time is seen
    ensureDefaultSelection()
    guard canStart else { return }
    startDevice()
  }

  func toggle() {
    if output.isRunning { stop() } else { start() }
  }

  private func restartIfNeeded() {
    if output.isRunning {
      tap.deactivate()
      output.stop()
      startDevice()
    } else {
      notifyChanged()
    }
  }

  private func notifyChanged() {
    NotificationCenter.default.post(name: DeckLinkController.stateDidChange, object: self)
    refreshColorManagement()
  }

  /// Re-apply each player's colour setup, because whether a player manages colour now depends on
  /// whether it is the one feeding the card. Every player is refreshed rather than just the routed
  /// one: the player that just LOST the route has to go back to normal ICC handling too.
  private func refreshColorManagement() {
    DispatchQueue.main.async {
      PlayerCore.playerCores.forEach { $0.refreshEdrMode() }
    }
  }

  // MARK: - frames

  /// Fills one output frame, on the feeder's thread. Returns false when the tap has nothing yet,
  /// which makes the feeder repeat its previous frame rather than starve the scheduler. Black is
  /// emitted only before the first capture, so the monitor still locks while playback starts.
  private func frameProvider() -> DeckLinkFrameProvider {
    return { [weak self] buffer, width, height, stride in
      guard let self = self else { return false }
      if self.tap.copyLatest(into: buffer, width: width, height: height, stride: stride) {
        return true
      }
      if !self.hasEmittedFirstFrame {
        memset(buffer, 0, stride * height)
        return true
      }
      return false
    }
  }

  /// Latched once the tap has produced anything, so the black fill above is a startup state only.
  private var hasEmittedFirstFrame: Bool { tap.capturedFrames > 0 }

  /// Called from ViewLayer.draw on the GL thread, after the on-screen render.
  /// Output-first path: returns true when it rendered for the card and previewed to the window,
  /// meaning the caller must not render again.
  func renderForOutput(for player: PlayerCore, renderContext: OpaquePointer, screenFBO: GLuint,
                       screenWidth: Int, screenHeight: Int) -> Bool {
    guard renderAtOutputResolution, output.isRunning, tap.isActive,
          screenWidth > 0, screenHeight > 0, claimsRoute(player) else { return false }
    let rendered = tap.renderForOutput(renderContext: renderContext, screenFBO: screenFBO,
                                       screenWidth: screenWidth, screenHeight: screenHeight)
    // Only ask for a display once the frame is whole. Firing per capture meant a display per FIELD,
    // roughly 54 a second into a mode that emits 29.97 frames, so half of them showed a frame whose
    // second field was still the seed. That is what read as dropped frames.
    if rendered && lowLatency && tap.frameComplete { output.displayNow() }
    return rendered
  }

  func captureFrameIfRouting(for player: PlayerCore, renderContext: OpaquePointer, sourceFBO: GLuint,
                             sourceWidth: Int, sourceHeight: Int) {
    guard output.isRunning, tap.isActive, sourceWidth > 0, sourceHeight > 0,
          claimsRoute(player) else { return }
    tap.capture(renderContext: renderContext, sourceFBO: sourceFBO,
                sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    // Low-latency mode is push-driven: tell the displayer a fresh frame exists the moment it does,
    // but only once it IS one. See renderForOutput above.
    if lowLatency && tap.frameComplete { output.displayNow() }
  }

  // MARK: - focus handling

  private var activationObservers: [NSObjectProtocol] = []

  private func updateActivityObservers() {
    let center = NotificationCenter.default
    activationObservers.forEach { center.removeObserver($0) }
    activationObservers.removeAll()
    guard releaseWhenInactive else { return }
    // A hardware output is exclusive, so handing it back when IINA is not frontmost lets another
    // app (a grading tool, say) take the card without quitting IINA.
    activationObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.wasRunningBeforeResign = self.output.isRunning
      if self.output.isRunning { self.stopDevice() }
    })
    activationObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
      guard let self = self, self.wasRunningBeforeResign else { return }
      self.wasRunningBeforeResign = false
      self.startDevice()
    })
  }

  /// Always watch activation for a restore attempt, independent of the release-when-inactive
  /// setting: if the card was busy or unplugged earlier, coming back to IINA is a natural moment to
  /// try again.
  private func observeActivationForRestore() {
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                           object: nil, queue: .main) { [weak self] _ in
      self?.restoreIfNeeded()
    }
  }
}
