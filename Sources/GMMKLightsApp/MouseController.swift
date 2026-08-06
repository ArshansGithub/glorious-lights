import Foundation
import GloriousMouseHID
import GloriousMouseProtocol
import GloriousSync

/// Owns the mouse transport and turns menu actions into blob writes.
///
/// Main-thread only, like ``KeyboardController``. The mouse protocol is entirely
/// synchronous `GetFeature`/`SetFeature` with no interrupt channel and no reply
/// pacing (`docs/mouse-protocol.md` §1.2), so a whole read-modify-write is two
/// transfers and doing them inline keeps ordering trivially correct.
///
/// ## Why there is a cached blob
///
/// Every setting except debounce lives in one 520-byte blob, and there is no way
/// to poke a single field: a write is always the whole thing (doc §4). So the
/// menu needs the current blob both to *show* what the mouse is set to and to
/// have something to modify. It is read on connect and after every write, and
/// the menu is built from it.
final class MouseController {

    private let mouse = GloriousMouse()

    /// The last blob read from profile 1, or `nil` before the first read.
    /// Everything the menu displays comes from here.
    private(set) var config: MouseConfigBlob?
    /// Firmware version string, e.g. `V103`.
    private(set) var firmwareVersion: String?
    /// Debounce in milliseconds, or `nil` when command `0x1a` does not answer —
    /// which doc §11 item 4 flags as genuinely open on this device.
    private(set) var debounceMilliseconds: Int?
    private(set) var lastError: String?

    /// Fires whenever the cached state changes, so the menu can redraw.
    var onStatusChange: (() -> Void)?

    var isConnected: Bool { mouse.isConnected }

    /// The profile the app reads and writes. Glorious's own software hides all
    /// but the first (doc §8), and nothing in this app switches profiles.
    static let profile: MouseProfile = .one

    init() {
        mouse.onConnect = { [weak self] in
            guard let self else { return }
            self.lastError = nil
            // A mouse that just appeared has settings the menu knows nothing
            // about; read them before anything is drawn.
            self.refresh()
        }
        mouse.onDisconnect = { [weak self] in
            guard let self else { return }
            self.config = nil
            self.firmwareVersion = nil
            self.debounceMilliseconds = nil
            self.lastError = nil
            self.onStatusChange?()
        }
        mouse.onOpenFailure = { [weak self] error in
            self?.lastError = error.description
            self?.onStatusChange?()
        }
    }

    /// Starts hot-plug monitoring. Reads if a mouse is already attached; never
    /// writes.
    func start() {
        mouse.start(on: .main, mode: .commonModes)
        if mouse.isConnected { refresh() } else { onStatusChange?() }
    }

    func stop() {
        mouse.close()
    }

    // MARK: - Reading

    /// Re-reads everything the menu shows. Cheap: three feature transfers.
    func refresh() {
        guard mouse.isConnected else {
            onStatusChange?()
            return
        }
        firmwareVersion = try? mouse.firmwareVersion() ?? nil
        // A `nil` debounce is an answer — "command 0x1a is unsupported here" —
        // not a failure, and `try?` flattens both into the same nil.
        debounceMilliseconds = try? mouse.debounceMilliseconds() ?? nil
        do {
            config = try mouse.readConfig(profile: Self.profile)
            lastError = nil
        } catch {
            config = nil
            lastError = String(describing: error)
        }
        onStatusChange?()
    }

    // MARK: - Writing

    /// Why a write could not be attempted, in words a menu can show.
    enum WriteRefusal: CustomStringConvertible {
        case notConnected
        case noConfig
        case sizeNotObserved

        var description: String {
            switch self {
            case .notConnected:
                return "The mouse is not connected."
            case .noConfig:
                return "The mouse's configuration has not been read yet."
            case .sizeNotObserved:
                return """
                    The config size could not be observed from the read, so the write marker \
                    at byte 0x03 would be a guess — and a wrong one makes the mouse ignore \
                    the write silently (docs/mouse-protocol.md §4).
                    """
            }
        }
    }

    /// The read-modify-write every mouse setting is (doc §4): take the cached
    /// blob, apply `mutate`, stamp the marker from the **observed** config size,
    /// send it, then re-read so the menu shows what the device actually has.
    ///
    /// The observed size is required rather than inferred, for the same reason
    /// the CLI requires it: byte `0x03` decides whether the write is accepted at
    /// all, and the trailing-zero inference is a lower bound that can be short.
    @discardableResult
    func modifyConfig(_ mutate: (inout MouseConfigBlob) throws -> Void) -> Bool {
        guard mouse.isConnected else { return refuse(.notConnected) }
        guard var blob = config else { return refuse(.noConfig) }
        guard let size = blob.observedConfigSize else { return refuse(.sizeNotObserved) }
        do {
            try mutate(&blob)
            try mouse.writeConfig(blob.preparedForWrite(profile: Self.profile, configSize: size))
            lastError = nil
        } catch {
            lastError = String(describing: error)
            onStatusChange?()
            return false
        }
        // Re-read rather than trusting the local copy: the blob write is the
        // commit, and the read-back is the only confirmation this protocol has.
        refresh()
        return true
    }

    private func refuse(_ refusal: WriteRefusal) -> Bool {
        lastError = refusal.description
        onStatusChange?()
        return false
    }

    // MARK: - Settings

    func setEffect(_ effect: MouseRGBEffect) {
        modifyConfig { $0.effect = effect }
    }

    /// Sets the colour of whichever effect carries a colour array, leaving the
    /// count byte and any other colours alone.
    func setColor(_ color: MouseRGB, for effect: MouseRGBEffect) {
        modifyConfig { blob in
            blob.effect = effect
            try blob.setColors([color], for: effect)
        }
    }

    /// Writes one nibble of the current effect's packed parameter byte, keeping
    /// the other as it was.
    func setModeParameter(speed: UInt8? = nil, brightness: UInt8? = nil) {
        modifyConfig { blob in
            guard let effect = blob.effect, let current = blob.modeParameter(for: effect) else {
                throw MouseFieldError.effectHasNoParameters(blob.effect ?? .off)
            }
            try blob.setModeParameter(
                MouseModeParameter(speed: speed ?? current.speed,
                                   brightness: brightness ?? current.brightness),
                for: effect)
        }
    }

    /// Applies a whole translated look: effect, its colour if it has one, its
    /// packed speed/brightness byte, and the rainbow direction where that
    /// matters — all in the single blob write the protocol requires anyway.
    func apply(_ plan: GloriousSync.MousePlan) {
        modifyConfig { blob in
            blob.effect = plan.effect
            if let color = plan.color {
                try blob.setColors([color], for: plan.effect)
            }
            if plan.effect.hasModeByte {
                try blob.setModeParameter(plan.parameter, for: plan.effect)
            }
            if let direction = plan.rainbowDirection {
                blob.rainbowDirection = direction
            }
        }
    }

    /// Paints the six LEDs individually via effect `constant` — the per-LED
    /// mode described in ``MouseLED``.
    ///
    /// Brightness is forced to full: the constant effect has its own mode byte,
    /// and a user who has just chosen six colours wants to see them rather than
    /// inherit whatever dimming the previous effect was using.
    func setPerLEDColors(_ colors: [MouseRGB]) {
        let padded = MouseLED.padded(colors)
        modifyConfig { blob in
            blob.effect = .constant
            try blob.setColors(padded, for: .constant)
            let current = blob.modeParameter(for: .constant)
            try blob.setModeParameter(
                MouseModeParameter(speed: current?.speed ?? 0,
                                   brightness: MouseModeParameter.maxBrightness),
                for: .constant)
        }
    }

    /// The six colours the mouse is currently showing, or `nil` when it is not
    /// in the per-LED mode.
    var perLEDColors: [MouseRGB]? {
        guard let config, config.effect == .constant else { return nil }
        return config.colors(for: .constant)
    }

    func setPollingRate(_ rate: MousePollingRate) {
        modifyConfig { $0.pollingRate = rate }
    }

    /// `ordinal` is 1-based over the **enabled** slots only (doc §6).
    func setActiveDPIOrdinal(_ ordinal: Int) {
        modifyConfig { try $0.setActiveDPIOrdinal(ordinal) }
    }

    func setDPISlotEnabled(_ enabled: Bool, at slot: Int) {
        modifyConfig { try $0.setDPISlotEnabled(enabled, at: slot) }
    }

    func setDPI(_ dpi: Int, at slot: Int) {
        modifyConfig { blob in
            let existing = blob.dpiStages[slot]
            try blob.setDPIStage(MouseDPIStage(dpi: dpi, isEnabled: existing.isEnabled), at: slot)
        }
    }

    /// Debounce is the one setting that is **not** in the blob: command `0x1a`
    /// writes it directly (doc §7), so there is no read-modify-write here — and
    /// no backup of it in a `mouse dump` either.
    func setDebounce(milliseconds: Int) {
        guard mouse.isConnected else { _ = refuse(.notConnected); return }
        do {
            try mouse.setDebounce(milliseconds: milliseconds)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        debounceMilliseconds = try? mouse.debounceMilliseconds() ?? nil
        onStatusChange?()
    }
}
