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

    /// Debounce window for continuous controls (sliders, the colour panel).
    /// Long enough to collapse a drag into a few writes, short enough that the
    /// keyboard still tracks the slider.
    static let debounceInterval: TimeInterval = 0.030

    private let keyboard = GMMKKeyboard()
    private var pendingSends: [String: DispatchWorkItem] = [:]

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
        keyboard.stop()
    }

    // MARK: - Commands

    func setMode(_ mode: LightingMode) {
        send(GMMKTransaction.single(GMMKPacket.setMode(mode)))
    }

    /// `percent` is 0–100; the device gets 0–4.
    func setBrightness(percent: Int, debounceKey: String? = "brightness") {
        let packet = GMMKPacket.setBrightness(level: Brightness.level(fromPercent: percent))
        send(GMMKTransaction.single(packet), debounceKey: debounceKey)
    }

    /// `speed` is 1 (slowest) – 5 (fastest); the device gets delay 3–0.
    func setSpeed(_ speed: Int, debounceKey: String? = "speed") {
        let packet = GMMKPacket.setDelay(Delay.delay(fromSpeed: speed))
        send(GMMKTransaction.single(packet), debounceKey: debounceKey)
    }

    /// Sends the colour with rainbow explicitly off in the same transaction.
    ///
    /// Same reasoning as the CLI's `color` command: with the rainbow flag set
    /// the effect ignores the solid colour entirely, so a colour write on its
    /// own reads to the user as "nothing happened".
    func setColor(_ color: RGB, debounceKey: String? = "color") {
        let packets = GMMKTransaction.bracket([
            GMMKPacket.setRainbow(false),
            GMMKPacket.setColor(red: color.red, green: color.green, blue: color.blue),
        ])
        send(packets, debounceKey: debounceKey)
    }

    func setRainbow(_ on: Bool) {
        send(GMMKTransaction.single(GMMKPacket.setRainbow(on)))
    }

    // MARK: - Sending

    /// Sends immediately, or coalesces on `debounceKey` when one is given.
    ///
    /// Debouncing is per key so a colour drag never cancels a pending
    /// brightness write.
    private func send(_ packets: [[UInt8]], debounceKey: String? = nil) {
        guard let key = debounceKey else {
            deliver(packets)
            return
        }
        pendingSends[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pendingSends[key] = nil
            self?.deliver(packets)
        }
        pendingSends[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
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
