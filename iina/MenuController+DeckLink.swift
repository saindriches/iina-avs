//
//  MenuController+DeckLink.swift
//  iina
//
//  The Video > DeckLink Output submenu.
//
//  Built entirely in code rather than in MainMenu.xib: CONTRIBUTING.md asks contributors not to add
//  or change xib files, and IINA already has precedent for a code-built menu in updatePluginMenu().
//  Contents are repopulated on every open, matching the audio-device menu idiom, so hot-plugging a
//  device or changing what a mode supports is picked up without any extra bookkeeping.
//

import Cocoa

extension MenuController {

  static let deckLinkMenuIdentifier = NSUserInterfaceItemIdentifier("iina.decklink.menu")
  static let deckLinkQuickIdentifier = NSUserInterfaceItemIdentifier("iina.decklink.quick")

  /// Append "DeckLink Output" to the Video menu. Called once from bindMenuItems().
  func setUpDeckLinkMenu() {
    // NSMenu has no lookup by identifier, so scan (the Video menu is short).
    guard !videoMenu.items.contains(where: { $0.identifier == MenuController.deckLinkMenuIdentifier })
    else { return }
    let submenu = NSMenu()
    submenu.identifier = MenuController.deckLinkMenuIdentifier
    submenu.delegate = self
    submenu.autoenablesItems = false   // we decide what is selectable, from device capability

    let item = NSMenuItem()
    item.title = NSLocalizedString("menu.decklink_output", value: "DeckLink Output", comment: "DeckLink Output")
    item.identifier = MenuController.deckLinkMenuIdentifier
    item.submenu = submenu

    videoMenu.addItem(.separator())
    videoMenu.addItem(item)

    // A window rather than another menu. Finding the combination a monitor accepts means changing a
    // setting, looking at the picture, and changing it back, repeatedly; a menu (and equally a
    // pop-up menu) closes on every choice and has to be re-walked each time, which is why the first
    // attempt at this added nothing. The panel stays open and shows the whole state at once.
    //
    // Shift-Cmd-D, because Ctrl-Cmd-D is taken by macOS itself for Look Up and never reached us.
    let quick = NSMenuItem(title: NSLocalizedString("menu.decklink_quick",
                                                    value: "DeckLink Output Panel",
                                                    comment: "DeckLink Output Panel"),
                           action: #selector(menuDeckLinkShowPanel(_:)), keyEquivalent: "d")
    quick.keyEquivalentModifierMask = [.shift, .command]
    quick.target = self
    quick.identifier = MenuController.deckLinkQuickIdentifier
    videoMenu.addItem(quick)
  }

  /// Show or hide the floating settings panel. It drives the same controller the menu does.
  @objc func menuDeckLinkShowPanel(_ sender: NSMenuItem) {
    DeckLinkPanelController.shared.toggleVisible()
  }

  /// Rebuild the submenu from what the hardware currently reports.
  func updateDeckLinkMenu(_ menu: NSMenu) {
    let dl = DeckLinkController.shared
    dl.invalidateHardwareCaches()   // opening the menu is a fine moment to re-read the hardware
    dl.ensureDefaultSelection()
    dl.restoreIfNeeded()   // picks up a device plugged in after launch
    menu.removeAllItems()

    guard dl.isDriverAvailable else {
      addDisabledRow(to: menu, NSLocalizedString("menu.decklink_no_driver",
                                                 value: "Blackmagic Desktop Video not installed",
                                                 comment: "Blackmagic Desktop Video not installed"))
      return
    }

    let devices = dl.devices
    guard !devices.isEmpty else {
      addDisabledRow(to: menu, NSLocalizedString("menu.decklink_no_device",
                                                 value: "No DeckLink device found",
                                                 comment: "No DeckLink device found"))
      return
    }

    // -- on/off
    let toggle = menu.addItem(withTitle: dl.isRunning
                                ? NSLocalizedString("menu.decklink_stop", value: "Stop Output", comment: "Stop Output")
                                : NSLocalizedString("menu.decklink_start", value: "Start Output", comment: "Start Output"),
                              action: #selector(menuDeckLinkToggle(_:)), keyEquivalent: "")
    toggle.target = self
    toggle.isEnabled = dl.isRunning || dl.canStart

    // A failed start must say why rather than leaving the menu looking inert.
    if let error = dl.lastError {
      addDisabledRow(to: menu, error)
    }
    // Be honest about whether playout is actually keeping up.
    if dl.isRunning {
      // captured vs scheduled is the tell: if captured lags scheduled the tap is not keeping the
      // feeder supplied, and resyncs explain holes in the schedule.
      let status = String(format: NSLocalizedString("menu.decklink_status", value: "Scheduled %ld, late %ld, dropped %ld, captured %ld, resync %ld, repeat %ld", comment: "status"),
                          dl.scheduledFrames, dl.lateFrames, dl.droppedFrames,
                          dl.capturedFrames, dl.resyncCount, dl.repeatCount)
      addDisabledRow(to: menu, status)
    }

    menu.addItem(.separator())

    // -- devices
    addSectionHeader(to: menu, NSLocalizedString("menu.decklink_device", value: "Device", comment: "Device"))
    for device in devices {
      let item = menu.addItem(withTitle: device.displayName,
                              action: #selector(menuDeckLinkSelectDevice(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = device.identifier
      item.state = (device.identifier == dl.selectedDeviceID) ? .on : .off
      item.isEnabled = true
    }

    let modes = dl.modes(forDeviceID: dl.selectedDeviceID)
    guard !modes.isEmpty else { return }

    // -- video mode
    // Offer every mode the device reports and let the user choose: a 1.5G HD-SDI reference monitor
    // and a 4K HDMI panel want very different rows, and 59.94p material has no single right answer
    // (720p59.94 keeps the rate, 1080i59.94 keeps the raster). Rows the current pixel format cannot
    // carry are disabled rather than hidden, so the reason stays visible.
    menu.addItem(.separator())
    addSectionHeader(to: menu, NSLocalizedString("menu.decklink_mode", value: "Video Mode", comment: "Video Mode"))
    let modeMenu = NSMenu()
    modeMenu.autoenablesItems = false
    for mode in modes {
      let title = String(format: "%@  (%ld×%ld %@)", mode.name, mode.width, mode.height,
                         formatFPS(mode.fps))
      let item = modeMenu.addItem(withTitle: title,
                                  action: #selector(menuDeckLinkSelectMode(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = mode.index
      item.state = (mode.index == dl.selectedModeIndex) ? .on : .off
      item.isEnabled = dl.mode(mode, supports: dl.pixelFormat)
    }
    let modeItem = menu.addItem(withTitle: dl.selectedMode?.name
                                  ?? NSLocalizedString("menu.decklink_choose", value: "Choose a Video Mode", comment: "Choose…"),
                                action: nil, keyEquivalent: "")
    modeItem.submenu = modeMenu

    // -- pixel format
    let formats: [(DeckLinkPixelFormat, String, Bool)] = [
      (.format8BitYUV, "8-bit YUV 4:2:2", dl.selectedMode?.supports8BitYUV ?? true),
      (.format10BitYUV, "10-bit YUV 4:2:2", dl.selectedMode?.supports10BitYUV ?? true),
      (.format10BitRGB, "10-bit RGB 4:4:4", dl.selectedMode?.supports10BitRGB ?? true),
    ]
    let formatMenu = NSMenu()
    formatMenu.autoenablesItems = false
    for (format, title, supported) in formats {
      let item = formatMenu.addItem(withTitle: title,
                                    action: #selector(menuDeckLinkSelectFormat(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = format.rawValue
      item.state = (format == dl.pixelFormat) ? .on : .off
      item.isEnabled = supported
    }
    let formatName = formats.first { $0.0 == dl.pixelFormat }?.1 ?? "-"
    let formatItem = menu.addItem(withTitle: String(format: "%@:  %@",
                                                    NSLocalizedString("menu.decklink_pixel_format",
                                                                      value: "Pixel Format",
                                                                      comment: "Pixel Format"),
                                                    formatName),
                                  action: nil, keyEquivalent: "")
    formatItem.submenu = formatMenu

    // -- levels
    let rangeMenu = NSMenu()
    rangeMenu.autoenablesItems = false
    let ranges: [(DeckLinkVideoRange, String)] = [(.SMPTE, "SMPTE (legal)"), (.full, "Full")]
    for (value, title) in ranges {
      let item = rangeMenu.addItem(withTitle: title,
                                   action: #selector(menuDeckLinkSelectRange(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = value.rawValue
      item.state = (value == dl.range) ? .on : .off
      item.isEnabled = true
    }
    let rangeName = ranges.first { $0.0 == dl.range }?.1 ?? "-"
    let rangeItem = menu.addItem(withTitle: String(format: "%@:  %@",
                                                   NSLocalizedString("menu.decklink_levels",
                                                                     value: "Levels",
                                                                     comment: "Levels"),
                                                   rangeName),
                                 action: nil, keyEquivalent: "")
    rangeItem.submenu = rangeMenu

    // -- render strategy
    menu.addItem(.separator())
    let native = menu.addItem(withTitle: NSLocalizedString("menu.decklink_native_render",
                                                           value: "Render at Output Resolution",
                                                           comment: "render at SDI resolution"),
                              action: #selector(menuDeckLinkToggleNativeRender(_:)), keyEquivalent: "")
    native.target = self
    native.state = dl.renderAtOutputResolution ? .on : .off
    native.isEnabled = true
    native.toolTip = NSLocalizedString("menu.decklink_native_render_tip",
                                       value: "Render once at the video mode's resolution and show the window as a preview of it. Better SDI quality and less work than rendering for the window and scaling down.",
                                       comment: "")

    // -- SDI signal configuration. These change the wire format rather than our rendering, and the
    // device is asked at probe time which of them it implements, so unsupported rows are disabled
    // rather than offered and silently ignored.
    let caps = dl.capabilities
    menu.addItem(.separator())
    addSectionHeader(to: menu, NSLocalizedString("menu.decklink_sdi", value: "SDI Signal",
                                                 comment: "SDI signal section"))

    let linkMenu = NSMenu()
    linkMenu.autoenablesItems = false
    let links: [(DeckLinkSDILink, String, Bool)] = [
      (.single, NSLocalizedString("menu.decklink_link_single", value: "Single Link", comment: ""), true),
      (.dual, NSLocalizedString("menu.decklink_link_dual", value: "Dual Link", comment: ""),
       caps?.supportsDualLink ?? false),
      (.quad, NSLocalizedString("menu.decklink_link_quad", value: "Quad Link", comment: ""),
       caps?.supportsQuadLink ?? false),
    ]
    for (value, title, supported) in links {
      let item = linkMenu.addItem(withTitle: title,
                                  action: #selector(menuDeckLinkSelectLink(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = value.rawValue
      item.state = (value == dl.sdiLink) ? .on : .off
      item.isEnabled = supported
    }
    let linkName = links.first { $0.0 == dl.sdiLink }?.1 ?? "-"
    let linkItem = menu.addItem(withTitle: String(format: "%@:  %@",
                                                   NSLocalizedString("menu.decklink_link",
                                                                     value: "SDI Link",
                                                                     comment: "link configuration"),
                                                   linkName),
                                action: nil, keyEquivalent: "")
    linkItem.submenu = linkMenu

    let item444 = menu.addItem(withTitle: NSLocalizedString("menu.decklink_444",
                                                            value: "4:4:4 SDI Output", comment: ""),
                               action: #selector(menuDeckLinkToggle444(_:)), keyEquivalent: "")
    item444.target = self
    item444.state = dl.use444 ? .on : .off
    item444.isEnabled = caps?.supports444SDI ?? false
    item444.toolTip = NSLocalizedString("menu.decklink_444_tip",
                                        value: "Send full-bandwidth chroma instead of 4:2:2. Pair with a 10-bit RGB pixel format; on HD rasters this generally needs dual link for the bandwidth.",
                                        comment: "")

    let itemLevelA = menu.addItem(withTitle: NSLocalizedString("menu.decklink_level_a",
                                                               value: "Level A for 3G-SDI", comment: ""),
                                  action: #selector(menuDeckLinkToggleLevelA(_:)), keyEquivalent: "")
    itemLevelA.target = self
    itemLevelA.state = dl.levelA ? .on : .off
    itemLevelA.isEnabled = caps?.supportsLevelA ?? false
    itemLevelA.toolTip = NSLocalizedString("menu.decklink_level_a_tip",
                                           value: "SMPTE Level A signalling for 3G-SDI. Level B is the default and more widely accepted; some monitors and routers require A.",
                                           comment: "")

    // -- aspect handling
    let scalingMenu = NSMenu()
    scalingMenu.autoenablesItems = false
    let scalings: [(DeckLinkScaling, String)] = [
      (.fit, NSLocalizedString("menu.decklink_scaling_fit", value: "Fit (letterbox)", comment: "")),
      (.fill, NSLocalizedString("menu.decklink_scaling_fill", value: "Fill (crop)", comment: "")),
      (.stretch, NSLocalizedString("menu.decklink_scaling_stretch", value: "Stretch (distort)", comment: "")),
    ]
    for (value, title) in scalings {
      let item = scalingMenu.addItem(withTitle: title,
                                     action: #selector(menuDeckLinkSelectScaling(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = value.rawValue
      item.state = (value == dl.scaling) ? .on : .off
      item.isEnabled = !dl.renderAtOutputResolution
    }
    let scalingName = scalings.first { $0.0 == dl.scaling }?.1 ?? "-"
    let scalingItem = menu.addItem(withTitle: String(format: "%@:  %@",
                                                     NSLocalizedString("menu.decklink_scaling",
                                                                       value: "Aspect Handling", comment: ""),
                                                     scalingName),
                                   action: nil, keyEquivalent: "")
    scalingItem.submenu = scalingMenu
    scalingItem.isEnabled = !dl.renderAtOutputResolution
    scalingItem.toolTip = NSLocalizedString("menu.decklink_scaling_tip",
                                            value: "What to do when the picture and the SDI raster are different shapes. Fit keeps the whole picture and adds bars, which is what a broadcast chain expects. Ignored under Render at Output Resolution, where mpv renders straight into the raster and fits it itself.",
                                            comment: "")

    // -- field mode, only meaningful on an interlaced raster. PsF rasters and progressive modes have
    // nothing to choose, so the row is offered but disabled rather than silently ignored.
    let interlacedRaster = dl.selectedMode?.isInterlaced ?? false
    let fieldMenu = NSMenu()
    fieldMenu.autoenablesItems = false
    let fieldModes: [(DeckLinkFieldMode, String)] = [
      (.psf, NSLocalizedString("menu.decklink_field_psf", value: "PsF (whole frames)", comment: "")),
      (.trueInterlace, NSLocalizedString("menu.decklink_field_true", value: "True Interlace (field-rate)", comment: "")),
    ]
    for (value, title) in fieldModes {
      let item = fieldMenu.addItem(withTitle: title,
                                   action: #selector(menuDeckLinkSelectFieldMode(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = value.rawValue
      item.state = (value == dl.fieldMode) ? .on : .off
      item.isEnabled = interlacedRaster
    }
    let fieldName = fieldModes.first { $0.0 == dl.fieldMode }?.1 ?? "-"
    let fieldItem = menu.addItem(withTitle: String(format: "%@:  %@",
                                                   NSLocalizedString("menu.decklink_fields", value: "Fields", comment: ""),
                                                   fieldName),
                                 action: nil, keyEquivalent: "")
    fieldItem.submenu = fieldMenu
    fieldItem.isEnabled = interlacedRaster
    fieldItem.toolTip = NSLocalizedString("menu.decklink_fields_tip",
                                          value: "PsF carries whole progressive frames in an interlaced raster, which is right for film and any progressive source. True Interlace samples each field a field period apart, which is what a CRT's scan shows, and needs motion at the field rate to be worth anything.",
                                          comment: "")

    // -- field order, which only weaving can hear: PsF puts one instant in both fields.
    let orderMenu = NSMenu()
    orderMenu.autoenablesItems = false
    let reported = (dl.selectedMode?.upperFieldFirst ?? true) ? "upper" : "lower"
    let fieldOrders: [(DeckLinkFieldOrder, String)] = [
      (.auto, String(format: NSLocalizedString("menu.decklink_field_order_auto",
                                               value: "Auto (%@ first)", comment: ""), reported)),
      (.upperFirst, NSLocalizedString("menu.decklink_field_order_upper", value: "Upper Field First", comment: "")),
      (.lowerFirst, NSLocalizedString("menu.decklink_field_order_lower", value: "Lower Field First", comment: "")),
    ]
    let orderEnabled = interlacedRaster && dl.fieldMode == .trueInterlace
    for (value, title) in fieldOrders {
      let item = orderMenu.addItem(withTitle: title,
                                   action: #selector(menuDeckLinkSelectFieldOrder(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = value.rawValue
      item.state = (value == dl.fieldOrder) ? .on : .off
      item.isEnabled = orderEnabled
    }
    let orderName = fieldOrders.first { $0.0 == dl.fieldOrder }?.1 ?? "-"
    let orderItem = menu.addItem(withTitle: String(format: "%@:  %@",
                                                   NSLocalizedString("menu.decklink_field_order",
                                                                     value: "Field Order", comment: ""),
                                                   orderName),
                                 action: nil, keyEquivalent: "")
    orderItem.submenu = orderMenu
    orderItem.isEnabled = orderEnabled
    orderItem.toolTip = NSLocalizedString("menu.decklink_field_order_tip",
                                          value: "Which field the card transmits first, and so which one carries the earlier moment. Auto follows the driver, which is right for a conforming chain. Backwards, motion advances two steps and falls back one at the field rate, which reads as a vibration on any pan.",
                                          comment: "")

    let cadence = menu.addItem(withTitle: NSLocalizedString("menu.decklink_film_cadence",
                                                            value: "Film Cadence (2:3 Pulldown)", comment: ""),
                               action: #selector(menuDeckLinkToggleFilmCadence(_:)), keyEquivalent: "")
    cadence.target = self
    cadence.state = dl.filmCadence ? .on : .off
    cadence.isEnabled = dl.filmCadenceAvailable
    cadence.toolTip = NSLocalizedString("menu.decklink_film_cadence_tip",
                                        value: "Lay 23.976 film onto the 59.94 field raster as broadcast does, three fields then two, generated on the card's clock rather than resampled from the window. Needs True Interlace, and the scheduled path rather than Low Latency, because the cadence has to be clocked by the card.",
                                        comment: "")

    let twitter = menu.addItem(withTitle: NSLocalizedString("menu.decklink_interline",
                                                             value: "Interline Filter", comment: ""),
                               action: #selector(menuDeckLinkToggleInterlineFilter(_:)), keyEquivalent: "")
    twitter.target = self
    twitter.state = dl.interlineFilter ? .on : .off
    twitter.isEnabled = dl.selectedMode?.isInterlacedOrPsF ?? false
    twitter.toolTip = NSLocalizedString("menu.decklink_interline_tip",
                                        value: "Band-limit vertically before the lines are split into fields. A CRT draws alternate lines in alternate fields, so single-line detail shimmers at the field rate; this trades some vertical resolution to stop it.",
                                        comment: "")

    // -- latency strategy
    let lowLat = menu.addItem(withTitle: NSLocalizedString("menu.decklink_low_latency",
                                                           value: "Low Latency Mode",
                                                           comment: "immediate display"),
                              action: #selector(menuDeckLinkToggleLowLatency(_:)), keyEquivalent: "")
    lowLat.target = self
    lowLat.state = dl.lowLatency ? .on : .off
    lowLat.isEnabled = true
    lowLat.toolTip = NSLocalizedString("menu.decklink_low_latency_tip",
                                       value: "Show each frame at the card's next refresh instead of queueing it for scheduled playback. Cuts output delay to under a frame; timing follows this Mac rather than the card's clock.",
                                       comment: "")

    // -- device release
    menu.addItem(.separator())
    let release = menu.addItem(withTitle: NSLocalizedString("menu.decklink_release",
                                                            value: "Release Device When Inactive",
                                                            comment: "Release Device When Inactive"),
                               action: #selector(menuDeckLinkToggleRelease(_:)), keyEquivalent: "")
    release.target = self
    release.state = dl.releaseWhenInactive ? .on : .off
    release.isEnabled = true
  }

  // MARK: - actions

  @objc func menuDeckLinkToggle(_ sender: NSMenuItem) {
    DeckLinkController.shared.toggle()
  }

  @objc func menuDeckLinkSelectDevice(_ sender: NSMenuItem) {
    DeckLinkController.shared.selectDevice(sender.representedObject as? String)
  }

  @objc func menuDeckLinkSelectMode(_ sender: NSMenuItem) {
    guard let index = sender.representedObject as? Int else { return }
    DeckLinkController.shared.selectMode(index)
  }

  @objc func menuDeckLinkSelectFormat(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? Int,
          let format = DeckLinkPixelFormat(rawValue: raw) else { return }
    DeckLinkController.shared.selectPixelFormat(format)
  }

  @objc func menuDeckLinkSelectRange(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? Int,
          let range = DeckLinkVideoRange(rawValue: raw) else { return }
    DeckLinkController.shared.selectRange(range)
  }

  @objc func menuDeckLinkToggleNativeRender(_ sender: NSMenuItem) {
    DeckLinkController.shared.renderAtOutputResolution.toggle()
  }

  @objc func menuDeckLinkSelectLink(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? Int,
          let link = DeckLinkSDILink(rawValue: raw) else { return }
    DeckLinkController.shared.selectSDILink(link)
  }

  @objc func menuDeckLinkSelectScaling(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? Int,
          let mode = DeckLinkScaling(rawValue: raw) else { return }
    DeckLinkController.shared.setScaling(mode)
  }

  @objc func menuDeckLinkToggleFilmCadence(_ sender: NSMenuItem) {
    DeckLinkController.shared.setFilmCadence(sender.state != .on)
  }

  @objc func menuDeckLinkSelectFieldOrder(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? Int,
          let order = DeckLinkFieldOrder(rawValue: raw) else { return }
    DeckLinkController.shared.setFieldOrder(order)
  }

  @objc func menuDeckLinkSelectFieldMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? Int,
          let mode = DeckLinkFieldMode(rawValue: raw) else { return }
    DeckLinkController.shared.setFieldMode(mode)
  }

  @objc func menuDeckLinkToggleInterlineFilter(_ sender: NSMenuItem) {
    let dl = DeckLinkController.shared
    dl.setInterlineFilter(!dl.interlineFilter)
  }

  @objc func menuDeckLinkToggle444(_ sender: NSMenuItem) {
    let dl = DeckLinkController.shared
    dl.setUse444(!dl.use444)
  }

  @objc func menuDeckLinkToggleLevelA(_ sender: NSMenuItem) {
    let dl = DeckLinkController.shared
    dl.setLevelA(!dl.levelA)
  }

  @objc func menuDeckLinkToggleLowLatency(_ sender: NSMenuItem) {
    DeckLinkController.shared.lowLatency.toggle()
  }

  @objc func menuDeckLinkToggleRelease(_ sender: NSMenuItem) {
    DeckLinkController.shared.releaseWhenInactive.toggle()
  }

  // MARK: - helpers

  private func addDisabledRow(to menu: NSMenu, _ title: String) {
    let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
  }

  private func addSectionHeader(to menu: NSMenu, _ title: String) {
    let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: title,
      attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)])
  }

  /// 29.97 rather than 29.970, and 25 rather than 25.000.
  private func formatFPS(_ fps: Double) -> String {
    let rounded = (fps * 100).rounded() / 100
    return rounded == rounded.rounded()
      ? String(format: "%.0f fps", rounded)
      : String(format: "%.2f fps", rounded)
  }
}
