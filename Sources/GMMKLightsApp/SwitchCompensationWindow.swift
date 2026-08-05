import AppKit
import GMMKProtocol

/// The one-time self-tune for a board with mixed switch housings.
///
/// Two phases, both live on the hardware:
///
/// * **Marking.** While this window is key, every key press toggles that key's
///   membership of the Lynx set and immediately repaints its LED — bright white
///   when marked, back to the target colour when unmarked. That is the feedback
///   the user needs to mark the right keys, and it doubles as a check of
///   ``GMMKKeyMap``: if a press lights the wrong LED, the table is wrong there
///   and the user can see exactly where.
/// * **Tuning.** The strength slider repaints all marked keys, debounced, so the
///   user drags until the board looks uniform.
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

    private let controller: KeyboardController

    private var target: RGB = .black
    private var lynxLEDIndices: Set<UInt16> = []
    private var strength = SwitchCompensation.defaultStrength

    /// Reports the marked set and strength back so they can be persisted.
    var onChange: ((Set<UInt16>, Double) -> Void)?

    private let instructionLabel = NSTextField(wrappingLabelWithString: """
        Press every key that has a Lynx switch. Marked keys light up white; \
        press one again to unmark it. Then drag the slider until the board \
        looks like one colour.
        """)
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var strengthRow = SliderRowView(title: "Compensation Strength",
                                                 range: 0...100) { "\($0)%" }

    private var keyMonitor: Any?
    /// Modifier key codes currently held down. `flagsChanged` fires on both
    /// press and release with no flag saying which, so the transitions are
    /// tracked here and only the press edge toggles.
    private var heldModifierKeyCodes: Set<UInt16> = []
    private var pendingRepaint: DispatchWorkItem?

    // MARK: - Lifecycle

    init(controller: KeyboardController) {
        self.controller = controller

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Switch Compensation"
        // The controller outlives the window so the tuner can be reopened with
        // its state intact; without this the close would deallocate it.
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        window.contentView = buildContentView()
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

        let clearButton = NSButton(title: "Clear Marks",
                                   target: self,
                                   action: #selector(clearMarks))
        // Deliberately no key equivalent on either button: the key monitor
        // swallows every press while the window is key, so a Return or Escape
        // shortcut would look available and never fire.
        let doneButton = NSButton(title: "Done", target: self, action: #selector(done))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [clearButton, spacer, doneButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill

        let stack = NSStackView(views: [instructionLabel, statusLabel, strengthRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
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
    func present(target: RGB, lynxLEDIndices: Set<UInt16>, strength: Double) {
        self.target = target
        self.lynxLEDIndices = lynxLEDIndices
        self.strength = strength

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
        lynxLEDIndices.removeAll()
        heldModifierKeyCodes.removeAll()
        updateStatus()
        onChange?(lynxLEDIndices, strength)
        repaintAll()
    }

    // MARK: - Key capture

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
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
            // Press and release look identical here, so only the press edge —
            // the transition into the held set — counts as a mark.
            if heldModifierKeyCodes.contains(event.keyCode) {
                heldModifierKeyCodes.remove(event.keyCode)
                return nil
            }
            heldModifierKeyCodes.insert(event.keyCode)
        } else if event.isARepeat {
            return nil
        }

        toggle(keyCode: event.keyCode)
        return nil
    }

    private func toggle(keyCode: UInt16) {
        guard let key = GMMKKeyMap.key(forKeyCode: keyCode) else {
            statusLabel.stringValue = markedSummary
                + " — key code \(keyCode) is not on the ANSI TKL map"
            return
        }

        let isMarked: Bool
        if lynxLEDIndices.contains(key.ledIndex) {
            lynxLEDIndices.remove(key.ledIndex)
            isMarked = false
        } else {
            lynxLEDIndices.insert(key.ledIndex)
            isMarked = true
        }

        statusLabel.stringValue = markedSummary
            + " — \(key.label) \(isMarked ? "marked" : "unmarked") (LED \(key.ledIndex))"
        onChange?(lynxLEDIndices, strength)

        // One packet, straight away: white while marked, back to the plain
        // target while not. A marked key stays white until the next whole-board
        // repaint, which is what makes the marked set visible on the hardware.
        controller.paintKey(ledIndex: key.ledIndex,
                            color: isMarked ? Self.markedColor : target)
    }

    // MARK: - Strength

    private func strengthChanged(percent: Int) {
        strength = Double(percent) / 100.0
        onChange?(lynxLEDIndices, strength)
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
                                    lynxLEDIndices: lynxLEDIndices,
                                    strength: strength)
    }

    private var markedSummary: String {
        let count = lynxLEDIndices.count
        return "\(count) key\(count == 1 ? "" : "s") marked"
    }

    private func updateStatus() {
        statusLabel.stringValue = markedSummary
    }
}
