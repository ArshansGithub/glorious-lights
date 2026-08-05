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
    }

    var mode: LightingMode = .fixed
    /// 0–100, mapped onto the device's 0–4 scale when sent.
    var brightnessPercent: Int = 100
    /// 1 (slowest) – 5 (fastest), mapped onto the device's delay 3–0 when sent.
    var speed: Int = 3
    var color: RGB = RGB(red: 0xFF, green: 0x88, blue: 0x00)
    var rainbow: Bool = false

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
    }

    /// Writes the whole struct back. Cheap enough to call on every change.
    func save() {
        defaults.set(Int(mode.rawValue), forKey: Key.mode)
        defaults.set(brightnessPercent, forKey: Key.brightnessPercent)
        defaults.set(speed, forKey: Key.speed)
        defaults.set(color.hexString, forKey: Key.colorHex)
        defaults.set(rainbow, forKey: Key.rainbow)
    }
}
