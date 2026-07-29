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
  }

  /// Rebuild the submenu from what the hardware currently reports.
  func updateDeckLinkMenu(_ menu: NSMenu) {
    let dl = DeckLinkController.shared
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
    let formatItem = menu.addItem(withTitle: NSLocalizedString("menu.decklink_pixel_format",
                                                               value: "Pixel Format",
                                                               comment: "Pixel Format"),
                                  action: nil, keyEquivalent: "")
    formatItem.submenu = formatMenu

    // -- levels
    let rangeMenu = NSMenu()
    rangeMenu.autoenablesItems = false
    for (value, title) in [(DeckLinkVideoRange.SMPTE, "SMPTE (legal)"), (.full, "Full")] {
      let item = rangeMenu.addItem(withTitle: title,
                                   action: #selector(menuDeckLinkSelectRange(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = value.rawValue
      item.state = (value == dl.range) ? .on : .off
      item.isEnabled = true
    }
    let rangeItem = menu.addItem(withTitle: NSLocalizedString("menu.decklink_levels",
                                                              value: "Levels",
                                                              comment: "Levels"),
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
