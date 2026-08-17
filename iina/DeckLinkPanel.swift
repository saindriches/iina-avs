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
  private var interlineBox: NSButton!
  private var filmCadenceBox: NSButton!
  private var use444Box: NSButton!
  private var levelABox: NSButton!
  private var nativeRenderBox: NSButton!
  private var lowLatencyBox: NSButton!
  private var releaseBox: NSButton!
  private var toggleButton: NSButton!
  private var statusLabel: NSTextField!

  private init() {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 10),
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
    statusLabel.preferredMaxLayoutWidth = 300
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
                                                            value: "Film Cadence (2:3 Pulldown)", comment: ""),
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
    releaseBox = addCheck(to: stack, NSLocalizedString("menu.decklink_release",
                                                       value: "Release Device When Inactive", comment: ""),
                          action: #selector(toggleRelease(_:)))

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
    popUp.widthAnchor.constraint(equalToConstant: 300).isActive = true
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
    dl.ensureDefaultSelection()
    dl.restoreIfNeeded()

    guard dl.isDriverAvailable else {
      [toggleButton, devicePopUp, modePopUp, formatPopUp, rangePopUp, linkPopUp,
       use444Box, levelABox, nativeRenderBox, lowLatencyBox, releaseBox].forEach { $0?.isEnabled = false }
      window?.setContentSize(NSSize(width: 340, height: fittingHeight()))
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
    fieldOrderPopUp.isEnabled = interlacedRaster && dl.fieldMode == .trueInterlace

    filmCadenceBox.state = dl.filmCadence ? .on : .off
    filmCadenceBox.isEnabled = dl.filmCadenceAvailable
    filmCadenceBox.toolTip = NSLocalizedString("menu.decklink_film_cadence_tip",
                                               value: "Lay 23.976 film onto the 59.94 field raster as broadcast does, three fields then two, generated on the card's clock rather than resampled from the window. Needs True Interlace, and the scheduled path rather than Low Latency, because the cadence has to be clocked by the card.",
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
    [nativeRenderBox, lowLatencyBox, releaseBox].forEach { $0?.isEnabled = true }

    window?.setContentSize(NSSize(width: 340, height: fittingHeight()))
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
      var text = String(format: NSLocalizedString("menu.decklink_status", value: "Scheduled %ld, late %ld, dropped %ld, captured %ld, resync %ld, repeat %ld", comment: ""),
                        dl.scheduledFrames, dl.lateFrames, dl.droppedFrames,
                        dl.capturedFrames, dl.resyncCount, dl.repeatCount)
      // The rate, and what it has to be. Interlace weaving needs a sample per FIELD, so the target
      // is twice the mode's frame rate; anything short of it means frames go out as PsF seeds
      // rather than as two distinct moments.
      if let mode = dl.selectedMode {
        // Say what the raster actually is and whether weaving armed. `isInterlaced` comes from the
        // driver's field dominance, and if it does not report upper or lower first then weaving
        // never engages however the Fields row is set, which looks identical to being too slow.
        let raster: String
        if mode.isInterlaced {
          raster = mode.upperFieldFirst ? "interlaced, upper first" : "interlaced, lower first"
        } else if mode.isInterlacedOrPsF {
          raster = "PsF"
        } else {
          raster = "progressive"
        }
        let weaving = mode.isInterlaced && dl.fieldMode == .trueInterlace
        text += String(format: NSLocalizedString("decklink.panel_raster",
                                                 value: "\nraster %@, weaving %@",
                                                 comment: "raster type and whether weaving is on"),
                       raster, weaving ? "on" : "off")
        // With the cadence running, a capture is a FILM frame, not a field, so the rate to judge it
        // against is the source rate. Say so rather than reporting it short against a target that
        // no longer applies.
        let cadence = dl.cadenceEngaged
        var needed = mode.fps * (weaving ? 2.0 : 1.0)
        if cadence {
          needed = mode.fps * 0.8   // four film frames per five output frames
          text += NSLocalizedString("decklink.panel_cadence", value: "\nfilm cadence 2:3 engaged",
                                    comment: "")
        } else if dl.filmCadence && dl.filmCadenceAvailable {
          text += NSLocalizedString("decklink.panel_cadence_idle",
                                    value: "\nfilm cadence asked for, source is not 2/5 of the field rate",
                                    comment: "")
        }
        text += String(format: NSLocalizedString("decklink.panel_rate",
                                                 value: "\ndraw %.1f/s, capture %.1f/s of %.2f needed\nframes out %.1f/s of %.2f",
                                                 comment: "draw, capture and published frame rates"),
                       drawsPerSecond, capturesPerSecond, needed, framesPerSecond, mode.fps)
      }
      statusLabel.stringValue = text
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

  @objc private func toggleRelease(_ sender: NSButton) {
    DeckLinkController.shared.releaseWhenInactive = (sender.state == .on)
    refresh()
  }
}
