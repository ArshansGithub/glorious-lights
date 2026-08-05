import AppKit

/// Shared geometry so every custom row lines up with AppKit's own menu items.
enum MenuMetrics {
    static let width: CGFloat = 260
    static let leadingInset: CGFloat = 20
    static let trailingInset: CGFloat = 14
    static let rowHeight: CGFloat = 26
}

/// A labelled slider hosted inside an `NSMenuItem`.
///
/// The slider is continuous; ``onChange`` fires on every intermediate value and
/// the controller throttles (leading edge plus a trailing send), so dragging
/// produces a live preview on the keyboard without flooding the HID endpoint.
final class SliderRowView: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let format: (Int) -> String

    /// Called with the slider's integer value on every change.
    var onChange: ((Int) -> Void)?

    init(title: String,
         range: ClosedRange<Int>,
         tickCount: Int? = nil,
         format: @escaping (Int) -> String) {
        self.format = format
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: MenuMetrics.width,
                                 height: MenuMetrics.rowHeight * 2))

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        if let tickCount {
            slider.numberOfTickMarks = tickCount
            slider.allowsTickMarkValuesOnly = true
            slider.tickMarkPosition = .below
        }

        for view in [titleLabel, valueLabel, slider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                constant: MenuMetrics.leadingInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                 constant: -MenuMetrics.trailingInset),
            valueLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                                constant: 8),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor,
                                            constant: MenuMetrics.leadingInset),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -MenuMetrics.trailingInset),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        titleLabel.stringValue = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Sets the displayed value without invoking ``onChange``.
    func setValue(_ value: Int) {
        slider.integerValue = value
        valueLabel.stringValue = format(value)
    }

    var isControlEnabled: Bool {
        get { slider.isEnabled }
        set {
            slider.isEnabled = newValue
            titleLabel.textColor = newValue ? .labelColor : .disabledControlTextColor
            valueLabel.textColor = newValue ? .secondaryLabelColor : .disabledControlTextColor
        }
    }

    @objc private func sliderMoved() {
        let value = slider.integerValue
        valueLabel.stringValue = format(value)
        onChange?(value)
    }
}

/// A row showing the current colour as a swatch. Clicking it dismisses the menu
/// and opens the shared `NSColorPanel`.
///
/// An `NSColorWell` embedded in a menu item is awkward: the colour panel is a
/// window, and opening one while the menu is in its own tracking run-loop mode
/// leaves the panel unresponsive until the menu closes. Dismissing first and
/// driving `NSColorPanel` directly gives the same affordance without that trap.
final class ColorRowView: NSView {

    private let titleLabel = NSTextField(labelWithString: "Color")
    private let swatch = NSView()
    private let hexLabel = NSTextField(labelWithString: "")
    private var isHighlighted = false

    /// Called when the row is clicked and the menu has been dismissed.
    var onClick: (() -> Void)?

    private(set) var isControlEnabled = true {
        didSet {
            titleLabel.textColor = isControlEnabled ? .labelColor : .disabledControlTextColor
            hexLabel.textColor = isControlEnabled ? .secondaryLabelColor : .disabledControlTextColor
            swatch.alphaValue = isControlEnabled ? 1.0 : 0.4
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: MenuMetrics.width,
                                 height: MenuMetrics.rowHeight))

        titleLabel.font = .menuFont(ofSize: 0)
        hexLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        hexLabel.textColor = .secondaryLabelColor

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor

        for view in [titleLabel, hexLabel, swatch] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                constant: MenuMetrics.leadingInset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            swatch.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -MenuMetrics.trailingInset),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 34),
            swatch.heightAnchor.constraint(equalToConstant: 14),

            hexLabel.trailingAnchor.constraint(equalTo: swatch.leadingAnchor, constant: -8),
            hexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hexLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                              constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setColor(_ color: NSColor, hexText: String) {
        swatch.layer?.backgroundColor = color.cgColor
        hexLabel.stringValue = hexText
    }

    func setEnabled(_ enabled: Bool) { isControlEnabled = enabled }

    // MARK: - Highlight + click

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        // `selectedMenuItemColor` is deprecated; the content-selection colour is
        // the supported accent-tracking equivalent and matches AppKit's own rows.
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0),
                     xRadius: 4, yRadius: 4).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isControlEnabled else { return }
        isHighlighted = true
        titleLabel.textColor = .selectedMenuItemTextColor
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        clearHighlight()
    }

    private func clearHighlight() {
        isHighlighted = false
        titleLabel.textColor = isControlEnabled ? .labelColor : .disabledControlTextColor
        needsDisplay = true
    }

    /// The menu can also be dismissed (Escape, a click elsewhere) with the
    /// cursor still over the row, so drop the highlight when the row leaves the
    /// window rather than relying on `mouseExited` alone.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clearHighlight() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // `separatorColor` is dynamic; a `cgColor` resolved at init would stay
        // frozen at whichever appearance was current then.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isControlEnabled else { return }
        // `cancelTracking` only *requests* dismissal; the menu's tracking loop
        // exits on a later pass. Ordering a window in from inside that loop is
        // the same trap this row exists to avoid, so hop to the next main-queue
        // turn. Clear the highlight here too — `mouseExited` never arrives when
        // the menu is dismissed with the cursor over the row.
        enclosingMenuItem?.menu?.cancelTracking()
        clearHighlight()
        DispatchQueue.main.async { [onClick] in onClick?() }
    }
}
