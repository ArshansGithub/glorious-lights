import AppKit
import GloriousMouseProtocol

/// The per-LED colour picker: six wells, one per addressable LED.
///
/// The mouse's `constant` effect drives all six LEDs independently — see
/// ``MouseLED`` for where they physically are, and note two things that shape
/// this window: both side strips are **mirrored**, so a colour applies to the
/// same position on each flank rather than to a side, and the **scroll wheel
/// follows LED 1**, so choosing LED 1's colour is choosing the wheel's.
///
/// Changes apply live, debounced. Every apply is a whole 520-byte blob write
/// plus a read-back, so a colour panel dragged continuously would otherwise
/// queue far more writes than the mouse can usefully show.
final class MouseLEDWindowController: NSWindowController, NSWindowDelegate {

    /// How long the wells must be still before the mouse is written to.
    /// Longer than the keyboard's throttle because each apply is two feature
    /// transfers rather than one short packet.
    static let applyDebounce: TimeInterval = 0.200

    private static let contentWidth: CGFloat = 320

    private let controller: MouseController

    private var colors: [MouseRGB]
    private var wells: [NSColorWell] = []
    private var pendingApply: DispatchWorkItem?

    /// Reports the six colours back so they can be persisted.
    var onChange: (([MouseRGB]) -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")

    init(controller: MouseController, colors: [MouseRGB]) {
        self.controller = controller
        self.colors = MouseLED.padded(colors)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: Self.contentWidth, height: 380),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Per-LED Colors"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        let content = buildContentView()
        window.contentView = content
        window.setContentSize(content.fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Construction

    private func buildContentView() -> NSView {
        let intro = NSTextField(wrappingLabelWithString: """
            Both side strips show all six LEDs, front to back, mirrored — a \
            colour lights the same position on each side. The scroll wheel \
            follows LED 1.
            """)
        intro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        intro.textColor = .secondaryLabelColor

        var rows: [NSView] = [intro]
        for index in MouseLED.indices {
            let label = NSTextField(labelWithString: MouseLED.label(forIndex: index))
            label.font = .systemFont(ofSize: NSFont.systemFontSize)

            let well = NSColorWell()
            well.color = nsColor(colors[index - 1])
            well.target = self
            well.action = #selector(wellChanged(_:))
            well.tag = index
            well.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                well.widthAnchor.constraint(equalToConstant: 56),
                well.heightAnchor.constraint(equalToConstant: 24),
            ])
            wells.append(well)

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [label, spacer, well])
            row.orientation = .horizontal
            row.distribution = .fill
            rows.append(row)
        }

        let copyButton = NSButton(title: "Copy LED 1 to All",
                                  target: self,
                                  action: #selector(copyFirstToAll))
        let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [copyButton, buttonSpacer, doneButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        rows.append(statusLabel)
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 380))
        content.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            content.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ]
        for row in rows {
            constraints.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                                          constant: -32))
        }
        NSLayoutConstraint.activate(constraints)
        return content
    }

    // MARK: - Presentation

    /// Shows the window seeded with `colors`, and — because the mouse may be in
    /// some other effect entirely — applies them once so what is on screen and
    /// what is on the mouse agree from the start.
    func present(colors: [MouseRGB]) {
        self.colors = MouseLED.padded(colors)
        for (offset, well) in wells.enumerated() {
            well.color = nsColor(self.colors[offset])
        }
        refreshStatus()

        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        apply()
    }

    func windowWillClose(_ notification: Notification) {
        pendingApply?.cancel()
        pendingApply = nil
        // A well left activated would keep the shared colour panel pointed at a
        // window that is gone.
        NSColorPanel.shared.close()
    }

    @objc private func done() { close() }

    // MARK: - Actions

    @objc private func wellChanged(_ sender: NSColorWell) {
        let index = sender.tag
        guard MouseLED.indices.contains(index) else { return }
        guard let color = mouseColor(from: sender.color) else { return }
        colors[index - 1] = color
        scheduleApply()
    }

    /// The convenience the six-well layout otherwise makes tedious: one colour
    /// everywhere, which is also how you get back to a plain solid look without
    /// leaving this mode.
    @objc private func copyFirstToAll() {
        let first = colors[0]
        colors = Array(repeating: first, count: MouseLED.count)
        for well in wells { well.color = nsColor(first) }
        scheduleApply()
    }

    // MARK: - Applying

    private func scheduleApply() {
        onChange?(colors)
        pendingApply?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pendingApply = nil
            self?.apply()
        }
        pendingApply = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.applyDebounce, execute: item)
    }

    private func apply() {
        controller.setPerLEDColors(colors)
        refreshStatus()
    }

    private func refreshStatus() {
        guard controller.isConnected else {
            statusLabel.stringValue = "Mouse not connected."
            return
        }
        statusLabel.stringValue = controller.perLEDColors == colors
            ? "Applied — the mouse is showing these six colours."
            : "Applying…"
    }

    // MARK: - Colour conversion

    private func nsColor(_ color: MouseRGB) -> NSColor {
        NSColor(srgbRed: CGFloat(color.red) / 255,
                green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255,
                alpha: 1)
    }

    private func mouseColor(from color: NSColor) -> MouseRGB? {
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        let scale = { (value: CGFloat) in UInt8(max(0, min(255, (value * 255).rounded()))) }
        return MouseRGB(red: scale(converted.redComponent),
                        green: scale(converted.greenComponent),
                        blue: scale(converted.blueComponent))
    }
}
