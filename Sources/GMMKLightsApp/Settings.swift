import Foundation
import GMMKProtocol

/// Last-used UI state, persisted in `UserDefaults`.
///
/// The keyboard stores its own lighting settings in flash, so this exists only
/// so the menu comes back up showing what the user last chose. Nothing here is
/// pushed to the device on launch — see ``AppDelegate`` — because the keyboard
/// may have been changed by the CLI, another machine, or its own onboard
/// shortcuts in the meantime, and silently overwriting that on login would be
/// surprising.
struct Settings {

    private enum Key {
        static let mode = "lighting.mode"
        static let brightnessPercent = "lighting.brightnessPercent"
        static let speed = "lighting.speed"
        static let colorHex = "lighting.colorHex"
        static let rainbow = "lighting.rainbow"
        static let compensated = "compensation.enabled"
        static let lynxLEDIndices = "compensation.lynxLEDIndices"
        static let compensationStrength = "compensation.strength"
    }

    var mode: LightingMode = .fixed
    /// 0–100, mapped onto the device's 0–4 scale when sent.
    var brightnessPercent: Int = 100
    /// 1 (slowest) – 5 (fastest), mapped onto the device's delay 3–0 when sent.
    var speed: Int = 3
    /// Doubles as the target colour of the compensated uniform paint.
    var color: RGB = RGB(red: 0xFF, green: 0x88, blue: 0x00)
    var rainbow: Bool = false

    /// Whether the last thing the user chose was the compensated uniform paint
    /// rather than an onboard effect. Both end up in mode ``LightingMode/custom``
    /// on the device, so the flag is what tells them apart in the UI.
    var compensated: Bool = false
    /// LED indices (``GMMKKeyMap``) the user marked as sitting under a Lynx
    /// switch. Survives across launches — re-marking 87 keys is not something to
    /// ask twice.
    var lynxLEDIndices: Set<UInt16> = []
    /// How hard to compensate those keys, `0`…`1`.
    var compensationStrength: Double = SwitchCompensation.defaultStrength

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.object(forKey: Key.mode) as? Int,
           let stored = LightingMode(rawValue: UInt8(clamping: raw)) {
            mode = stored
        }
        if let percent = defaults.object(forKey: Key.brightnessPercent) as? Int {
            brightnessPercent = max(0, min(100, percent))
        }
        if let stored = defaults.object(forKey: Key.speed) as? Int {
            speed = max(1, min(5, stored))
        }
        if let hex = defaults.string(forKey: Key.colorHex), let stored = RGB(hex: hex) {
            color = stored
        }
        if let stored = defaults.object(forKey: Key.rainbow) as? Bool {
            rainbow = stored
        }
        if let stored = defaults.object(forKey: Key.compensated) as? Bool {
            compensated = stored
        }
        if let stored = defaults.array(forKey: Key.lynxLEDIndices) as? [Int] {
            // Anything outside the addressable range is dropped rather than
            // trusted: a stale or hand-edited default must not send the
            // firmware an index it has never been asked about.
            lynxLEDIndices = Set(stored.compactMap { value -> UInt16? in
                guard let index = UInt16(exactly: value),
                      GMMKKeyMap.paintableLEDIndices.contains(index) else { return nil }
                return index
            })
        }
        if let stored = defaults.object(forKey: Key.compensationStrength) as? Double {
            compensationStrength = min(max(stored, SwitchCompensation.strengthRange.lowerBound),
                                       SwitchCompensation.strengthRange.upperBound)
        }
    }

    /// Writes the whole struct back. Cheap enough to call on every change.
    func save() {
        defaults.set(Int(mode.rawValue), forKey: Key.mode)
        defaults.set(brightnessPercent, forKey: Key.brightnessPercent)
        defaults.set(speed, forKey: Key.speed)
        defaults.set(color.hexString, forKey: Key.colorHex)
        defaults.set(rainbow, forKey: Key.rainbow)
        defaults.set(compensated, forKey: Key.compensated)
        defaults.set(lynxLEDIndices.sorted().map(Int.init), forKey: Key.lynxLEDIndices)
        defaults.set(compensationStrength, forKey: Key.compensationStrength)
    }
}
