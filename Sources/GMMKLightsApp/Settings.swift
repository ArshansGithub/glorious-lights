import Foundation
import GMMKProtocol
import GloriousSync

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
        static let markedLEDIndices = "compensation.markedLEDIndices"
        static let markedSwitches = "compensation.markedSwitches"
        static let compensationStrength = "compensation.strength"
        static let compensationBalance = "compensation.balance"
        static let syncDevices = "sync.enabled"
        static let lookFamily = "sync.look.family"
        static let lookColorHex = "sync.look.colorHex"
        static let lookBrightness = "sync.look.brightness"
        static let lookSpeed = "sync.look.speed"
        /// What ``markedLEDIndices`` was called when the marked set could only
        /// mean "the Lynx-switch keys". Read once, for migration.
        static let legacyLynxLEDIndices = "compensation.lynxLEDIndices"
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
    /// LED indices (``GMMKKeyMap``) the user marked as having the odd-one-out
    /// switch housing. Survives across launches — marking keys one press at a
    /// time is not something to ask twice.
    var markedLEDIndices: Set<UInt16> = []
    /// Which kind of switch those marks identify, which is what decides whether
    /// the correction lands on them or on everything else.
    var markedSwitches: SwitchCompensation.MarkedSwitches = .trueColor
    /// How hard to correct the tinted keys, `0`…`1`.
    var compensationStrength: Double = SwitchCompensation.defaultStrength
    /// Intensity balance between the two sets, `-1`…`1`. Positive dims the
    /// unmarked set, negative the marked one.
    var compensationBalance: Double = SwitchCompensation.defaultBalance

    /// Whether a change made in one device's section is also applied,
    /// translated, to the other.
    var syncDevices: Bool = false
    /// The last look applied to the desk, and the canonical value both devices
    /// are translated from — see ``GloriousSync``.
    var deskLook = DeskLook(family: .solid,
                            color: DeskColor(hex: "66ffaa") ?? DeskColor(red: 0x66,
                                                                         green: 0xFF,
                                                                         blue: 0xAA),
                            brightness: 1.0,
                            speed: 0.5)

    /// The four compensation fields as the protocol layer wants them.
    var compensationProfile: SwitchCompensation.Profile {
        SwitchCompensation.Profile(markedLEDIndices: markedLEDIndices,
                                   markedSwitches: markedSwitches,
                                   strength: compensationStrength,
                                   balance: compensationBalance)
    }

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
        // The marked set moved key when the strength became signed and the set
        // stopped meaning specifically "the Lynx keys". The values themselves
        // did not change, so the old key is read as a fallback.
        if let stored = (defaults.array(forKey: Key.markedLEDIndices)
                         ?? defaults.array(forKey: Key.legacyLynxLEDIndices)) as? [Int] {
            // Anything outside the addressable range is dropped rather than
            // trusted: a stale or hand-edited default must not send the
            // firmware an index it has never been asked about.
            markedLEDIndices = Set(stored.compactMap { value -> UInt16? in
                guard let index = UInt16(exactly: value),
                      GMMKKeyMap.paintableLEDIndices.contains(index) else { return nil }
                return index
            })
        }
        if let raw = defaults.string(forKey: Key.markedSwitches),
           let stored = SwitchCompensation.MarkedSwitches(rawValue: raw) {
            markedSwitches = stored
        }
        if let stored = defaults.object(forKey: Key.compensationStrength) as? Double {
            // A strength written while the slider was briefly bidirectional
            // could be negative. Magnitude is what it always meant; the
            // direction is now ``markedSwitches``' job.
            compensationStrength = min(max(abs(stored), SwitchCompensation.strengthRange.lowerBound),
                                       SwitchCompensation.strengthRange.upperBound)
        }
        // Absent before the balance slider existed, which is the same as
        // neutral — so no migration beyond the default is needed.
        if let stored = defaults.object(forKey: Key.compensationBalance) as? Double {
            compensationBalance = min(max(stored, SwitchCompensation.balanceRange.lowerBound),
                                      SwitchCompensation.balanceRange.upperBound)
        }
        if let stored = defaults.object(forKey: Key.syncDevices) as? Bool {
            syncDevices = stored
        }
        // Each field falls back to the default independently: a look stored by
        // an older build, or hand-edited, should lose only the part that is
        // unreadable rather than the whole look.
        if let raw = defaults.string(forKey: Key.lookFamily),
           let family = DeskEffectFamily(rawValue: raw) {
            deskLook.family = family
        }
        if let hex = defaults.string(forKey: Key.lookColorHex), let color = DeskColor(hex: hex) {
            deskLook.color = color
        }
        if let stored = defaults.object(forKey: Key.lookBrightness) as? Double {
            deskLook.brightness = min(max(stored, 0), 1)
        }
        if let stored = defaults.object(forKey: Key.lookSpeed) as? Double {
            deskLook.speed = min(max(stored, 0), 1)
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
        defaults.set(markedLEDIndices.sorted().map(Int.init), forKey: Key.markedLEDIndices)
        defaults.set(markedSwitches.rawValue, forKey: Key.markedSwitches)
        defaults.set(compensationStrength, forKey: Key.compensationStrength)
        defaults.set(compensationBalance, forKey: Key.compensationBalance)
        defaults.set(syncDevices, forKey: Key.syncDevices)
        defaults.set(deskLook.family.rawValue, forKey: Key.lookFamily)
        defaults.set(deskLook.color.hexString, forKey: Key.lookColorHex)
        defaults.set(deskLook.brightness, forKey: Key.lookBrightness)
        defaults.set(deskLook.speed, forKey: Key.lookSpeed)
    }
}
