import Foundation
import GMMKProtocol
import GloriousMouseProtocol

/// Translates a ``DeskLook`` into what each device understands, and back.
///
/// Pure: nothing here talks to hardware or builds packets. It answers "what
/// should each device be set to" and leaves the sending to the transports, which
/// is what makes the whole mapping table testable — and the mapping is where the
/// mistakes live, because the two devices disagree about almost every scale.
///
/// ## The disagreements, resolved once
///
/// | | Keyboard | Mouse |
/// |---|---|---|
/// | brightness | `0`…`4`, **0 is off** | `0`…`4`, 0 is off — but a look never sends 0 |
/// | speed | a **delay**: `0` fastest … `3` slowest | a **speed**: `1` slow … `3` fast |
/// | rainbow | a flag *on top of* a mode | an effect of its own |
/// | colour order | R,G,B on the wire | R,B,G on the wire |
///
/// The mouse's brightness floor is deliberate. Its `0` means "LEDs dark", and a
/// desk look that names an effect while leaving the mouse black reads as a
/// broken mouse rather than as a dim one, so the bottom of the range maps to `1`.
/// The keyboard keeps its `0` because the app's brightness slider already
/// exposes it as "off" and users reach for it on purpose.
public enum GloriousSync {

    // MARK: - Keyboard

    /// What the keyboard should be set to for a look.
    ///
    /// `rainbow` is a separate field rather than folded into `mode` because that
    /// is how the hardware works: the flag at config `0x04` makes whatever mode
    /// is running cycle hues (`docs/protocol.md` §2), so ``DeskEffectFamily/wave``
    /// and ``DeskEffectFamily/rainbowCycle`` are the *same* mode with the flag
    /// off and on.
    public struct KeyboardPlan: Equatable, Sendable {
        public var mode: LightingMode
        public var rainbow: Bool
        /// `0`…`4`, where 0 is off.
        public var brightnessLevel: UInt8
        /// `0`…`3`, where **higher is slower** — it is a delay, not a speed.
        public var delay: UInt8
        public var color: RGB

        public init(mode: LightingMode, rainbow: Bool, brightnessLevel: UInt8,
                    delay: UInt8, color: RGB) {
            self.mode = mode
            self.rainbow = rainbow
            self.brightnessLevel = brightnessLevel
            self.delay = delay
            self.color = color
        }
    }

    /// The keyboard mode each family runs in. Wave and rainbow cycle share one.
    public static func keyboardMode(for family: DeskEffectFamily) -> LightingMode {
        switch family {
        case .solid:        return .fixed
        case .breathing:    return .breathing
        case .wave:         return .horizontalWave
        case .rainbowCycle: return .horizontalWave
        }
    }

    /// `0…1` → the device's `0`…`4`.
    ///
    /// Routed through ``Brightness/level(fromPercent:)`` so a synced brightness
    /// and a brightness the user dragged land on the same level: any non-zero
    /// value maps to at least 1, and only an explicit 0 turns the board off.
    public static func keyboardBrightnessLevel(_ brightness01: Double) -> UInt8 {
        let clamped = min(max(brightness01, 0), 1)
        return Brightness.level(fromPercent: Int((clamped * 100).rounded()))
    }

    /// `0…1` speed → the device's `0`…`3` **delay**, inverted: fastest is 0.
    public static func keyboardDelay(_ speed01: Double) -> UInt8 {
        let clamped = min(max(speed01, 0), 1)
        return UInt8(((1 - clamped) * Double(Delay.max)).rounded())
    }

    public static func keyboardPlan(for look: DeskLook) -> KeyboardPlan {
        KeyboardPlan(mode: keyboardMode(for: look.family),
                     rainbow: look.family == .rainbowCycle,
                     brightnessLevel: keyboardBrightnessLevel(look.brightness),
                     delay: keyboardDelay(look.speed),
                     color: look.color.keyboardColor)
    }

    // MARK: - Mouse

    /// What the mouse should be set to for a look.
    ///
    /// `color` is `nil` for families whose mouse effect carries no colour array,
    /// so a caller cannot accidentally write a colour into an effect that has
    /// nowhere to put one.
    public struct MousePlan: Equatable, Sendable {
        public var effect: MouseRGBEffect
        public var color: MouseRGB?
        public var parameter: MouseModeParameter
        /// Only meaningful for ``MouseRGBEffect/rainbow``.
        public var rainbowDirection: MouseRainbowDirection?

        public init(effect: MouseRGBEffect, color: MouseRGB?,
                    parameter: MouseModeParameter,
                    rainbowDirection: MouseRainbowDirection?) {
            self.effect = effect
            self.color = color
            self.parameter = parameter
            self.rainbowDirection = rainbowDirection
        }
    }

    /// The mouse effect each family runs.
    ///
    /// Both travelling families land on `rainbow`, told apart by direction. The
    /// mouse does have a `wave` effect of its own, but it is a hue sweep with no
    /// colour parameter — the same thing `rainbow` is — so nothing is gained by
    /// splitting them and the direction carries the distinction instead.
    public static func mouseEffect(for family: DeskEffectFamily) -> MouseRGBEffect {
        switch family {
        case .solid:        return .single
        case .breathing:    return .breathing1
        case .wave:         return .rainbow
        case .rainbowCycle: return .rainbow
        }
    }

    /// Direction for the families that run as `rainbow`; `nil` for the rest.
    public static func mouseRainbowDirection(for family: DeskEffectFamily)
        -> MouseRainbowDirection? {
        switch family {
        case .wave:         return .up
        case .rainbowCycle: return .down
        case .solid, .breathing: return nil
        }
    }

    /// `0…1` → the device's `1`…`4`. Never 0 — see the type's discussion.
    public static func mouseBrightness(_ brightness01: Double) -> UInt8 {
        let clamped = min(max(brightness01, 0), 1)
        let span = Double(MouseModeParameter.maxBrightness - 1)   // 1…4 is three steps
        return UInt8(1 + Int((clamped * span).rounded()))
    }

    /// `0…1` → the device's `1`…`3`.
    ///
    /// The mouse's speed 0 means "static", which would freeze an effect the look
    /// asked to animate, so the floor is 1 for the same reason brightness's is.
    public static func mouseSpeed(_ speed01: Double) -> UInt8 {
        let clamped = min(max(speed01, 0), 1)
        let span = Double(MouseModeParameter.maxSpeed - 1)        // 1…3 is two steps
        return UInt8(1 + Int((clamped * span).rounded()))
    }

    public static func mousePlan(for look: DeskLook) -> MousePlan {
        let effect = mouseEffect(for: look.family)
        return MousePlan(effect: effect,
                         color: effect.colorArray == nil ? nil : look.color.mouseColor,
                         parameter: MouseModeParameter(speed: mouseSpeed(look.speed),
                                                       brightness: mouseBrightness(look.brightness)),
                         rainbowDirection: mouseRainbowDirection(for: look.family))
    }

    // MARK: - Reverse mapping

    /// The family a keyboard mode belongs to, or `nil` when it belongs to none.
    ///
    /// `nil` is the common case and the right answer: seventeen of the
    /// keyboard's twenty modes have no mouse counterpart, and picking one of
    /// those is the user asking that device for something specific rather than
    /// describing the desk. A caller syncing changes should leave the other
    /// device alone rather than approximate.
    public static func family(forKeyboardMode mode: LightingMode,
                              rainbow: Bool) -> DeskEffectFamily? {
        if rainbow {
            // The flag overrides the colour entirely, so any mode carrying it is
            // a hue cycle whatever else it is.
            return .rainbowCycle
        }
        switch mode {
        case .fixed:          return .solid
        case .breathing:      return .breathing
        case .horizontalWave: return .wave
        case .breathingCycle: return .rainbowCycle
        default:              return nil
        }
    }

    /// The family a mouse effect belongs to, or `nil` when it belongs to none.
    public static func family(forMouseEffect effect: MouseRGBEffect) -> DeskEffectFamily? {
        switch effect {
        case .single:            return .solid
        case .breathing1:        return .breathing
        case .wave:              return .wave
        case .rainbow:           return .rainbowCycle
        case .spectrumBreathing: return .rainbowCycle
        default:                 return nil
        }
    }

    /// `0`…`4` → `0…1`, the inverse of ``keyboardBrightnessLevel(_:)``.
    public static func brightness01(fromKeyboardLevel level: UInt8) -> Double {
        Double(min(level, Brightness.max)) / Double(Brightness.max)
    }

    /// `1`…`4` → `0…1`, the inverse of ``mouseBrightness(_:)``. A brightness of
    /// 0 on the device — LEDs off — reads back as 0.
    public static func brightness01(fromMouseBrightness brightness: UInt8) -> Double {
        guard brightness > 0 else { return 0 }
        let clamped = min(brightness, MouseModeParameter.maxBrightness)
        return Double(clamped - 1) / Double(MouseModeParameter.maxBrightness - 1)
    }

    /// `0`…`3` delay → `0…1` speed, the inverse of ``keyboardDelay(_:)``.
    public static func speed01(fromKeyboardDelay delay: UInt8) -> Double {
        1 - Double(min(delay, Delay.max)) / Double(Delay.max)
    }

    /// `1`…`3` → `0…1`, the inverse of ``mouseSpeed(_:)``. Speed 0 is the
    /// device's "static", which reads back as the slowest a look can name.
    public static func speed01(fromMouseSpeed speed: UInt8) -> Double {
        guard speed > 0 else { return 0 }
        let clamped = min(speed, MouseModeParameter.maxSpeed)
        return Double(clamped - 1) / Double(MouseModeParameter.maxSpeed - 1)
    }
}
