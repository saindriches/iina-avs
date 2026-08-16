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
  static let interlineFilter = "decklink.interlineFilter"
}

/// How the two fields of an interlaced frame are produced.
enum DeckLinkFieldMode: Int {
  /// Both fields are one instant: a progressive frame carried in an interlaced raster. Right for
  /// film and any progressive source, and what this output has always produced.
  case psf = 0
  /// Each field is its own moment, a field period apart, which is what a CRT's scan actually shows.
  /// Only buys anything when the source itself carries motion at the field rate.
  case trueInterlace = 1
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

  /// Vertical band-limit before lines are split into fields, against interline twitter on a CRT.
  /// Costs vertical resolution, so it is off unless asked for, and it is only offered on an
  /// interlaced raster.
  private(set) var interlineFilter: Bool

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
  var isDriverAvailable: Bool { DeckLinkOutput.isDriverAvailable() }

  /// Frames the device reported late or dropped in this session. Surfaced so the UI can be honest
  /// about whether playout is keeping up.
  var lateFrames: Int { output.lateFrames }
  var droppedFrames: Int { output.droppedFrames }
  var scheduledFrames: Int { output.scheduledFrames }
  var resyncCount: Int { output.resyncCount }
  var repeatCount: Int { output.repeatCount }
  var capturedFrames: Int { tap.capturedFrames }

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
    interlineFilter = d.bool(forKey: Keys.interlineFilter)
    updateActivityObservers()
    observeActivationForRestore()
    observeSleepWake()
  }

  // MARK: - enumeration

  var devices: [DeckLinkDevice] { DeckLinkOutput.devices() }

  func modes(forDeviceID identifier: String?) -> [DeckLinkMode] {
    guard let device = device(withID: identifier) else { return [] }
    return DeckLinkOutput.modes(forDeviceAt: device.index)
  }

  func device(withID identifier: String?) -> DeckLinkDevice? {
    guard let identifier = identifier else { return nil }
    return devices.first { $0.identifier == identifier }
  }

  var selectedDevice: DeckLinkDevice? { device(withID: selectedDeviceID) }

  var selectedMode: DeckLinkMode? {
    let all = modes(forDeviceID: selectedDeviceID)
    return all.first { $0.index == selectedModeIndex }
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
    // Mode indices are per-device, so a device change invalidates the chosen mode.
    selectedModeIndex = -1
    UserDefaults.standard.set(-1, forKey: Keys.modeIndex)
    restartIfNeeded()
  }

  func selectMode(_ index: Int) {
    guard index != selectedModeIndex else { return }
    selectedModeIndex = index
    UserDefaults.standard.set(index, forKey: Keys.modeIndex)
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
    restartIfNeeded()
  }

  func setInterlineFilter(_ on: Bool) {
    guard on != interlineFilter else { return }
    interlineFilter = on
    UserDefaults.standard.set(on, forKey: Keys.interlineFilter)
    restartIfNeeded()
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
    // Weave only when the raster is genuinely interlaced AND the user asked for it: PsF rasters are
    // one instant by definition, and a progressive mode must not be touched.
    let weave = mode.isInterlaced && fieldMode == .trueInterlace
    // Immediate readback is synchronous, so it stalls the GL thread until the GPU is done. Weaving
    // already needs twice as many readbacks, and at field rate that stall is what stops the pair
    // completing in time, which the card then shows as a dropped field. Low Latency keeps its
    // immediate DISPLAY either way; only the readback falls back to the pipelined path, at the cost
    // of one field of delay that monitoring will never notice.
    tap.immediateReadback = lowLatency && !weave   // sub-frame monitoring wants this frame, not the last one
    // The filter is about an interlaced raster, PsF included, since a CRT scans alternate lines
    // either way. A progressive mode has nothing to twitter, so it never gets it.
    let filter = mode.isInterlacedOrPsF && interlineFilter
    tap.activate(width: mode.width, height: mode.height, fps: mode.fps,
                 weaveFields: weave, upperFieldFirst: mode.upperFieldFirst,
                 interlineFilter: filter)

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
    } catch {
      lastError = error.localizedDescription
      tap.deactivate()   // device never opened; nothing should keep capturing for it
    }
    notifyChanged()
    return ok
  }

  /// User asked to stop. Clears the intent, so it stays off across launches.
  func stop() {
    setRoutingEnabled(false)
    stopDevice()
  }

  private func stopDevice() {
    endBackgroundActivity()
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
    if rendered && lowLatency { output.displayNow() }
    return rendered
  }

  func captureFrameIfRouting(for player: PlayerCore, renderContext: OpaquePointer, sourceFBO: GLuint,
                             sourceWidth: Int, sourceHeight: Int) {
    guard output.isRunning, tap.isActive, sourceWidth > 0, sourceHeight > 0,
          claimsRoute(player) else { return }
    tap.capture(renderContext: renderContext, sourceFBO: sourceFBO,
                sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    // Low-latency mode is push-driven: tell the displayer a fresh frame exists the moment it does.
    if lowLatency { output.displayNow() }
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
