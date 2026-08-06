import AppKit
import GMMKProtocol

/// The one-time self-tune for a board with mixed switch housings.
///
/// Two phases, both live on the hardware:
///
/// * **Marking.** While this window is key, every key press toggles that key's
///   membership of the marked set and immediately repaints its LED — bright
///   white when marked, back to the target colour when unmarked. That is the
///   feedback the user needs to mark the right keys, and it doubles as a check
///   of ``GMMKKeyMap``: if a press lights the wrong LED, the table is wrong
///   there and the user can see exactly where.
///
///   What to mark is *whichever housing there are fewer of* — the odd ones out —
///   because marking costs one press per key. A segmented control then says
///   which kind those were, and that decides which side of the marked set is
///   the tinted one that gets corrected. See ``SwitchCompensation``.
/// * **Tuning.** The strength slider repaints the tinted keys, debounced, so the
///   user drags until the board matches the colour they picked.
///
/// Key presses are read with a **local** `NSEvent` monitor, which sees only this
/// app's own events and needs no Accessibility or Input Monitoring grant beyond
/// the one the HID transport already requires. Events are swallowed while the
/// window is key so marking a key never also types it.
final class SwitchCompensationWindowController: NSWindowController, NSWindowDelegate {

    /// How long the strength slider must be still before the board is repainted.
    /// A repaint is twelve packets; a drag would otherwise queue far more of
    /// them than the user can see.
    static let repaintDebounce: TimeInterval = 0.100

    /// Colour a key flashes to when it is marked.
    static let markedColor = RGB(red: 0xFF, green: 0xFF, blue: 0xFF)

    /// Fixed window width; the height follows from how the instructions wrap.
    private static let contentWidth: CGFloat = 420

    /// Virtual key code → the **device-dependent** bit that key sets in
    /// `NSEvent.modifierFlags.rawValue`.
    ///
    /// `NSEvent.ModifierFlags`' public constants are per *kind* of modifier:
    /// both Shift keys set `.shift`, so they cannot be told apart that way. The
    /// device-dependent bits below (`NX_DEVICE…KEYMASK`) are per physical key,
    /// which is what marking a left and a right modifier separately needs.
    private static let deviceModifierMasks: [UInt16: UInt] = [
        0x37: 0x000008,     // Left Command
        0x36: 0x000010,     // Right Command
        0x38: 0x000002,     // Left Shift
        0x3C: 0x000004,     // Right Shift
        0x3A: 0x000020,     // Left Option
        0x3D: 0x000040,     // Right Option
        0x3B: 0x000001,     // Left Control
        0x3E: 0x002000,     // Right Control
    ]

    /// Caps Lock, which has no device-dependent bit of its own.
    private static let capsLockKeyCode: UInt16 = 0x39

    /// Everything the tuner owns, reported back in one piece for persistence.
    struct Tuning {
        var markedLEDIndices: Set<UInt16>
        var markedSwitches: SwitchCompensation.MarkedSwitches
        var strength: Double
    }

    private let controller: KeyboardController

    private var target: RGB = .black
    private var markedLEDIndices: Set<UInt16> = []
    private var markedSwitches: SwitchCompensation.MarkedSwitches = .trueColor
    private var strength = SwitchCompensation.defaultStrength

    /// Reports the tuning back so it can be persisted.
    var onChange: ((Tuning) -> Void)?

    private let instructionLabel = NSTextField(wrappingLabelWithString: """
        Press every key whose switch is the odd one out — whichever kind of \
        housing your board has fewer of. Marked keys light up white; press one \
        again to unmark it.

        Say which kind you marked, then drag the slider until the whole board \
        matches the colour you picked. The keys that tint the light are the ones \
        corrected; the rest are left alone.

        Fn is handled inside the keyboard and never reaches the Mac, so use the \
        button for it.
        """)
    private let statusLabel = NSTextField(labelWithString: "")
    private let switchKindControl = NSSegmentedControl(
        labels: ["The true-color ones", "The tinted ones"],
        trackingMode: .selectOne,
        target: nil,
        action: nil)
    private lazy var strengthRow = SliderRowView(title: "Correction Strength",
                                                 range: 0...100) { "\($0)%" }

    private var keyMonitor: Any?
    /// Modifier key codes currently held down, derived from each event's flags
    /// rather than counted, so only the press edge toggles.
    private var heldModifierKeyCodes: Set<UInt16> = []
    /// Last known Caps Lock state, seeded when the monitor is installed.
    private var capsLockWasOn = false
    private var pendingRepaint: DispatchWorkItem?

    // MARK: - Lifecycle

    init(controller: KeyboardController) {
        self.controller = controller

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 260),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Switch Compensation"
        // The controller outlives the window so the tuner can be reopened with
        // its state intact; without this the close would deallocate it.
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        let content = buildContentView()
        window.contentView = content
        // The instructions wrap, so their height depends on the width — let
        // auto layout say how tall the window needs to be rather than guessing.
        window.setContentSize(content.fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContentView() -> NSView {
        instructionLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor

        strengthRow.onChange = { [weak self] percent in
            self?.strengthChanged(percent: percent)
        }

        switchKindControl.target = self
        switchKindControl.action = #selector(switchKindChanged)
        let switchKindLabel = NSTextField(labelWithString: "Marked keys are:")
        switchKindLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let switchKindRow = NSStackView(views: [switchKindLabel, switchKindControl])
        switchKindRow.orientation = .horizontal
        switchKindRow.spacing = 8

        let fnButton = NSButton(title: "Toggle Fn Key",
                                target: self,
                                action: #selector(toggleFnKey))
        let clearButton = NSButton(title: "Clear Marks",
                                   target: self,
                                   action: #selector(clearMarks))
        // Deliberately no key equivalent on either button: the key monitor
        // swallows every press while the window is key, so a Return or Escape
        // shortcut would look available and never fire.
        let doneButton = NSButton(title: "Done", target: self, action: #selector(done))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [fnButton, clearButton, spacer, doneButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill

        let stack = NSStackView(views: [instructionLabel, statusLabel,
                                        switchKindRow, strengthRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 260))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            instructionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            strengthRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        return content
    }

    // MARK: - Presentation

    /// Shows the window seeded with the persisted state and paints the board so
    /// the marking phase starts from what the settings describe.
    ///
    /// The paint is also what puts the board in mode `custom`, which the
    /// single-key writes during marking rely on.
    func present(target: RGB, tuning: Tuning) {
        self.target = target
        markedLEDIndices = tuning.markedLEDIndices
        markedSwitches = tuning.markedSwitches
        strength = tuning.strength

        switchKindControl.selectedSegment = markedSwitches == .trueColor ? 0 : 1
        strengthRow.setValue(Int((strength * 100).rounded()))
        updateStatus()

        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        repaintAll()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        pendingRepaint?.cancel()
        pendingRepaint = nil
        // Leave the board in the state the settings describe rather than
        // covered in the white marking flashes.
        repaintAll()
    }

    @objc private func done() {
        close()
    }

    @objc private func clearMarks() {
        markedLEDIndices.removeAll()
        heldModifierKeyCodes.removeAll()
        updateStatus()
        notifyChange()
        repaintAll()
    }

    /// Which kind of switch the marks identify. Flipping it swaps which half of
    /// the board is corrected, so the board is repainted at once.
    @objc private func switchKindChanged() {
        markedSwitches = switchKindControl.selectedSegment == 1 ? .tinted : .trueColor
        notifyChange()
        repaintAll()
    }

    // MARK: - Key capture

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Seed from the world as it is, so the first Caps Lock press reads as a
        // change and the first modifier press is not mistaken for a release.
        capsLockWasOn = NSEvent.modifierFlags.contains(.capsLock)
        heldModifierKeyCodes.removeAll()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        heldModifierKeyCodes.removeAll()
    }

    /// - Returns: `nil` to swallow the event, so marking a key does not also
    ///   type it or fire a menu shortcut.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard window?.isKeyWindow == true else { return event }

        if event.type == .flagsChanged {
            guard isPressEdge(of: event) else { return nil }
        } else if event.isARepeat {
            return nil
        }

        toggle(keyCode: event.keyCode)
        return nil
    }

    /// Whether a `flagsChanged` event is the key going **down**.
    ///
    /// Modifiers never produce `keyDown`; they arrive here, and press and
    /// release look identical apart from the flags they carry. The reliable
    /// signal is the flag state itself rather than counting events, which
    /// desynchronises the moment one is missed — releasing Shift while another
    /// app is focused, say.
    ///
    /// Caps Lock is the exception twice over: it has no device-dependent bit,
    /// and `.capsLock` reports the *lock*, not the key. Each physical press
    /// flips the lock exactly once, so a change in either direction is one
    /// press — which also means Caps can be marked and unmarked normally.
    private func isPressEdge(of event: NSEvent) -> Bool {
        let flags = event.modifierFlags

        if let mask = Self.deviceModifierMasks[event.keyCode] {
            guard flags.rawValue & mask != 0 else {
                heldModifierKeyCodes.remove(event.keyCode)
                return false
            }
            return heldModifierKeyCodes.insert(event.keyCode).inserted
        }

        if event.keyCode == Self.capsLockKeyCode {
            let locked = flags.contains(.capsLock)
            defer { capsLockWasOn = locked }
            return locked != capsLockWasOn
        }

        // Anything else with no press edge we can name — the keyboard's own Fn
        // among them, which never reaches macOS at all.
        return false
    }

    /// Toggles the key that reports `keyCode`.
    private func toggle(keyCode: UInt16) {
        guard let key = GMMKKeyMap.key(forKeyCode: keyCode) else {
            statusLabel.stringValue = markedSummary
                + " — key code \(keyCode) is not on the ANSI TKL map"
            return
        }
        toggle(ledIndex: key.ledIndex, label: key.label)
    }

    /// The keyboard's Fn key is handled inside the firmware and never produces
    /// an event, so it can only be marked by naming its LED index.
    @objc private func toggleFnKey() {
        toggle(ledIndex: GMMKKeyMap.fnLEDIndex, label: "Fn")
    }

    private func toggle(ledIndex: UInt16, label: String) {
        let isMarked: Bool
        if markedLEDIndices.contains(ledIndex) {
            markedLEDIndices.remove(ledIndex)
            isMarked = false
        } else {
            markedLEDIndices.insert(ledIndex)
            isMarked = true
        }

        statusLabel.stringValue = markedSummary
            + " — \(label) \(isMarked ? "marked" : "unmarked") (LED \(ledIndex))"
        notifyChange()

        // One packet, straight away: white while marked, back to whatever that
        // key should show while not. A marked key stays white until the next
        // whole-board repaint, which is what makes the set visible on the
        // hardware.
        let restored = SwitchCompensation.color(forLEDIndex: ledIndex,
                                                target: target,
                                                markedLEDIndices: markedLEDIndices,
                                                markedSwitches: markedSwitches,
                                                strength: strength)
        controller.paintKey(ledIndex: ledIndex,
                            color: isMarked ? Self.markedColor : restored)
    }

    // MARK: - Strength

    private func strengthChanged(percent: Int) {
        strength = Double(percent) / 100.0
        notifyChange()
        pendingRepaint?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pendingRepaint = nil
            self?.repaintAll()
        }
        pendingRepaint = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.repaintDebounce, execute: item)
    }

    // MARK: - Painting

    private func repaintAll() {
        controller.paintCompensated(target: target,
                                    markedLEDIndices: markedLEDIndices,
                                    markedSwitches: markedSwitches,
                                    strength: strength)
    }

    private func notifyChange() {
        onChange?(Tuning(markedLEDIndices: markedLEDIndices,
                         markedSwitches: markedSwitches,
                         strength: strength))
    }

    private var markedSummary: String {
        let count = markedLEDIndices.count
        return "\(count) key\(count == 1 ? "" : "s") marked"
    }

    private func updateStatus() {
        statusLabel.stringValue = markedSummary
    }
}
