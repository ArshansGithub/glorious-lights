import Foundation
import GMMKHID
import GMMKProtocol

/// Owns the HID transport and turns UI intents into bracketed transactions.
///
/// Main-thread only, like ``GMMKKeyboard`` itself: the HID manager is scheduled
/// on the main run loop, so hot-plug callbacks arrive there and every send
/// happens there too. Sends are cheap (a handful of 63-byte reports with a 2 ms
/// gap), and doing them inline keeps ordering trivially correct.
final class KeyboardController {

    /// Throttle window for continuous controls (sliders, the colour panel).
    /// Long enough to collapse a drag into a few writes, short enough that the
    /// keyboard still tracks the slider.
    static let throttleInterval: TimeInterval = 0.030

    private let keyboard = GMMKKeyboard()
    private var pendingSends: [String: DispatchWorkItem] = [:]
    /// Uptime of the last delivery per throttle key, for the leading edge.
    private var lastDelivery: [String: TimeInterval] = [:]

    /// Fires whenever ``isConnected`` changes or a send fails, so the menu can
    /// redraw its status line. Passed the message to show, if any.
    var onStatusChange: (() -> Void)?

    private(set) var lastError: String?

    var isConnected: Bool { keyboard.isConnected }

    init() {
        keyboard.onConnect = { [weak self] in
            self?.lastError = nil
            self?.onStatusChange?()
        }
        keyboard.onDisconnect = { [weak self] in
            // A send error from while the keyboard was still attached must not
            // survive the unplug, or the menu reports "found, but not usable"
            // for a keyboard that is not there at all.
            self?.lastError = nil
            self?.onStatusChange?()
        }
        keyboard.onOpenFailure = { [weak self] error in
            self?.lastError = error.description
            self?.onStatusChange?()
        }
    }

    /// Starts hot-plug monitoring on the main run loop. Does not send anything.
    func start() {
        keyboard.start(on: .main, mode: .commonModes)
        onStatusChange?()
    }

    func stop() {
        for item in pendingSends.values { item.cancel() }
        pendingSends.removeAll()
        lastDelivery.removeAll()
        keyboard.stop()
    }

    // MARK: - Commands

    // Each of these is one ``GMMKTransaction`` operation: START, the field
    // written at all three profile bases, END. See `GMMKTransaction` for why
    // the repetition is necessary.

    func setMode(_ mode: LightingMode) {
        send(GMMKTransaction.setMode(mode))
    }

    /// `percent` is 0–100; the device gets 0–4.
    func setBrightness(percent: Int, throttleKey: String? = "brightness") {
        send(GMMKTransaction.setBrightness(level: Brightness.level(fromPercent: percent)),
             throttleKey: throttleKey)
    }

    /// `speed` is 1 (slowest) – 5 (fastest); the device gets delay 3–0.
    func setSpeed(_ speed: Int, throttleKey: String? = "speed") {
        send(GMMKTransaction.setDelay(Delay.delay(fromSpeed: speed)), throttleKey: throttleKey)
    }

    /// Sends the colour with rainbow explicitly off in the same transaction —
    /// with the flag set the effect ignores the colour entirely, so a colour
    /// write on its own reads to the user as "nothing happened".
    func setColor(_ color: RGB, throttleKey: String? = "color") {
        send(GMMKTransaction.setColor(color), throttleKey: throttleKey)
    }

    func setRainbow(_ on: Bool) {
        send(GMMKTransaction.setRainbow(on))
    }

    /// Switches to mode `custom` and paints every LED the target colour, with
    /// the marked keys compensated — see ``SwitchCompensation``, including what
    /// the sign of `strength` means.
    ///
    /// Twelve packets rather than the usual five, so it gets its own throttle
    /// key: a strength drag must not be able to cancel a pending colour write.
    func paintCompensated(target: RGB,
                          markedLEDIndices: Set<UInt16>,
                          strength: Double,
                          throttleKey: String? = "paint") {
        send(GMMKTransaction.paintCompensated(target: target,
                                              markedLEDIndices: markedLEDIndices,
                                              strength: strength),
             throttleKey: throttleKey)
    }

    /// Paints one LED. Sent unthrottled — it is a single write, and it is the
    /// feedback for a key press, so dropping one would read as a dead key.
    ///
    /// Only visible if the board is already in mode `custom`; the tuner paints
    /// the whole board when it opens, which is what puts it there.
    func paintKey(ledIndex: UInt16, color: RGB) {
        send(GMMKTransaction.paintKey(ledIndex: ledIndex, color: color))
    }

    // MARK: - Sending

    /// Sends immediately, or throttles on `throttleKey` when one is given.
    ///
    /// This is a leading-edge throttle with a trailing send, not a plain
    /// debounce: the first event of a drag goes out at once and at most one
    /// write lands per window afterwards, so the keyboard previews the drag
    /// live instead of staying dark until the user lets go. Throttling is per
    /// key so a colour drag never cancels a pending brightness write.
    private func send(_ packets: [[UInt8]], throttleKey: String? = nil) {
        guard let key = throttleKey else {
            deliver(packets)
            return
        }
        pendingSends[key]?.cancel()
        pendingSends[key] = nil

        let now = ProcessInfo.processInfo.systemUptime
        let remaining: TimeInterval
        if let last = lastDelivery[key] {
            remaining = Self.throttleInterval - (now - last)
        } else {
            remaining = 0
        }
        guard remaining > 0 else {
            lastDelivery[key] = now
            deliver(packets)
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSends[key] = nil
            self.lastDelivery[key] = ProcessInfo.processInfo.systemUptime
            self.deliver(packets)
        }
        pendingSends[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: item)
    }

    private func deliver(_ packets: [[UInt8]]) {
        guard keyboard.isConnected else { return }
        do {
            try keyboard.send(packets: packets)
            if lastError != nil {
                lastError = nil
                onStatusChange?()
            }
        } catch {
            lastError = String(describing: error)
            onStatusChange?()
        }
    }
}
