//
//  DeckLinkPanel.swift
//  iina
//
//  A floating window holding every DeckLink output setting at once.
//
//  The Video menu is fine for setting the output up and forgetting it. It is the wrong shape for the
//  job this panel exists for: finding the combination a monitor actually likes. That means flipping
//  link width, then 4:4:4, then the pixel format, looking at the picture between each, and going
//  back. A menu closes on every choice and has to be re-walked from Video -> DeckLink Output, and a
//  pop-up menu is no better because it also closes. So this is a panel: it stays where it is put,
//  survives IINA losing focus, and shows the whole state at once so the interactions between
//  settings (a mode that a pixel format cannot carry, 4:4:4 needing dual link) are visible rather
//  than discovered one submenu at a time.
//
//  It drives DeckLinkController directly, exactly as the menu does, and rebuilds from
//  `stateDidChange`, so the two can never disagree about the hardware.
//

import Cocoa

class DeckLinkPanelController: NSWindowController {

  static let shared = DeckLinkPanelController()

  private var observer: NSObjectProtocol?
  private var statusTimer: Timer?
  /// Sampled once a second so the panel can show RATES. Cumulative counters cannot answer the only
  /// question that matters for interlace, which is whether captures are arriving fast enough.
  ///
  /// Three rates rather than one, because they fail for different reasons and the cure differs.
  /// `draw` is how often the GL hook runs at all, `capture` how many of those we sampled, and
  /// `frames` how many WHOLE frames reached the card. draw short of the target means the display
  /// loop is the ceiling; capture short of draw means we are discarding samples; frames short of
  /// half the captures means pairs are not completing and the feeder is repeating.
  private var lastCaptured = 0
  private var lastPublished = 0
  private var lastHookCalls = 0
  private var lastSampledAt: CFTimeInterval = 0
  private var capturesPerSecond: Double = 0
  private var framesPerSecond: Double = 0
  private var drawsPerSecond: Double = 0

  /// Rows whose enabled state depends on hardware capability, rebuilt on every refresh.
  private var devicePopUp: NSPopUpButton!
  private var modePopUp: NSPopUpButton!
  private var formatPopUp: NSPopUpButton!
  private var rangePopUp: NSPopUpButton!
  private var linkPopUp: NSPopUpButton!
  private var fieldPopUp: NSPopUpButton!
  private var fieldOrderPopUp: NSPopUpButton!
  private var scalingPopUp: NSPopUpButton!
  private var interlineBox: NSButton!
  private var filmCadenceBox: NSButton!
  private var testPatternPopUp: NSPopUpButton!
  private var testOpacitySlider: NSSlider!
  private var use444Box: NSButton!
  private var levelABox: NSButton!
  private var nativeRenderBox: NSButton!
  private var lowLatencyBox: NSButton!
  private var compensateAudioBox: NSButton!
  private var releaseBox: NSButton!
  private var toggleButton: NSButton!
  private var statusLabel: NSTextField!

  private init() {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 10),
                        styleMask: [.titled, .closable, .utilityWindow, .hudWindow],
                        backing: .buffered, defer: false)
    panel.title = NSLocalizedString("decklink.panel_title", value: "DeckLink Output",
                                    comment: "DeckLink panel title")
    // Stays above the video and keeps its state while IINA is in the background, because the
    // comparison being made is often against another application driving the same monitor.
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.isReleasedWhenClosed = false
    super.init(window: panel)
    buildContent()
    panel.setFrameAutosaveName("DeckLinkPanel")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - construction

  private func buildContent() {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    stack.translatesAutoresizingMaskIntoConstraints = false

    toggleButton = NSButton(title: "", target: self, action: #selector(toggleOutput(_:)))
    toggleButton.bezelStyle = .rounded
    stack.addArrangedSubview(toggleButton)

    statusLabel = makeLabel("")
    statusLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byWordWrapping
    statusLabel.preferredMaxLayoutWidth = 344
    stack.addArrangedSubview(statusLabel)

    stack.addArrangedSubview(separator())

    devicePopUp = addRow(to: stack, NSLocalizedString("menu.decklink_device", value: "Device", comment: "Device"),
                         action: #selector(selectDevice(_:)))
    modePopUp = addRow(to: stack, NSLocalizedString("menu.decklink_mode", value: "Video Mode", comment: "Video Mode"),
                       action: #selector(selectMode(_:)))
    formatPopUp = addRow(to: stack, NSLocalizedString("menu.decklink_pixel_format", value: "Pixel Format", comment: ""),
                         action: #selector(selectFormat(_:)))
    rangePopUp = addRow(to: stack, NSLocalizedString("menu.decklink_levels", value: "Levels", comment: ""),
                        action: #selector(selectRange(_:)))
    scalingPopUp = addRow(to: stack, NSLocalizedString("menu.decklink_scaling",
                                                       value: "Aspect Handling", comment: ""),
                          action: #selector(selectScaling(_:)))

    stack.addArrangedSubview(separator())
    stack.addArrangedSubview(sectionLabel(NSLocalizedString("menu.decklink_sdi", value: "SDI Signal", comment: "")))

    linkPopUp = addRow(to: stack, NSLocalizedString("menu.decklink_link", value: "SDI Link", comment: ""),
                       action: #selector(selectLink(_:)))
    use444Box = addCheck(to: stack, NSLocalizedString("menu.decklink_444", value: "4:4:4 SDI Output", comment: ""),
                         action: #selector(toggle444(_:)))
    levelABox = addCheck(to: stack, NSLocalizedString("menu.decklink_level_a", value: "Level A for 3G-SDI", comment: ""),
                         action: #selector(toggleLevelA(_:)))

    fieldPopUp = addRow(to: stack, NSLocalizedString("menu.decklink_fields", value: "Fields", comment: ""),
                        action: #selector(selectFieldMode(_:)))

    fieldOrderPopUp = addRow(to: stack, NSLocalizedString("menu.decklink_field_order",
                                                          value: "Field Order", comment: ""),
                             action: #selector(selectFieldOrder(_:)))

    filmCadenceBox = addCheck(to: stack, NSLocalizedString("menu.decklink_film_cadence",
                                                            value: "Pulldown Cadence", comment: ""),
                              action: #selector(toggleFilmCadence(_:)))

    interlineBox = addCheck(to: stack, NSLocalizedString("menu.decklink_interline",
                                                         value: "Interline Filter", comment: ""),
                            action: #selector(toggleInterlineFilter(_:)))

    stack.addArrangedSubview(separator())

    nativeRenderBox = addCheck(to: stack, NSLocalizedString("menu.decklink_native_render",
                                                            value: "Render at Output Resolution", comment: ""),
                               action: #selector(toggleNativeRender(_:)))
    lowLatencyBox = addCheck(to: stack, NSLocalizedString("menu.decklink_low_latency",
                                                          value: "Low Latency Mode", comment: ""),
                             action: #selector(toggleLowLatency(_:)))
    compensateAudioBox = addCheck(to: stack, NSLocalizedString("menu.decklink_compensate_audio",
                                                               value: "Delay Audio to Match", comment: ""),
                                  action: #selector(toggleCompensateAudio(_:)))
    compensateAudioBox.toolTip = NSLocalizedString("menu.decklink_compensate_audio_tip",
                                                   value: "The SDI picture reaches the monitor later than the window does, but the audio does not, so anything watched on the monitor drifts by exactly that. This holds mpv's audio delay at the measured video latency. It is put back as it was when output stops.",
                                                   comment: "")
    releaseBox = addCheck(to: stack, NSLocalizedString("menu.decklink_release",
                                                       value: "Release Device When Inactive", comment: ""),
                          action: #selector(toggleRelease(_:)))

    testPatternPopUp = addRow(to: stack, NSLocalizedString("menu.decklink_test_pattern",
                                                          value: "Test Pattern", comment: ""),
                             action: #selector(selectTestPattern(_:)))
    testPatternPopUp.toolTip = NSLocalizedString("menu.decklink_test_pattern_tip",
                                                 value: "Patterns that answer what the picture cannot. Field Order sweeps a bar one step per field: even is correct, a back-step every other field means swapped fields, a stall and jump means repetition. Geometry gives crosshatch, circle and safe-area boxes for setting a tube up. Twitter shows what the interline filter buys and costs. Greyscale sets black level, Bars check chroma and levels.",
                                                 comment: "")
    testOpacitySlider = NSSlider(value: 1.0, minValue: 0.05, maxValue: 1.0,
                                 target: self, action: #selector(changeTestOpacity(_:)))
    testOpacitySlider.isContinuous = true
    testOpacitySlider.translatesAutoresizingMaskIntoConstraints = false
    testOpacitySlider.widthAnchor.constraint(equalToConstant: 344).isActive = true
    testOpacitySlider.toolTip = NSLocalizedString("menu.decklink_test_opacity_tip",
                                                  value: "Mix the pattern over the picture instead of replacing it. A safe-area box is only useful against the shot it is meant to contain, and the overscan being measured is the overscan of real content.",
                                                  comment: "")
    stack.addArrangedSubview(testOpacitySlider)

    guard let content = window?.contentView else { return }
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
  }

  private func makeLabel(_ text: String) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: 11)
    return l
  }

  private func sectionLabel(_ text: String) -> NSTextField {
    let l = makeLabel(text)
    l.font = .systemFont(ofSize: 10, weight: .semibold)
    l.textColor = .secondaryLabelColor
    return l
  }

  private func separator() -> NSBox {
    let b = NSBox()
    b.boxType = .separator
    return b
  }

  private func addRow(to stack: NSStackView, _ title: String, action: Selector) -> NSPopUpButton {
    stack.addArrangedSubview(sectionLabel(title))
    let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    popUp.target = self
    popUp.action = action
    popUp.autoenablesItems = false
    popUp.translatesAutoresizingMaskIntoConstraints = false
    popUp.widthAnchor.constraint(equalToConstant: 344).isActive = true
    stack.addArrangedSubview(popUp)
    return popUp
  }

  private func addCheck(to stack: NSStackView, _ title: String, action: Selector) -> NSButton {
    let box = NSButton(checkboxWithTitle: title, target: self, action: action)
    box.font = .systemFont(ofSize: 11)
    stack.addArrangedSubview(box)
    return box
  }

  // MARK: - showing

  func toggleVisible() {
    if window?.isVisible == true {
      hide()
      return
    }
    // Show BEFORE refreshing: `refresh` declines to work on a hidden window, so populating first
    // left the panel blank until something else triggered it, which in practice meant pressing
    // Stop/Start. Non-activating, because bringing settings up should not steal focus from the
    // video being judged.
    window?.orderFrontRegardless()
    refresh()
    if observer == nil {
      observer = NotificationCenter.default.addObserver(forName: DeckLinkController.stateDidChange,
                                                        object: nil, queue: .main) { [weak self] _ in
        self?.refresh()
      }
    }
    startStatusTimer()
  }

  private func hide() {
    window?.orderOut(nil)
    statusTimer?.invalidate()
    statusTimer = nil
  }

  /// The playout counters move constantly while running, so they are polled rather than waiting for
  /// a state change that may never come. Only the status line is rewritten: a full rebuild every
  /// second would tear down the pop-up menus underneath the user's cursor.
  private func startStatusTimer() {
    statusTimer?.invalidate()
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.refreshStatus()
    }
    RunLoop.main.add(timer, forMode: .common)
    statusTimer = timer
  }

  // MARK: - state

  /// Rebuild every control from the controller. Cheap, and called on any state change, so the panel
  /// cannot drift from the hardware the way separately-maintained UI state would.
  func refresh() {
    guard window?.isVisible == true else { return }
    let dl = DeckLinkController.shared
    // The one place that is allowed to go back to the hardware: a rebuild happens on state changes,
    // not on a clock, so a device plugged in since last time turns up here. `refreshStatus` below
    // must live off the cache, which is what it failed to do.
    dl.invalidateHardwareCaches()
    dl.ensureDefaultSelection()
    dl.restoreIfNeeded()

    guard dl.isDriverAvailable else {
      [toggleButton, devicePopUp, modePopUp, formatPopUp, rangePopUp, linkPopUp,
       use444Box, levelABox, nativeRenderBox, lowLatencyBox, releaseBox].forEach { $0?.isEnabled = false }
      window?.setContentSize(NSSize(width: 380, height: fittingHeight()))
      return
    }

    toggleButton.title = dl.isRunning
      ? NSLocalizedString("menu.decklink_stop", value: "Stop Output", comment: "")
      : NSLocalizedString("menu.decklink_start", value: "Start Output", comment: "")
    toggleButton.isEnabled = dl.isRunning || dl.canStart

    refreshStatus()

    // -- device
    let devices = dl.devices
    devicePopUp.removeAllItems()
    for device in devices {
      devicePopUp.addItem(withTitle: device.displayName)
      devicePopUp.lastItem?.representedObject = device.identifier
    }
    devicePopUp.isEnabled = !devices.isEmpty
    if let index = devices.firstIndex(where: { $0.identifier == dl.selectedDeviceID }) {
      devicePopUp.selectItem(at: index)
    }

    // -- video mode. Rows the current pixel format cannot carry stay visible but disabled, so the
    // reason a mode is unavailable is legible instead of the row simply not being there.
    let modes = dl.modes(forDeviceID: dl.selectedDeviceID)
    modePopUp.removeAllItems()
    for mode in modes {
      modePopUp.addItem(withTitle: String(format: "%@  (%ld×%ld %@)", mode.name, mode.width,
                                          mode.height, Self.formatFPS(mode.fps)))
      modePopUp.lastItem?.representedObject = mode.index
      modePopUp.lastItem?.isEnabled = dl.mode(mode, supports: dl.pixelFormat)
    }
    modePopUp.isEnabled = !modes.isEmpty
    if let index = modes.firstIndex(where: { $0.index == dl.selectedModeIndex }) {
      modePopUp.selectItem(at: index)
    }

    // -- pixel format
    let formats: [(DeckLinkPixelFormat, String, Bool)] = [
      (.format8BitYUV, "8-bit YUV 4:2:2", dl.selectedMode?.supports8BitYUV ?? true),
      (.format10BitYUV, "10-bit YUV 4:2:2", dl.selectedMode?.supports10BitYUV ?? true),
      (.format10BitRGB, "10-bit RGB 4:4:4", dl.selectedMode?.supports10BitRGB ?? true),
    ]
    formatPopUp.removeAllItems()
    for (format, title, supported) in formats {
      formatPopUp.addItem(withTitle: title)
      formatPopUp.lastItem?.representedObject = format.rawValue
      formatPopUp.lastItem?.isEnabled = supported
    }
    if let index = formats.firstIndex(where: { $0.0 == dl.pixelFormat }) {
      formatPopUp.selectItem(at: index)
    }

    // -- levels
    let ranges: [(DeckLinkVideoRange, String)] = [(.SMPTE, "SMPTE (legal)"), (.full, "Full")]
    rangePopUp.removeAllItems()
    for (value, title) in ranges {
      rangePopUp.addItem(withTitle: title)
      rangePopUp.lastItem?.representedObject = value.rawValue
    }
    if let index = ranges.firstIndex(where: { $0.0 == dl.range }) {
      rangePopUp.selectItem(at: index)
    }

    // -- aspect handling, for when the picture and the raster are different shapes
    let scalings: [(DeckLinkScaling, String)] = [
      (.fit, NSLocalizedString("menu.decklink_scaling_fit", value: "Fit (letterbox)", comment: "")),
      (.fill, NSLocalizedString("menu.decklink_scaling_fill", value: "Fill (crop)", comment: "")),
      (.stretch, NSLocalizedString("menu.decklink_scaling_stretch", value: "Stretch (distort)", comment: "")),
    ]
    scalingPopUp.removeAllItems()
    for (value, title) in scalings {
      scalingPopUp.addItem(withTitle: title)
      scalingPopUp.lastItem?.representedObject = value.rawValue
    }
    if let index = scalings.firstIndex(where: { $0.0 == dl.scaling }) {
      scalingPopUp.selectItem(at: index)
    }
    // With Render at Output Resolution on, mpv draws into the raster and does the fitting itself,
    // so this has nothing left to decide. Say so by disabling it rather than letting it look live.
    scalingPopUp.isEnabled = !dl.renderAtOutputResolution
    scalingPopUp.toolTip = NSLocalizedString("menu.decklink_scaling_tip",
                                             value: "What to do when the picture and the SDI raster are different shapes. Fit keeps the whole picture and adds bars, which is what a broadcast chain expects. Ignored under Render at Output Resolution, where mpv renders straight into the raster and fits it itself.",
                                             comment: "")

    // -- SDI signal, gated on what the device says it implements
    let caps = dl.capabilities
    let links: [(DeckLinkSDILink, String, Bool)] = [
      (.single, NSLocalizedString("menu.decklink_link_single", value: "Single Link", comment: ""), true),
      (.dual, NSLocalizedString("menu.decklink_link_dual", value: "Dual Link", comment: ""), caps?.supportsDualLink ?? false),
      (.quad, NSLocalizedString("menu.decklink_link_quad", value: "Quad Link", comment: ""), caps?.supportsQuadLink ?? false),
    ]
    linkPopUp.removeAllItems()
    for (value, title, supported) in links {
      linkPopUp.addItem(withTitle: title)
      linkPopUp.lastItem?.representedObject = value.rawValue
      linkPopUp.lastItem?.isEnabled = supported
    }
    if let index = links.firstIndex(where: { $0.0 == dl.sdiLink }) {
      linkPopUp.selectItem(at: index)
    }

    // Fields: only an interlaced raster has a choice to make here.
    let interlacedRaster = dl.selectedMode?.isInterlaced ?? false
    let fieldModes: [(DeckLinkFieldMode, String)] = [
      (.psf, NSLocalizedString("menu.decklink_field_psf", value: "PsF (whole frames)", comment: "")),
      (.trueInterlace, NSLocalizedString("menu.decklink_field_true", value: "True Interlace (field-rate)", comment: "")),
      (.sourceInterlaced, NSLocalizedString("menu.decklink_field_source", value: "Source Fields (pass through)", comment: "")),
    ]
    fieldPopUp.removeAllItems()
    for (value, title) in fieldModes {
      fieldPopUp.addItem(withTitle: title)
      fieldPopUp.lastItem?.representedObject = value.rawValue
    }
    if let index = fieldModes.firstIndex(where: { $0.0 == dl.fieldMode }) {
      fieldPopUp.selectItem(at: index)
    }
    fieldPopUp.isEnabled = interlacedRaster

    // Field order only has an effect while weaving, since PsF puts one instant in both fields.
    let reported = (dl.selectedMode?.upperFieldFirst ?? true) ? "upper" : "lower"
    let fieldOrders: [(DeckLinkFieldOrder, String)] = [
      (.auto, String(format: NSLocalizedString("menu.decklink_field_order_auto",
                                               value: "Auto (%@ first)", comment: ""), reported)),
      (.upperFirst, NSLocalizedString("menu.decklink_field_order_upper", value: "Upper Field First", comment: "")),
      (.lowerFirst, NSLocalizedString("menu.decklink_field_order_lower", value: "Lower Field First", comment: "")),
    ]
    fieldOrderPopUp.removeAllItems()
    for (value, title) in fieldOrders {
      fieldOrderPopUp.addItem(withTitle: title)
      fieldOrderPopUp.lastItem?.representedObject = value.rawValue
    }
    if let index = fieldOrders.firstIndex(where: { $0.0 == dl.fieldOrder }) {
      fieldOrderPopUp.selectItem(at: index)
    }
    fieldOrderPopUp.isEnabled = interlacedRaster
      && (dl.fieldMode == .trueInterlace || dl.fieldMode == .sourceInterlaced)
    fieldOrderPopUp.toolTip = dl.fieldMode == .sourceInterlaced
      ? NSLocalizedString("menu.decklink_field_order_src_tip",
                          value: "Which field the SOURCE was encoded with first. The card splits the frame by row parity, so when the source disagrees with the raster the picture is shifted one line, which exchanges the two fields without visibly moving anything. Auto assumes the source agrees with the raster.",
                          comment: "")
      : NSLocalizedString("menu.decklink_field_order_tip2",
                          value: "Which field the card transmits first, and so which one carries the earlier moment.",
                          comment: "")

    filmCadenceBox.state = dl.filmCadence ? .on : .off
    filmCadenceBox.isEnabled = dl.filmCadenceAvailable
    filmCadenceBox.toolTip = NSLocalizedString("menu.decklink_film_cadence_tip",
                                               value: "Spread a source slower than the field rate across the fields, generated on the card's clock rather than resampled from the window. 23.976 film into 59.94 fields gives the 2:3 of telecine, 50p gives 5:6, 30p a clean two fields each. Needs True Interlace. Works on either latency path, since both are now paced by the card.",
                                               comment: "")

    interlineBox.state = dl.interlineFilter ? .on : .off
    interlineBox.isEnabled = dl.selectedMode?.isInterlacedOrPsF ?? false

    use444Box.state = dl.use444 ? .on : .off
    use444Box.isEnabled = caps?.supports444SDI ?? false
    levelABox.state = dl.levelA ? .on : .off
    levelABox.isEnabled = caps?.supportsLevelA ?? false

    nativeRenderBox.state = dl.renderAtOutputResolution ? .on : .off
    lowLatencyBox.state = dl.lowLatency ? .on : .off
    releaseBox.state = dl.releaseWhenInactive ? .on : .off
    let patterns: [(DeckLinkTestPattern, String)] = [
      (.off, NSLocalizedString("menu.decklink_pattern_off", value: "Off (video)", comment: "")),
      (.fieldOrder, NSLocalizedString("menu.decklink_pattern_field", value: "Field Order Sweep", comment: "")),
      (.geometry, NSLocalizedString("menu.decklink_pattern_geometry", value: "Geometry and Safe Area", comment: "")),
      (.twitter, NSLocalizedString("menu.decklink_pattern_twitter", value: "Interline Twitter", comment: "")),
      (.greyscale, NSLocalizedString("menu.decklink_pattern_grey", value: "Greyscale and Black Level", comment: "")),
      (.colourBars, NSLocalizedString("menu.decklink_pattern_bars", value: "75% Colour Bars", comment: "")),
    ]
    testPatternPopUp.removeAllItems()
    for (value, title) in patterns {
      testPatternPopUp.addItem(withTitle: title)
      testPatternPopUp.lastItem?.representedObject = value.rawValue
    }
    if let index = patterns.firstIndex(where: { $0.0 == dl.testPattern }) {
      testPatternPopUp.selectItem(at: index)
    }
    testOpacitySlider.doubleValue = dl.testOpacity
    testOpacitySlider.isEnabled = dl.testPattern != .off

    compensateAudioBox.state = dl.compensateAudio ? .on : .off
    [nativeRenderBox, lowLatencyBox, releaseBox, testPatternPopUp,
     compensateAudioBox].forEach { $0?.isEnabled = true }

    window?.setContentSize(NSSize(width: 380, height: fittingHeight()))
  }

  /// Just the counters, cheap enough to run every second.
  private func refreshStatus() {
    guard window?.isVisible == true, statusLabel != nil else { return }
    let dl = DeckLinkController.shared

    let now = CACurrentMediaTime()
    if lastSampledAt > 0, now > lastSampledAt {
      let elapsed = now - lastSampledAt
      capturesPerSecond = Double(dl.capturedFrames - lastCaptured) / elapsed
      framesPerSecond = Double(dl.publishedFrames - lastPublished) / elapsed
      drawsPerSecond = Double(dl.hookCalls - lastHookCalls) / elapsed
    }
    lastCaptured = dl.capturedFrames
    lastPublished = dl.publishedFrames
    lastHookCalls = dl.hookCalls
    lastSampledAt = now
    if let error = dl.lastError {
      statusLabel.stringValue = error
    } else if dl.isRunning {
      statusLabel.stringValue = runningStatus(dl)
    } else if !dl.isDriverAvailable {
      statusLabel.stringValue = NSLocalizedString("menu.decklink_no_driver",
                                                  value: "Blackmagic Desktop Video not installed",
                                                  comment: "")
    } else if dl.devices.isEmpty {
      statusLabel.stringValue = NSLocalizedString("menu.decklink_no_device",
                                                  value: "No DeckLink device found", comment: "")
    } else {
      statusLabel.stringValue = NSLocalizedString("decklink.panel_idle", value: "Output stopped",
                                                  comment: "DeckLink idle status")
    }
  }

  /// Four labelled lines, in the order the picture actually travels.
  ///
  /// signal  what the card is being handed, as opposed to what was asked for
  /// build   how the fields are being made, which is the setting that most often is not what
  ///         the checkbox suggests
  /// rate    the pipeline, left to right, each stage against what it has to be
  /// count   cumulative totals, and only the ones that mean something is wrong
  ///
  /// Every rate carries its target, because a bare number cannot say whether it is healthy, and
  /// grouping them left to right shows WHERE a shortfall starts rather than only that there is one.
  private func runningStatus(_ dl: DeckLinkController) -> String {
    guard let mode = dl.selectedMode else {
      return String(format: "count   sent %ld, late %ld, dropped %ld",
                    dl.scheduledFrames, dl.lateFrames, dl.droppedFrames)
    }

    // -- signal. `isInterlaced` comes from the driver's field dominance; if it reports neither
    // upper nor lower first then weaving never engages however the Fields row is set, which from
    // the outside looks identical to being too slow. The order shown is the EFFECTIVE one.
    let weaving = mode.isInterlaced && dl.fieldMode == .trueInterlace
    var raster: String
    if mode.isInterlaced {
      raster = "interlaced, \(dl.upperFieldFirst(for: mode) ? "upper" : "lower") first"
      if dl.fieldOrder != .auto { raster += " (forced)" }
    } else if mode.isInterlacedOrPsF {
      raster = "PsF"
    } else {
      raster = "progressive"
    }
    // Deliberately NOT the mode name or size: the Video Mode row directly below already says both,
    // and repeating them was what pushed this line onto a second row.
    var lines = ["signal  " + raster]

    // -- build, and the capture rate the chosen scheme implies.
    let fieldRate = mode.fps * 2.0
    var needed = weaving ? fieldRate : mode.fps
    let build: String
    if dl.cadenceEngaged {
      // One capture per SOURCE frame: the cadence builds the fields itself.
      needed = dl.sourceFrameRate
      let rates = dl.sourceRates
      if abs(rates.reported - rates.effective) > 0.05 {
        // Say both, because a cadence planned against a rate the file did not mean is exactly the
        // case worth seeing, and it is invisible otherwise.
        build = String(format: "cadence %.2f fps (file says %.2f), %ld holds",
                       rates.effective, rates.reported, dl.cadenceHolds)
      } else {
        build = String(format: "cadence %.2f fps into %.2f fields, %ld holds",
                       rates.effective, fieldRate, dl.cadenceHolds)
      }
    } else if dl.weaveStarved {
      // Only as many distinct moments a second as the source has frames, so field-rate motion
      // cannot be made however it is sampled.
      needed = mode.fps
      // Two different thresholds, and saying "too slow" for both was wrong. Weaving needs a moment
      // per FIELD, which is what this source cannot supply. Whether frames have to REPEAT is a
      // question about the frame rate, half of that, and a 50p source is well above it: those
      // frames are being dropped, not repeated, and calling that too slow was misleading.
      let short = dl.sourceFrameRate < mode.fps
      build = String(format: "whole frames %.2f from %.2f, %@",
                     mode.fps, dl.sourceFrameRate, short ? "repeating" : "dropping")
    } else if dl.fieldMode == .sourceInterlaced && mode.isInterlaced {
      // Both preconditions are invisible from the picture until motion combs wrongly, so say them.
      // Scaling is the brutal one: resampling vertically averages each line with the other field,
      // and once that has happened nothing downstream can take them apart again.
      var note = "source fields, passing through"
      if !dl.renderAtOutputResolution {
        // The most destructive of the three and the easiest to miss. Without this the picture is
        // taken from the WINDOW's framebuffer, so the window's height sets the vertical resolution
        // and the rescale to the raster averages every line with the other field. The fields are
        // gone before the tap ever sees them, and nothing downstream can recover them.
        note = "source fields NEED Render at Output Resolution"
      } else if dl.sourceDeinterlacing {
        note = "source fields, but mpv is DEINTERLACING"
      } else if dl.sourceHeight > 0 && dl.sourceHeight != mode.height && !dl.usesLinePlacement {
        note = String(format: "source fields, but %ld is being scaled to %ld",
                      dl.sourceHeight, mode.height)
      } else if dl.usesLinePlacement {
        // State the offset rather than implying it: an odd one silently inverts the field order,
        // so it is exactly the number worth being able to read back.
        let placement = dl.linePlacement
        note = String(format: "source fields, %ld placed in %ld at line %ld%@",
                      placement.height, mode.height, placement.top,
                      dl.isSwappingFields ? ", swapped" : "")
      } else if dl.isSwappingFields {
        note = "source fields, shifted one line"
      }
      build = note
    } else if weaving {
      build = "field-rate interlace"
    } else if mode.isInterlacedOrPsF {
      build = "whole frames (PsF)"
    } else {
      build = "progressive"
    }
    lines.append("build   " + build + (dl.interlineFilter && mode.isInterlacedOrPsF ? ", interline filter" : ""))

    // -- rate, in pipeline order, each against its target.
    lines.append(String(format: "rate    draw %.1f  capture %.1f/%.2f  out %.1f/%.2f",
                        drawsPerSecond, capturesPerSecond, needed, framesPerSecond, mode.fps))

    // -- delay. Where the picture on the monitor sits relative to the window, and what the audio
    // is being shifted by to match it.
    var delay = String(format: "delay   %.0f ms, %ld in card",
                       dl.smoothedLatency * 1000.0, dl.bufferedFrames)
    if dl.compensateAudio { delay += ", audio matched" }
    lines.append(delay)

    // -- count. Scheduled is context; the rest should all be zero.
    lines.append(String(format: "count   sent %ld, late %ld, drop %ld, rep %ld, dup %ld, resync %ld",
                        dl.scheduledFrames, dl.lateFrames, dl.droppedFrames,
                        dl.repeatCount, dl.duplicateFrames, dl.resyncCount))
    return lines.joined(separator: "\n")
  }

  private func fittingHeight() -> CGFloat {
    window?.contentView?.fittingSize.height ?? 420
  }

  /// Same rendering as the menu's: whole rates without decimals, 59.94 and friends with two.
  private static func formatFPS(_ fps: Double) -> String {
    let rounded = (fps * 100).rounded() / 100
    return rounded == rounded.rounded()
      ? String(format: "%.0f fps", rounded)
      : String(format: "%.2f fps", rounded)
  }

  // MARK: - actions

  @objc private func toggleOutput(_ sender: NSButton) { DeckLinkController.shared.toggle(); refresh() }

  @objc private func selectDevice(_ sender: NSPopUpButton) {
    DeckLinkController.shared.selectDevice(sender.selectedItem?.representedObject as? String)
    refresh()
  }

  @objc private func selectMode(_ sender: NSPopUpButton) {
    guard let index = sender.selectedItem?.representedObject as? Int else { return }
    DeckLinkController.shared.selectMode(index)
    refresh()
  }

  @objc private func selectFormat(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? Int,
          let format = DeckLinkPixelFormat(rawValue: raw) else { return }
    DeckLinkController.shared.selectPixelFormat(format)
    refresh()
  }

  @objc private func selectRange(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? Int,
          let range = DeckLinkVideoRange(rawValue: raw) else { return }
    DeckLinkController.shared.selectRange(range)
    refresh()
  }

  @objc private func selectLink(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? Int,
          let link = DeckLinkSDILink(rawValue: raw) else { return }
    DeckLinkController.shared.selectSDILink(link)
    refresh()
  }

  @objc private func selectFieldMode(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? Int,
          let mode = DeckLinkFieldMode(rawValue: raw) else { return }
    DeckLinkController.shared.setFieldMode(mode)
    refresh()
  }

  @objc private func selectScaling(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? Int,
          let mode = DeckLinkScaling(rawValue: raw) else { return }
    DeckLinkController.shared.setScaling(mode)
    refresh()
  }

  @objc private func selectFieldOrder(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? Int,
          let order = DeckLinkFieldOrder(rawValue: raw) else { return }
    DeckLinkController.shared.setFieldOrder(order)
    refresh()
  }

  @objc private func toggleFilmCadence(_ sender: NSButton) {
    DeckLinkController.shared.setFilmCadence(sender.state == .on)
    refresh()
  }

  @objc private func toggleInterlineFilter(_ sender: NSButton) {
    DeckLinkController.shared.setInterlineFilter(sender.state == .on)
    refresh()
  }

  @objc private func toggle444(_ sender: NSButton) {
    DeckLinkController.shared.setUse444(sender.state == .on)
    refresh()
  }

  @objc private func toggleLevelA(_ sender: NSButton) {
    DeckLinkController.shared.setLevelA(sender.state == .on)
    refresh()
  }

  @objc private func toggleNativeRender(_ sender: NSButton) {
    DeckLinkController.shared.renderAtOutputResolution = (sender.state == .on)
    refresh()
  }

  @objc private func toggleLowLatency(_ sender: NSButton) {
    DeckLinkController.shared.lowLatency = (sender.state == .on)
    refresh()
  }

  @objc private func toggleCompensateAudio(_ sender: NSButton) {
    DeckLinkController.shared.setCompensateAudio(sender.state == .on)
    refresh()
  }

  @objc private func selectTestPattern(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? Int,
          let pattern = DeckLinkTestPattern(rawValue: raw) else { return }
    DeckLinkController.shared.testPattern = pattern
    refresh()
  }

  @objc private func changeTestOpacity(_ sender: NSSlider) {
    DeckLinkController.shared.testOpacity = sender.doubleValue
    UserDefaults.standard.set(sender.doubleValue, forKey: "decklink.testOpacity")
  }

  @objc private func toggleRelease(_ sender: NSButton) {
    DeckLinkController.shared.releaseWhenInactive = (sender.state == .on)
    refresh()
  }
}
