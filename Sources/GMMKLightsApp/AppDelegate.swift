import AppKit
import GMMKProtocol
import GloriousAudioCapture
import GloriousMouseProtocol
import GloriousSync
import GloriousVisualizer

/// Status-item menu for both devices: the keyboard's effect picker, brightness,
/// speed, colour and switch compensation, then the mouse's own section.
///
/// The two halves share nothing but the menu and the colour panel. Keyboard
/// state is mirrored in `UserDefaults` because the app drives it; mouse state is
/// read back from the device before every draw because the mouse owns it. Each
/// section hides itself when its device is absent.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let controller = KeyboardController()
    private let mouseController = MouseController()
    private lazy var mouseSection = MouseMenuSection(controller: mouseController) {
        [weak self] in self?.presentColorPanel(for: .mouse)
    }
    private var settings = Settings()
    private lazy var sync = SyncCoordinator(keyboard: controller,
                                            mouse: mouseController) { [weak self] in
        self?.settings.compensationProfile ?? .neutral
    }

    private lazy var visualizer = VisualizerController(
        lease: controller.lease,
        source: settings.visualizerSource,
        mode: settings.visualizerMode,
        themeColor: settings.color,
        sensitivity: settings.visualizerSensitivity,
        autoGain: settings.visualizerAutoGain)
    private let visualizerItem = NSMenuItem(title: "Audio Visualizer",
                                            action: nil, keyEquivalent: "")
    private let visualizerOptionsItem = NSMenuItem(title: "Visualizer Options",
                                                   action: nil, keyEquivalent: "")
    private let visualizerModeMenu = NSMenu()
    private let visualizerSourceMenu = NSMenu()
    private let visualizerSensitivityMenu = NSMenu()
    private let visualizerAutoGainItem = NSMenuItem(title: "Auto Gain",
                                                    action: nil, keyEquivalent: "")

    private let syncSeparator = NSMenuItem.separator()
    private let syncItem = NSMenuItem(title: "Sync Devices", action: nil, keyEquivalent: "")
    private let themesItem = NSMenuItem(title: "Desk Themes", action: nil, keyEquivalent: "")

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private let connectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let effectItem = NSMenuItem(title: "Effect", action: nil, keyEquivalent: "")
    private let effectMenu = NSMenu()
    private let rainbowItem = NSMenuItem(title: "Rainbow", action: nil, keyEquivalent: "")
    private let compensatedItem = NSMenuItem(title: "Uniform Color (Compensated)",
                                             action: nil, keyEquivalent: "")
    /// Advisory note under the colour row, shown only for red-heavy colours.
    private let redHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Which device the shared `NSColorPanel` is currently editing, or `nil`
    /// when this delegate is not driving it. One panel, two devices, so the
    /// target has to be remembered rather than inferred.
    private var colorPanelTarget: ColorPanelTarget?

    private enum ColorPanelTarget {
        case keyboard
        case mouse
    }

    /// How long the colour panel must be still before a mouse colour is sent.
    static let mouseColorDebounce: TimeInterval = 0.150
    private var pendingMouseColor: DispatchWorkItem?
    /// Kept across openings so the tuner reopens with its state intact.
    private lazy var tuner = SwitchCompensationWindowController(controller: controller)
    private lazy var ledPicker = MouseLEDWindowController(controller: mouseController,
                                                          colors: settings.mouseLEDColors)

    private lazy var brightnessRow = SliderRowView(title: "Brightness",
                                                   range: 0...100) { "\($0)%" }
    private lazy var speedRow = SliderRowView(title: "Speed",
                                              range: 1...5,
                                              tickCount: 5) { "\($0) / 5" }
    private let colorRow = ColorRowView()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard",
                                           accessibilityDescription: "Glorious Lights")
        statusItem.button?.image?.isTemplate = true
        statusItem.menu = menu

        buildMenu()
        applySettingsToUI()

        controller.onStatusChange = { [weak self] in self?.refreshConnectionItem() }
        // Monitoring only. Deliberately no initial send: the keyboard keeps its
        // own settings in flash, and pushing our restored UI state at login
        // would clobber whatever the user last set by other means.
        controller.start()

        // The mouse is read, never written, on connect: its settings live in its
        // own flash too, and the menu is drawn from what it reports.
        mouseController.onStatusChange = { [weak self] in self?.mouseSection.refresh() }
        mouseController.start()

        // First launch only: prefer system audio when it is already granted,
        // since it hears the mix rather than the room. Never overrides a source
        // the user has since chosen, and never provokes a permission prompt —
        // an ungranted source is simply not preferred.
        if !settings.hasChosenVisualizerSource {
            settings.visualizerSource = preferredAudioSource(
                systemAudio: SystemAudio.authorization,
                microphone: AudioCapture.authorization)
            settings.hasChosenVisualizerSource = true
            settings.save()
            visualizer.source = settings.visualizerSource
        }

        visualizer.onStatusChange = { [weak self] in self?.refreshVisualizerItems() }

        refreshConnectionItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the visualizer first: it holds the transport lease and its own
        // keyboard handle, and it restores the user's look on the way out.
        if visualizer.isRunning { stopVisualizer() }
        controller.stop()
        mouseController.stop()
        settings.save()
    }

    // MARK: - Menu construction

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        connectionItem.isEnabled = false
        menu.addItem(connectionItem)
        menu.addItem(.separator())

        for mode in LightingMode.allCases {
            let item = NSMenuItem(title: mode.displayName,
                                  action: #selector(selectEffect(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            effectMenu.addItem(item)
        }
        effectItem.submenu = effectMenu
        menu.addItem(effectItem)

        rainbowItem.action = #selector(toggleRainbow(_:))
        rainbowItem.target = self
        menu.addItem(rainbowItem)

        compensatedItem.action = #selector(applyCompensated(_:))
        compensatedItem.target = self
        menu.addItem(compensatedItem)

        let tuneItem = NSMenuItem(title: "Tune Switch Compensation…",
                                  action: #selector(openTuner(_:)),
                                  keyEquivalent: "")
        tuneItem.target = self
        menu.addItem(tuneItem)

        visualizerItem.action = #selector(toggleVisualizer(_:))
        visualizerItem.target = self
        menu.addItem(visualizerItem)
        menu.addItem(buildVisualizerOptions())
        menu.addItem(.separator())

        brightnessRow.onChange = { [weak self] percent in
            guard let self else { return }
            self.settings.brightnessPercent = percent
            self.rememberKeyboardLook()
            self.settings.save()
            self.controller.setBrightness(percent: percent)
            // The mouse write is a whole blob, so it rides the slider's own
            // throttle rather than firing on every intermediate value.
            self.syncToMouse()
        }
        menu.addItem(row(brightnessRow))

        speedRow.onChange = { [weak self] speed in
            guard let self else { return }
            self.settings.speed = speed
            self.settings.save()
            self.controller.setSpeed(speed)
        }
        menu.addItem(row(speedRow))

        colorRow.onClick = { [weak self] in self?.presentColorPanel(for: .keyboard) }
        menu.addItem(row(colorRow))

        // Advisory, never blocking: a red-heavy colour is the one case where a
        // mixed-switch board looks obviously mismatched, and the fix is to pick
        // a different colour rather than to correct harder.
        redHintItem.isEnabled = false
        redHintItem.attributedTitle = NSAttributedString(
            string: "Red-heavy — will show your switch mix",
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        redHintItem.indentationLevel = 1
        menu.addItem(redHintItem)

        menu.addItem(switchFriendlyItem())

        mouseSection.install(in: menu)
        mouseSection.onLookChanged = { [weak self] in self?.syncFromMouse() }
        mouseSection.onOpenPerLEDPicker = { [weak self] in self?.openLEDPicker() }

        menu.addItem(syncSeparator)
        syncItem.action = #selector(toggleSync(_:))
        syncItem.target = self
        menu.addItem(syncItem)

        let themesMenu = NSMenu()
        for (index, group) in DeskTheme.groups.enumerated() {
            if index > 0 { themesMenu.addItem(.separator()) }
            let header = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            themesMenu.addItem(header)
            for theme in group.entries {
                let item = NSMenuItem(title: theme.name,
                                      action: #selector(selectTheme(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = theme.look
                item.image = swatchImage(nsColor(theme.look.color.keyboardColor))
                item.indentationLevel = 1
                themesMenu.addItem(item)
            }
        }
        themesItem.submenu = themesMenu
        menu.addItem(themesItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Glorious Lights",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func row(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    /// Submenu of colours both switch housings render about the same, so the
    /// board looks uniform with no per-key correction at all — see
    /// ``SwitchFriendlyPalette``. These are ordinary solid colours.
    private func switchFriendlyItem() -> NSMenuItem {
        let submenu = NSMenu()
        for swatch in SwitchFriendlyPalette.swatches {
            let item = NSMenuItem(title: swatch.name,
                                  action: #selector(selectSwitchFriendlyColor(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = swatch.color
            item.image = swatchImage(nsColor(swatch.color))
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Switch-Friendly Colors", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func swatchImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 12)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 2, yRadius: 2)
            color.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            return true
        }
    }

    // MARK: - State → UI

    private func applySettingsToUI() {
        brightnessRow.setValue(settings.brightnessPercent)
        speedRow.setValue(settings.speed)
        colorRow.setColor(nsColor(settings.color), hexText: "#" + settings.color.hexString)
        refreshEnablement()
    }

    private func refreshEnablement() {
        // While the visualizer holds the transport, the controls that would
        // fight it are disabled rather than silently dropped: the lease already
        // drops their sends, and a control that looks live but does nothing is
        // worse than one that says it is unavailable.
        let visualizing = visualizer.isRunning
        for item in [effectItem, rainbowItem, compensatedItem] {
            item.isEnabled = !visualizing
            item.toolTip = visualizing ? "Stop the audio visualizer to change this." : nil
        }

        for item in effectMenu.items {
            let mode = item.representedObject as? LightingMode
            item.state = (mode == settings.mode && !settings.compensated) ? .on : .off
        }
        effectItem.title = settings.compensated
            ? "Effect: " + compensatedItem.title
            : "Effect: \(settings.mode.displayName)"
        compensatedItem.state = settings.compensated ? .on : .off
        rainbowItem.state = settings.rainbow ? .on : .off
        rainbowItem.isEnabled = settings.mode.usesSolidColor

        brightnessRow.isControlEnabled = !visualizing
        speedRow.isControlEnabled = settings.mode.isAnimated && !visualizing
        // A colour write only shows up when the mode uses the solid colour and
        // the rainbow flag is off — clicking through to the panel otherwise
        // would look like the app was broken. The compensated paint is the
        // exception: it is in mode `custom`, which ignores the config colour,
        // but the same swatch is its target.
        let colorEnabled = !visualizing
            && (settings.compensated || (settings.mode.usesSolidColor && !settings.rainbow))
        colorRow.setEnabled(colorEnabled)
        // The hint is about the colour the board is actually showing, so it is
        // pointless when the colour is not in play at all.
        redHintItem.isHidden = !colorEnabled || !SwitchCompensation.isRedHeavy(settings.color)
        // An already-open panel outlives the row that spawned it, so detach it
        // too; otherwise dragging in it keeps writing colour while the menu
        // says the control is unavailable.
        if !colorEnabled { dismissColorPanel() }
    }

    private func refreshConnectionItem() {
        if controller.isConnected {
            connectionItem.title = "Keyboard connected"
        } else if controller.lastError != nil {
            connectionItem.title = "Keyboard found, but not usable"
            connectionItem.toolTip = controller.lastError
        } else {
            connectionItem.title = "Keyboard not found"
            connectionItem.toolTip = nil
        }
        statusItem?.button?.appearsDisabled = !controller.isConnected
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshConnectionItem()
        refreshEnablement()
        mouseSection.refresh()
        refreshSyncSection()
        refreshVisualizerItems()
    }

    /// The sync section is about *both* devices, so it only appears when at
    /// least one is here — and the toggle itself only means anything when both
    /// are, since it describes copying changes from one to the other.
    private func refreshSyncSection() {
        let anyDevice = controller.isConnected || mouseController.isConnected
        let bothDevices = controller.isConnected && mouseController.isConnected
        for item in [syncSeparator, syncItem, themesItem] { item.isHidden = !anyDevice }

        syncItem.state = settings.syncDevices ? .on : .off
        syncItem.isEnabled = bothDevices
        syncItem.toolTip = bothDevices
            ? "Apply a change made to one device to the other as well."
            : "Both the keyboard and the mouse have to be connected to sync them."
        // Themes need no partner: they apply to whatever is plugged in.
        // A theme writes to the keyboard, so it waits for the visualizer too —
        // unless only the mouse is present, which the visualizer never touches.
        themesItem.isEnabled = anyDevice
            && !(visualizer.isRunning && controller.isConnected)
    }

    // MARK: - Actions

    @objc private func selectEffect(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? LightingMode else { return }
        settings.mode = mode
        settings.compensated = false
        rememberKeyboardLook()
        settings.save()
        refreshEnablement()
        controller.setMode(mode)
        syncToMouse()
    }

    /// Paints the whole board the chosen colour, correcting the keys whose
    /// housing tints it.
    ///
    /// This is mode `custom` on the device — the same mode as the plain effect
    /// of that name — so the app's own ``Settings/compensated`` flag is what
    /// distinguishes them in the menu.
    @objc private func applyCompensated(_ sender: NSMenuItem) {
        settings.mode = .custom
        settings.compensated = true
        rememberKeyboardLook()
        settings.save()
        refreshEnablement()
        paintCompensated()
        syncToMouse()
    }

    /// Applies a ``SwitchFriendlyPalette`` swatch.
    ///
    /// These colours are chosen so both housings render them about the same, so
    /// ordinarily this is a plain global solid colour. If the user has tuned a
    /// compensation profile it still rides the per-key path, because a global
    /// write in `fixed` mode would throw the tuning away.
    @objc private func selectSwitchFriendlyColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? RGB else { return }
        let profile = settings.compensationProfile
        settings.color = color
        settings.compensated = profile.isActive
        settings.mode = profile.isActive ? .custom : .fixed
        settings.rainbow = false
        settings.save()
        colorRow.setColor(nsColor(color), hexText: "#" + color.hexString)
        refreshEnablement()
        controller.setSolidColor(color,
                                 brightnessPercent: settings.brightnessPercent,
                                 compensation: profile)
        rememberKeyboardLook()
        syncToMouse()
    }

    /// Opens the per-LED picker.
    ///
    /// The colour wells in that window drive the *shared* `NSColorPanel`, the
    /// same one this delegate points at the keyboard or the mouse's single
    /// colour. Letting go of it first keeps ``dismissColorPanel()`` — which
    /// fires whenever the colour row becomes irrelevant — from yanking the
    /// panel out from under an active well.
    private func openLEDPicker() {
        dismissColorPanel()
        ledPicker.onChange = { [weak self] colors in
            guard let self else { return }
            self.settings.mouseLEDColors = colors
            self.settings.save()
        }
        ledPicker.present(colors: settings.mouseLEDColors)
    }

    // MARK: - Visualizer

    private func buildVisualizerOptions() -> NSMenuItem {
        let submenu = NSMenu()

        for mode in VisualizerMode.allCases {
            let item = NSMenuItem(title: mode.displayName,
                                  action: #selector(selectVisualizerMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.toolTip = mode.summary
            visualizerModeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = visualizerModeMenu
        submenu.addItem(modeItem)

        for source in AudioSource.allCases {
            let item = NSMenuItem(title: source.displayName,
                                  action: #selector(selectVisualizerSource(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = source
            visualizerSourceMenu.addItem(item)
        }
        let sourceItem = NSMenuItem(title: "Source", action: nil, keyEquivalent: "")
        sourceItem.submenu = visualizerSourceMenu
        submenu.addItem(sourceItem)

        // Centred on 1.0, which is where the pipeline's own normalisation puts
        // a typical loud passage at full height. The steps are geometric
        // because the difference between 1x and 1.5x matters far more than
        // between 3x and 4x.
        for multiplier in [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0] {
            let item = NSMenuItem(title: String(format: "%.1f×", multiplier),
                                  action: #selector(selectVisualizerSensitivity(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = multiplier
            visualizerSensitivityMenu.addItem(item)
        }
        let sensitivityItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        sensitivityItem.submenu = visualizerSensitivityMenu
        submenu.addItem(sensitivityItem)

        visualizerAutoGainItem.action = #selector(toggleVisualizerAutoGain(_:))
        visualizerAutoGainItem.target = self
        visualizerAutoGainItem.toolTip = "Normalise to the loudest sound heard recently, "
            + "so quiet and loud material both fill the board."
        submenu.addItem(visualizerAutoGainItem)

        visualizerOptionsItem.submenu = submenu
        return visualizerOptionsItem
    }

    /// Authorization for whichever source is selected.
    private var currentSourceAuthorization: AudioSourceAuthorization {
        switch settings.visualizerSource {
        case .microphone:  return AudioCapture.authorization
        case .systemAudio: return SystemAudio.authorization
        }
    }

    private func refreshVisualizerItems() {
        visualizerItem.state = visualizer.isRunning ? .on : .off
        let source = settings.visualizerSource
        let authorization = currentSourceAuthorization

        switch authorization {
        case .denied:
            visualizerItem.title = "Audio Visualizer — \(source.permissionName.lowercased()) "
                + "access needed"
            visualizerItem.toolTip = "Grant access in System Settings › Privacy & Security › "
                + "\(source.permissionName), then try again."
        case .unavailable:
            visualizerItem.title = "Audio Visualizer — system audio needs macOS 14.2"
            visualizerItem.toolTip = "Capturing system audio uses CoreAudio process taps, "
                + "added in macOS 14.2. Switch the source to Microphone."
        case .granted, .undetermined:
            visualizerItem.title = "Audio Visualizer"
            visualizerItem.toolTip = visualizer.lastError
        }
        // Still clickable when denied: the click is what opens System Settings.
        visualizerItem.isEnabled = (controller.isConnected && authorization != .unavailable)
            || authorization == .denied

        for item in visualizerSourceMenu.items {
            guard let itemSource = item.representedObject as? AudioSource else { continue }
            item.state = itemSource == source ? .on : .off
            let itemAuthorization = itemSource == .microphone
                ? AudioCapture.authorization
                : SystemAudio.authorization
            item.isEnabled = itemAuthorization != .unavailable
            item.toolTip = itemAuthorization == .unavailable
                ? "Needs macOS 14.2 or later."
                : "Needs \(itemSource.permissionName) permission."
        }

        for item in visualizerModeMenu.items {
            item.state = (item.representedObject as? VisualizerMode) == settings.visualizerMode
                ? .on : .off
        }
        for item in visualizerSensitivityMenu.items {
            item.state = (item.representedObject as? Double) == settings.visualizerSensitivity
                ? .on : .off
        }
        visualizerAutoGainItem.state = settings.visualizerAutoGain ? .on : .off
        visualizerOptionsItem.isEnabled = true
    }

    @objc private func toggleVisualizer(_ sender: NSMenuItem) {
        if currentSourceAuthorization == .denied {
            openPrivacySettings(for: settings.visualizerSource)
            return
        }
        if visualizer.isRunning {
            stopVisualizer()
            return
        }
        // The microphone can be asked ahead of time, and asking is
        // asynchronous, so the start hangs off the answer rather than racing
        // it. System audio has no such API — its prompt appears when the tap is
        // created, so starting *is* the request.
        if settings.visualizerSource == .microphone,
           AudioCapture.authorization == .undetermined {
            AudioCapture.requestAuthorization { [weak self] authorization in
                guard let self else { return }
                if authorization == .granted { self.startVisualizer() }
                self.refreshVisualizerItems()
            }
            return
        }
        startVisualizer()
    }

    private func startVisualizer() {
        visualizer.source = settings.visualizerSource
        visualizer.update(mode: settings.visualizerMode,
                          themeColor: settings.color,
                          sensitivity: settings.visualizerSensitivity,
                          autoGain: settings.visualizerAutoGain)
        visualizer.start()
        refreshVisualizerItems()
        refreshEnablement()
    }

    /// Stops the visualizer and puts the board back where the user left it.
    ///
    /// The restore matters: the visualizer leaves the board in mode `custom`
    /// showing whatever the last frame was, which is not a state anyone chose.
    /// `stop()` blocks until the render thread is done, so this cannot race a
    /// final frame.
    private func stopVisualizer() {
        visualizer.stop()
        reapplyCurrentLook()
        refreshVisualizerItems()
        refreshEnablement()
    }

    /// Re-sends the persisted keyboard state — the same thing the menu would
    /// send if the user picked it again.
    private func reapplyCurrentLook() {
        let profile = settings.compensationProfile
        if settings.compensated {
            controller.setBrightness(percent: settings.brightnessPercent)
            controller.paintCompensated(target: settings.color,
                                        profile: profile,
                                        throttleKey: nil)
            return
        }
        controller.applyLook(mode: settings.mode,
                             rainbow: settings.rainbow,
                             brightness: Brightness.level(fromPercent: settings.brightnessPercent),
                             delay: Delay.delay(fromSpeed: settings.speed),
                             color: settings.color)
    }

    /// Opens the Privacy pane for whichever permission the source needs.
    ///
    /// The anchors are the ones System Settings' own privacy extension
    /// declares — system audio is `Privacy_AudioCapture`, a different pane from
    /// the microphone's.
    private func openPrivacySettings(for source: AudioSource) {
        let anchor = source == .systemAudio ? "Privacy_AudioCapture" : "Privacy_Microphone"
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        if let url { NSWorkspace.shared.open(url) }
    }

    @objc private func selectVisualizerSource(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? AudioSource else { return }
        settings.visualizerSource = source
        settings.save()
        // Switching source mid-session restarts capture: the pipeline is
        // source-agnostic but the capture object is not.
        if visualizer.isRunning {
            visualizer.stop()
            visualizer.source = source
            visualizer.start()
        } else {
            visualizer.source = source
        }
        refreshVisualizerItems()
    }

    @objc private func selectVisualizerMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? VisualizerMode else { return }
        settings.visualizerMode = mode
        settings.save()
        visualizer.update(mode: mode, themeColor: settings.color)
        refreshVisualizerItems()
    }

    @objc private func selectVisualizerSensitivity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        settings.visualizerSensitivity = value
        settings.save()
        visualizer.update(sensitivity: value)
        refreshVisualizerItems()
    }

    @objc private func toggleVisualizerAutoGain(_ sender: NSMenuItem) {
        settings.visualizerAutoGain.toggle()
        settings.save()
        visualizer.update(autoGain: settings.visualizerAutoGain)
        refreshVisualizerItems()
    }

    @objc private func openTuner(_ sender: NSMenuItem) {
        tuner.onChange = { [weak self] profile in
            guard let self else { return }
            self.settings.markedLEDIndices = profile.markedLEDIndices
            self.settings.markedSwitches = profile.markedSwitches
            self.settings.compensationStrength = profile.strength
            self.settings.compensationBalance = profile.balance
            self.settings.save()
        }
        // Opening the tuner paints, which leaves the board in mode `custom`
        // showing the compensated colours — so record that as the current state
        // rather than letting the menu keep claiming the old effect.
        settings.mode = .custom
        settings.compensated = true
        settings.save()
        refreshEnablement()
        tuner.present(target: settings.color, profile: settings.compensationProfile)
    }

    private func paintCompensated() {
        controller.paintCompensated(target: settings.color,
                                    profile: settings.compensationProfile)
    }

    // MARK: - Sync

    @objc private func toggleSync(_ sender: NSMenuItem) {
        settings.syncDevices.toggle()
        settings.save()
        refreshSyncSection()
        // Turning it on is itself an instruction to match: push the look the
        // keyboard is showing onto the mouse, rather than waiting for the next
        // change and leaving the desk mismatched in the meantime.
        if settings.syncDevices { sync.applyToMouse(settings.deskLook) }
    }

    /// Applies a curated look to every device that is present, regardless of the
    /// sync toggle — picking a theme *is* the instruction to match.
    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let look = sender.representedObject as? DeskLook else { return }
        settings.deskLook = look
        // Keep the keyboard's own UI state honest about what was just sent.
        settings.color = look.color.keyboardColor
        settings.brightnessPercent = Int((look.clampedBrightness * 100).rounded())
        let plan = GloriousSync.keyboardPlan(for: look)
        settings.mode = plan.mode
        settings.rainbow = plan.rainbow
        settings.compensated = plan.mode == .fixed && !plan.rainbow
            && settings.compensationProfile.isActive
        settings.save()
        applySettingsToUI()
        sync.apply(look)
    }

    /// Mirrors a keyboard-side change onto the mouse, if syncing is on and the
    /// change is one a desk look can describe.
    private func syncToMouse() {
        guard settings.syncDevices, mouseController.isConnected else { return }
        sync.applyToMouse(settings.deskLook)
    }

    /// Mirrors a mouse-side change onto the keyboard, reading back what the
    /// mouse actually ended up with rather than what was asked for.
    private func syncFromMouse() {
        guard settings.syncDevices, controller.isConnected,
              let config = mouseController.config,
              var look = sync.deskLook(fromMouse: config) else { return }
        // An effect with no colour of its own keeps the look's existing one, so
        // switching the mouse to rainbow and back does not lose the colour.
        if GloriousSync.mousePlan(for: look).color == nil {
            look.color = settings.deskLook.color
        }
        settings.deskLook = look
        let plan = GloriousSync.keyboardPlan(for: look)
        settings.mode = plan.mode
        settings.rainbow = plan.rainbow
        settings.color = look.color.keyboardColor
        settings.brightnessPercent = Int((look.clampedBrightness * 100).rounded())
        settings.compensated = false
        settings.save()
        applySettingsToUI()
        sync.applyToKeyboard(look)
    }

    /// Records a keyboard-side change in the stored look, so a later sync or a
    /// relaunch describes what the desk is actually showing.
    private func rememberKeyboardLook() {
        settings.deskLook.color = DeskColor(settings.color)
        settings.deskLook.brightness = Double(settings.brightnessPercent) / 100
        // The speed row is 1 (slowest) … 5 (fastest); a look is 0…1.
        settings.deskLook.speed = Double(settings.speed - 1) / 4
        // An effect with no counterpart leaves the family alone rather than
        // approximating: picking Vortex says nothing about what the mouse
        // should do, so the stored look keeps whatever it had.
        if let family = GloriousSync.family(forKeyboardMode: settings.mode,
                                            rainbow: settings.rainbow) {
            settings.deskLook.family = family
        }
    }

    @objc private func toggleRainbow(_ sender: NSMenuItem) {
        settings.rainbow.toggle()
        rememberKeyboardLook()
        settings.save()
        refreshEnablement()
        controller.setRainbow(settings.rainbow)
        syncToMouse()
    }

    /// Opens the shared colour panel pointed at one device or the other.
    ///
    /// There is only one `NSColorPanel` in the system, so the two devices take
    /// turns: whichever asked last owns it, and ``colorPanelTarget`` is what
    /// routes the continuous updates. Retargeting mid-drag would otherwise send
    /// a mouse colour to the keyboard.
    private func presentColorPanel(for target: ColorPanelTarget) {
        let panel = NSColorPanel.shared
        panel.isContinuous = true
        switch target {
        case .keyboard:
            panel.color = nsColor(settings.color)
        case .mouse:
            panel.color = mouseSection.currentColor
                .map { NSColor(srgbRed: CGFloat($0.red) / 255,
                               green: CGFloat($0.green) / 255,
                               blue: CGFloat($0.blue) / 255,
                               alpha: 1) }
                ?? nsColor(settings.color)
        }
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        colorPanelTarget = target
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Detaches (and hides) the shared colour panel if we are the one driving it.
    private func dismissColorPanel() {
        guard colorPanelTarget != nil, NSColorPanel.sharedColorPanelExists else {
            colorPanelTarget = nil
            return
        }
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        if panel.isVisible { panel.orderOut(nil) }
        colorPanelTarget = nil
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        switch colorPanelTarget {
        case .keyboard: keyboardColorPanelChanged(sender)
        case .mouse:    mouseColorPanelChanged(sender)
        case nil:       break
        }
    }

    private func keyboardColorPanelChanged(_ sender: NSColorPanel) {
        // The row can be disabled while the panel is still on screen.
        guard settings.compensated || settings.mode.usesSolidColor else { return }
        guard let rgb = self.rgb(from: sender.color) else { return }
        let profile = settings.compensationProfile
        settings.color = rgb
        if !profile.isActive {
            // The rainbow flag is cleared by the same transaction the colour
            // rides in, so reflect that in the persisted UI state too.
            settings.rainbow = false
        }
        settings.save()
        colorRow.setColor(nsColor(rgb), hexText: "#" + rgb.hexString)
        refreshEnablement()
        // One call either way: an active profile turns this into a per-key
        // paint, a neutral one into the global colour write.
        controller.setColor(rgb, compensation: profile)
        rememberKeyboardLook()
        syncToMouse()
    }

    /// A mouse colour change is a read-modify-write of the whole 520-byte blob
    /// plus a read-back, so a continuous drag is debounced rather than
    /// throttled: the mouse only needs the colour the user settles on, and the
    /// intermediate ones would each cost two feature transfers.
    private func mouseColorPanelChanged(_ sender: NSColorPanel) {
        guard let effect = mouseSection.colorEditableEffect else { return }
        guard let rgb = self.rgb(from: sender.color) else { return }
        let color = MouseRGB(red: rgb.red, green: rgb.green, blue: rgb.blue)
        pendingMouseColor?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingMouseColor = nil
            guard color != self.mouseSection.currentColor else { return }
            self.mouseController.setColor(color, for: effect)
        }
        pendingMouseColor = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.mouseColorDebounce, execute: item)
    }

    // MARK: - Colour conversion

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255,
                green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255,
                alpha: 1)
    }

    private func rgb(from color: NSColor) -> RGB? {
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        let scale = { (value: CGFloat) in UInt8(max(0, min(255, (value * 255).rounded()))) }
        return RGB(red: scale(converted.redComponent),
                   green: scale(converted.greenComponent),
                   blue: scale(converted.blueComponent))
    }
}
