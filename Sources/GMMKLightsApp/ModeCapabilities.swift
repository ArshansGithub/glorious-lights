import GMMKProtocol

/// UI-only policy about which controls make sense for which effect.
///
/// This is presentation, not protocol: the firmware accepts a colour write in
/// any mode, it just may not use it. Keeping it here rather than in
/// `GMMKProtocol` avoids asserting anything the packet reference doesn't.
extension LightingMode {

    /// Whether the solid colour at config `0x05` visibly affects this effect.
    ///
    /// Excluded: ``off`` (nothing lit), ``custom`` (colours come from LED
    /// colour RAM instead), ``breathingCycle`` (cycles hues by definition), and
    /// ``reactiveColor`` (uses the variant byte at config `0x08`).
    var usesSolidColor: Bool {
        switch self {
        case .off, .custom, .breathingCycle, .reactiveColor: return false
        default: return true
        }
    }

    /// Whether this effect animates, i.e. whether the speed control matters.
    var isAnimated: Bool {
        switch self {
        case .fixed, .off, .custom: return false
        default: return true
        }
    }
}
