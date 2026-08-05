import AppKit
import GMMKProtocol

/// Status-item menu: effect picker, brightness, speed, colour, connection state.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let controller = KeyboardController()
    private var settings = Settings()

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private let connectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let effectItem = NSMenuItem(title: "Effect", action: nil, keyEquivalent: "")
    private let effectMenu = NSMenu()
    private let rainbowItem = NSMenuItem(title: "Rainbow", action: nil, keyEquivalent: "")
    private let compensatedItem = NSMenuItem(title: "Uniform Color (Compensated)",
                                             action: nil, keyEquivalent: "")
    /// True while the shared `NSColorPanel` is targeted at this delegate.
    private var ownsColorPanel = false
    /// Kept across openings so the tuner reopens with its state intact.
    private lazy var tuner = SwitchCompensationWindowController(controller: controller)

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
                                           accessibilityDescription: "GMMK Lights")
        statusItem.button?.image?.isTemplate = true
        statusItem.menu = menu

        buildMenu()
        applySettingsToUI()

        controller.onStatusChange = { [weak self] in self?.refreshConnectionItem() }
        // Monitoring only. Deliberately no initial send: the keyboard keeps its
        // own settings in flash, and pushing our restored UI state at login
        // would clobber whatever the user last set by other means.
        controller.start()
        refreshConnectionItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
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
        menu.addItem(.separator())

        brightnessRow.onChange = { [weak self] percent in
            guard let self else { return }
            self.settings.brightnessPercent = percent
            self.settings.save()
            self.controller.setBrightness(percent: percent)
        }
        menu.addItem(row(brightnessRow))

        speedRow.onChange = { [weak self] speed in
            guard let self else { return }
            self.settings.speed = speed
            self.settings.save()
            self.controller.setSpeed(speed)
        }
        menu.addItem(row(speedRow))

        colorRow.onClick = { [weak self] in self?.presentColorPanel() }
        menu.addItem(row(colorRow))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit GMMK Lights",
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

    // MARK: - State → UI

    private func applySettingsToUI() {
        brightnessRow.setValue(settings.brightnessPercent)
        speedRow.setValue(settings.speed)
        colorRow.setColor(nsColor(settings.color), hexText: "#" + settings.color.hexString)
        refreshEnablement()
    }

    private func refreshEnablement() {
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

        speedRow.isControlEnabled = settings.mode.isAnimated
        // A colour write only shows up when the mode uses the solid colour and
        // the rainbow flag is off — clicking through to the panel otherwise
        // would look like the app was broken. The compensated paint is the
        // exception: it is in mode `custom`, which ignores the config colour,
        // but the same swatch is its target.
        let colorEnabled = settings.compensated
            || (settings.mode.usesSolidColor && !settings.rainbow)
        colorRow.setEnabled(colorEnabled)
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
    }

    // MARK: - Actions

    @objc private func selectEffect(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? LightingMode else { return }
        settings.mode = mode
        settings.compensated = false
        settings.save()
        refreshEnablement()
        controller.setMode(mode)
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
        settings.save()
        refreshEnablement()
        paintCompensated()
    }

    @objc private func openTuner(_ sender: NSMenuItem) {
        tuner.onChange = { [weak self] tuning in
            guard let self else { return }
            self.settings.markedLEDIndices = tuning.markedLEDIndices
            self.settings.markedSwitches = tuning.markedSwitches
            self.settings.compensationStrength = tuning.strength
            self.settings.save()
        }
        // Opening the tuner paints, which leaves the board in mode `custom`
        // showing the compensated colours — so record that as the current state
        // rather than letting the menu keep claiming the old effect.
        settings.mode = .custom
        settings.compensated = true
        settings.save()
        refreshEnablement()
        tuner.present(target: settings.color,
                      tuning: .init(markedLEDIndices: settings.markedLEDIndices,
                                    markedSwitches: settings.markedSwitches,
                                    strength: settings.compensationStrength))
    }

    private func paintCompensated() {
        controller.paintCompensated(target: settings.color,
                                    markedLEDIndices: settings.markedLEDIndices,
                                    markedSwitches: settings.markedSwitches,
                                    strength: settings.compensationStrength)
    }

    @objc private func toggleRainbow(_ sender: NSMenuItem) {
        settings.rainbow.toggle()
        settings.save()
        refreshEnablement()
        controller.setRainbow(settings.rainbow)
    }

    private func presentColorPanel() {
        let panel = NSColorPanel.shared
        panel.isContinuous = true
        panel.color = nsColor(settings.color)
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        ownsColorPanel = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Detaches (and hides) the shared colour panel if we are the one driving it.
    private func dismissColorPanel() {
        guard ownsColorPanel, NSColorPanel.sharedColorPanelExists else {
            ownsColorPanel = false
            return
        }
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        if panel.isVisible { panel.orderOut(nil) }
        ownsColorPanel = false
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        // The row can be disabled while the panel is still on screen.
        guard settings.compensated || settings.mode.usesSolidColor else { return }
        guard let rgb = self.rgb(from: sender.color) else { return }
        settings.color = rgb
        if !settings.compensated {
            // The rainbow flag is cleared by the same transaction the colour
            // rides in, so reflect that in the persisted UI state too.
            settings.rainbow = false
        }
        settings.save()
        colorRow.setColor(nsColor(rgb), hexText: "#" + rgb.hexString)
        refreshEnablement()
        if settings.compensated {
            paintCompensated()
        } else {
            controller.setColor(rgb)
        }
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
