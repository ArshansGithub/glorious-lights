import AppKit
import GloriousMouseProtocol

/// The mouse half of the status-item menu.
///
/// Kept out of ``AppDelegate`` because the two devices share nothing: different
/// USB IDs, different transport, different protocol, and — unlike the keyboard,
/// whose settings the app mirrors in `UserDefaults` — the mouse's entire state
/// is read back from the device itself before every draw. Everything shown here
/// comes from the cached blob in ``MouseController``.
///
/// All of these items hide themselves when no mouse is attached, so the menu
/// shows whichever devices are actually present.
final class MouseMenuSection: NSObject {

    /// DPI values offered in the menu. The sensor accepts any multiple of 100
    /// from 100 to 12000 (doc §6) — far too many for a menu — so these are the
    /// common stops, and `gmmk-cli mouse dpi` covers the rest.
    static let offeredDPIValues = [400, 800, 1200, 1600, 2000, 2400, 3200, 6400, 12000]

    private let controller: MouseController
    /// Asks the delegate to open the shared colour panel targeted at the mouse.
    private let presentColorPanel: () -> Void

    // MARK: - Items

    private let separator = NSMenuItem.separator()
    private let headerItem = NSMenuItem(title: "Mouse", action: nil, keyEquivalent: "")
    private let effectItem = NSMenuItem(title: "Effect", action: nil, keyEquivalent: "")
    private let effectMenu = NSMenu()
    private let colorItem = NSMenuItem(title: "Color…", action: nil, keyEquivalent: "")
    private let brightnessItem = NSMenuItem(title: "Brightness", action: nil, keyEquivalent: "")
    private let brightnessMenu = NSMenu()
    private let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
    private let speedMenu = NSMenu()
    private let dpiItem = NSMenuItem(title: "DPI Stages", action: nil, keyEquivalent: "")
    private let dpiMenu = NSMenu()
    private let dpiEnabledMenu = NSMenu()
    private let dpiValueMenu = NSMenu()
    private let pollingItem = NSMenuItem(title: "Polling Rate", action: nil, keyEquivalent: "")
    private let pollingMenu = NSMenu()
    private let debounceItem = NSMenuItem(title: "Debounce", action: nil, keyEquivalent: "")
    private let debounceMenu = NSMenu()

    private var allItems: [NSMenuItem] {
        [separator, headerItem, effectItem, colorItem, brightnessItem,
         speedItem, dpiItem, pollingItem, debounceItem]
    }

    init(controller: MouseController, presentColorPanel: @escaping () -> Void) {
        self.controller = controller
        self.presentColorPanel = presentColorPanel
        super.init()
        buildSubmenus()
    }

    /// Appends the section to `menu`, in order.
    func install(in menu: NSMenu) {
        allItems.forEach(menu.addItem)
    }

    // MARK: - Construction

    private func buildSubmenus() {
        headerItem.isEnabled = false

        for effect in MouseRGBEffect.allCases {
            effectMenu.addItem(item(effect.displayName,
                                    #selector(selectEffect(_:)),
                                    represented: effect))
        }
        effectItem.submenu = effectMenu

        colorItem.action = #selector(openColorPanel)
        colorItem.target = self

        // Brightness 0 is off and 1–4 are low → high (doc §5.3). Zero is offered
        // because it is the documented way to darken a mouse whose effect you
        // want to keep.
        brightnessMenu.addItem(item("Off", #selector(selectBrightness(_:)), represented: 0))
        for level in 1...Int(MouseModeParameter.maxBrightness) {
            brightnessMenu.addItem(item("\(level) / \(MouseModeParameter.maxBrightness)",
                                        #selector(selectBrightness(_:)),
                                        represented: level))
        }
        brightnessItem.submenu = brightnessMenu

        for speed in 0...Int(MouseModeParameter.maxSpeed) {
            let name = MouseModeParameter(speed: UInt8(speed), brightness: 0).speedName
            speedMenu.addItem(item(name.capitalized, #selector(selectSpeed(_:)), represented: speed))
        }
        speedItem.submenu = speedMenu

        for slot in 0..<GloriousMouseDevice.dpiSlotCount {
            dpiMenu.addItem(item("", #selector(selectActiveDPISlot(_:)), represented: slot))
            dpiEnabledMenu.addItem(item("", #selector(toggleDPISlot(_:)), represented: slot))

            let valuesForSlot = NSMenu()
            for dpi in Self.offeredDPIValues {
                let entry = item("\(dpi)", #selector(selectDPIValue(_:)),
                                 represented: DPIValueChoice(slot: slot, dpi: dpi))
                valuesForSlot.addItem(entry)
            }
            let slotItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            slotItem.submenu = valuesForSlot
            dpiValueMenu.addItem(slotItem)
        }
        dpiMenu.addItem(.separator())
        let enabledItem = NSMenuItem(title: "Enabled Stages", action: nil, keyEquivalent: "")
        enabledItem.submenu = dpiEnabledMenu
        dpiMenu.addItem(enabledItem)
        let valuesItem = NSMenuItem(title: "Set Stage DPI", action: nil, keyEquivalent: "")
        valuesItem.submenu = dpiValueMenu
        dpiMenu.addItem(valuesItem)
        dpiItem.submenu = dpiMenu

        for rate in MousePollingRate.allCases {
            pollingMenu.addItem(item("\(rate.hertz) Hz",
                                     #selector(selectPollingRate(_:)),
                                     represented: rate))
        }
        pollingItem.submenu = pollingMenu

        for ms in MouseCommandReport.debounceTimesMilliseconds {
            debounceMenu.addItem(item("\(ms) ms", #selector(selectDebounce(_:)), represented: ms))
        }
        debounceItem.submenu = debounceMenu
    }

    private func item(_ title: String, _ action: Selector, represented: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
    }

    /// One entry of the per-slot DPI value menus.
    private struct DPIValueChoice {
        let slot: Int
        let dpi: Int
    }

    // MARK: - Refresh

    /// Redraws every item from the cached blob. Called whenever the menu is
    /// about to open and whenever the controller's state changes.
    func refresh() {
        guard controller.isConnected else {
            allItems.forEach { $0.isHidden = true }
            return
        }
        allItems.forEach { $0.isHidden = false }
        headerItem.title = headerTitle
        headerItem.toolTip = controller.lastError

        guard let config = controller.config else {
            // Connected but unreadable: say so in the header and offer nothing
            // that would write a blob nobody has seen.
            [effectItem, colorItem, brightnessItem, speedItem,
             dpiItem, pollingItem].forEach { $0.isEnabled = false }
            refreshDebounce()
            return
        }
        [effectItem, brightnessItem, speedItem, dpiItem, pollingItem]
            .forEach { $0.isEnabled = true }

        let effect = config.effect
        for entry in effectMenu.items {
            entry.state = (entry.representedObject as? MouseRGBEffect) == effect ? .on : .off
        }
        effectItem.title = "Effect: " + (effect?.displayName ?? "unknown")

        // A colour is only meaningful for the effects that carry one, and only
        // the first of a multi-colour array is editable here.
        let colorArray = effect?.colorArray
        colorItem.isEnabled = colorArray != nil
        if let effect, let colors = config.colors(for: effect), let first = colors.first {
            colorItem.title = "Color: #" + first.hexString
        } else {
            colorItem.title = "Color (not used by this effect)"
        }

        let parameter = effect.flatMap { config.modeParameter(for: $0) }
        brightnessItem.isEnabled = parameter != nil
        speedItem.isEnabled = parameter != nil
        brightnessItem.title = parameter.map { "Brightness: \($0.brightness == 0 ? "off" : "\($0.brightness)")" }
            ?? "Brightness"
        speedItem.title = parameter.map { "Speed: \($0.speedName)" } ?? "Speed"
        for entry in brightnessMenu.items {
            entry.state = (entry.representedObject as? Int) == parameter.map { Int($0.brightness) }
                ? .on : .off
        }
        for entry in speedMenu.items {
            entry.state = (entry.representedObject as? Int) == parameter.map { Int($0.speed) }
                ? .on : .off
        }

        refreshDPI(config)

        pollingItem.title = "Polling Rate: "
            + (config.pollingRate.map { "\($0.hertz) Hz" } ?? "unknown")
        for entry in pollingMenu.items {
            entry.state = (entry.representedObject as? MousePollingRate) == config.pollingRate
                ? .on : .off
        }

        refreshDebounce()
    }

    private var headerTitle: String {
        var title = "Mouse"
        if let version = controller.firmwareVersion { title += " — firmware \(version)" }
        if controller.config == nil {
            title += controller.lastError == nil
                ? " (not readable)"
                : " (not readable — see tooltip)"
        }
        return title
    }

    private func refreshDPI(_ config: MouseConfigBlob) {
        let stages = config.dpiStages
        let activeSlot = config.activeDPISlot
        dpiItem.title = activeSlot.map { "DPI: \(stages[$0].displayValue)" } ?? "DPI Stages"

        for (index, entry) in dpiMenu.items.enumerated() {
            guard let slot = entry.representedObject as? Int else { continue }
            let stage = stages[slot]
            let active = slot == activeSlot ? "  ✓ active" : ""
            entry.title = "Stage \(slot + 1): \(stage.displayValue) dpi\(active)"
            // The checkmark means *enabled*; the active stage is named in the
            // title, because one item cannot carry two independent states.
            entry.state = stage.isEnabled ? .on : .off
            // Selecting a disabled stage would point the active ordinal at a
            // stage the mouse has switched off.
            entry.isEnabled = stage.isEnabled
            _ = index
        }
        for entry in dpiEnabledMenu.items {
            guard let slot = entry.representedObject as? Int else { continue }
            entry.title = "Stage \(slot + 1): \(stages[slot].displayValue) dpi"
            entry.state = stages[slot].isEnabled ? .on : .off
        }
        for (slot, entry) in dpiValueMenu.items.enumerated() {
            entry.title = "Stage \(slot + 1): \(stages[slot].displayValue) dpi"
            for value in entry.submenu?.items ?? [] {
                guard let choice = value.representedObject as? DPIValueChoice else { continue }
                value.state = choice.dpi == stages[slot].x ? .on : .off
            }
        }
    }

    private func refreshDebounce() {
        if let ms = controller.debounceMilliseconds {
            debounceItem.title = "Debounce: \(ms) ms"
            debounceItem.isEnabled = true
        } else {
            // Command 0x1a not answering is an answer, not a failure (doc §11
            // item 4) — but there is nothing to set, so the control goes away.
            debounceItem.title = "Debounce (unsupported on this unit)"
            debounceItem.isEnabled = false
        }
        for entry in debounceMenu.items {
            entry.state = (entry.representedObject as? Int) == controller.debounceMilliseconds
                ? .on : .off
        }
    }

    // MARK: - Actions

    @objc private func selectEffect(_ sender: NSMenuItem) {
        guard let effect = sender.representedObject as? MouseRGBEffect else { return }
        controller.setEffect(effect)
    }

    @objc private func openColorPanel() {
        presentColorPanel()
    }

    @objc private func selectBrightness(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? Int else { return }
        controller.setModeParameter(brightness: UInt8(level))
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? Int else { return }
        controller.setModeParameter(speed: UInt8(speed))
    }

    /// The blob stores the active stage as a **1-based ordinal over the enabled
    /// slots only** (doc §6), so a physical slot has to be converted rather than
    /// incremented: with stage 2 disabled, stage 5 is ordinal 4.
    @objc private func selectActiveDPISlot(_ sender: NSMenuItem) {
        guard let slot = sender.representedObject as? Int,
              let config = controller.config else { return }
        var ordinal = 0
        for candidate in 0..<config.dpiSlotCount where config.isDPISlotEnabled(candidate) {
            ordinal += 1
            if candidate == slot {
                controller.setActiveDPIOrdinal(ordinal)
                return
            }
        }
    }

    @objc private func toggleDPISlot(_ sender: NSMenuItem) {
        guard let slot = sender.representedObject as? Int,
              let config = controller.config else { return }
        controller.setDPISlotEnabled(!config.isDPISlotEnabled(slot), at: slot)
    }

    @objc private func selectDPIValue(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? DPIValueChoice else { return }
        controller.setDPI(choice.dpi, at: choice.slot)
    }

    @objc private func selectPollingRate(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? MousePollingRate else { return }
        controller.setPollingRate(rate)
    }

    @objc private func selectDebounce(_ sender: NSMenuItem) {
        guard let ms = sender.representedObject as? Int else { return }
        controller.setDebounce(milliseconds: ms)
    }

    // MARK: - Colour panel support

    /// The effect whose colour array the colour panel edits, if any.
    var colorEditableEffect: MouseRGBEffect? {
        guard let effect = controller.config?.effect, effect.colorArray != nil else { return nil }
        return effect
    }

    /// The colour currently shown for that effect.
    var currentColor: MouseRGB? {
        guard let effect = colorEditableEffect else { return nil }
        return controller.config?.colors(for: effect)?.first
    }
}
