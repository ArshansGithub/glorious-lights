import Foundation
import GMMKProtocol
import GloriousMouseProtocol
import GloriousSync

/// Applies a ``DeskLook`` to whichever devices are present.
///
/// ``GloriousSync`` decides *what* each device should be set to; this decides
/// *how* it gets there — which transaction, in which order, and what happens
/// when one device refuses.
///
/// ## Order and isolation
///
/// The keyboard goes first, then the mouse, one after the other. Both transports
/// are synchronous and live on the main thread, so "serial" needs no machinery;
/// it just means not interleaving them. A failure on either device is recorded
/// by that device's controller and **does not stop the other** — a mouse that
/// has been unplugged mid-theme should not leave the keyboard on the old look.
///
/// ## Compensation
///
/// A static look on a keyboard with a tuned compensation profile goes out as a
/// per-key paint, exactly as a manual colour change would. Animated looks cannot:
/// per-key colour RAM is only displayed in mode `custom`, which is not running
/// an animation, so those go out as an ordinary onboard effect and the
/// compensation simply does not apply to them.
struct SyncCoordinator {

    let keyboard: KeyboardController
    let mouse: MouseController
    /// The user's current compensation profile, read at apply time rather than
    /// captured, so a look applied after a tuning session uses the new one.
    let compensationProfile: () -> SwitchCompensation.Profile

    /// Applies a look to both devices, keyboard first. Each device is skipped
    /// if it is not connected.
    func apply(_ look: DeskLook) {
        applyToKeyboard(look)
        applyToMouse(look)
    }

    /// The keyboard half. No-op when the keyboard is absent.
    func applyToKeyboard(_ look: DeskLook) {
        guard keyboard.isConnected else { return }
        let plan = GloriousSync.keyboardPlan(for: look)
        let profile = compensationProfile()

        // A static look is the only one per-key colours can express: LED RAM is
        // displayed in mode `custom`, and an animation overwrites it.
        if plan.mode == .fixed, !plan.rainbow, profile.isActive {
            keyboard.setBrightness(level: plan.brightnessLevel)
            keyboard.paintCompensated(target: plan.color, profile: profile, throttleKey: nil)
            return
        }
        keyboard.applyLook(mode: plan.mode,
                           rainbow: plan.rainbow,
                           brightness: plan.brightnessLevel,
                           delay: plan.delay,
                           color: plan.color)
    }

    /// The mouse half. No-op when the mouse is absent or its blob has not been
    /// read — ``MouseController`` refuses a write it cannot base on a real blob.
    func applyToMouse(_ look: DeskLook) {
        guard mouse.isConnected else { return }
        mouse.apply(GloriousSync.mousePlan(for: look))
    }

    // MARK: - Reading a look back off a device

    /// The look the mouse is currently showing, or `nil` if its effect is one no
    /// desk look can describe.
    ///
    /// Used when syncing *from* the mouse: rather than guessing what the user
    /// meant, this reads what the device actually ended up with after the write
    /// landed, so the keyboard follows the mouse's real state.
    func deskLook(fromMouse config: MouseConfigBlob) -> DeskLook? {
        guard let effect = config.effect,
              let family = GloriousSync.family(forMouseEffect: effect) else { return nil }
        let parameter = config.modeParameter(for: effect)
        // An effect with no colour array keeps whatever colour the look already
        // had; the caller merges this into the stored look.
        let color = config.colors(for: effect)?.first.map(DeskColor.init)
        return DeskLook(family: family,
                        color: color ?? DeskColor(red: 0, green: 0, blue: 0),
                        brightness: parameter.map {
                            GloriousSync.brightness01(fromMouseBrightness: $0.brightness)
                        } ?? 1,
                        speed: parameter.map {
                            GloriousSync.speed01(fromMouseSpeed: $0.speed)
                        } ?? 0.5)
    }
}
