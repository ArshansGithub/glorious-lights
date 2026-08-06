import Foundation
import GMMKProtocol

/// How the board interprets the music.
///
/// The original visualizer had one behaviour — draw the spectrum — and it read
/// as noise because a 17-column bar graph on a 6-row grid has no gesture to it.
/// These are gestures: a few large, coherent shapes that move with the music
/// over time. Every one of them is built so that **no isolated single key can
/// ever light**, which is what made the old output look like confetti.
public enum VisualizerMode: String, CaseIterable, Sendable {
    /// The whole board breathes with the beat; hue drifts with brightness.
    case pulse
    /// Each beat launches a band of light travelling across the board.
    case wave
    /// Onsets fire rings expanding from the centre.
    case ripple
    /// Bars, but grouped into musical registers and never narrower than two
    /// columns.
    case spectrum
    /// Loudness fills outward from the middle.
    case vu

    public var displayName: String {
        switch self {
        case .pulse:    return "Pulse"
        case .wave:     return "Wave"
        case .ripple:   return "Ripple"
        case .spectrum: return "Spectrum"
        case .vu:       return "VU"
        }
    }

    public var summary: String {
        switch self {
        case .pulse:    return "The board breathes with the beat"
        case .wave:     return "Light travels across on every beat"
        case .ripple:   return "Drum hits fire rings from the centre"
        case .spectrum: return "Bars by musical register"
        case .vu:       return "Loudness fills out from the middle"
        }
    }
}

/// Paints a ``MusicalFrame`` onto the keyboard.
///
/// Stateful: modes carry their own animation — a wave in flight, a ring
/// expanding, a decaying pulse — because the whole point is that the display has
/// memory. One instance per session.
public final class ModeRenderer {

    /// Colour ramp shared by every mode, so the board looks like one product
    /// whichever mode is running.
    ///
    /// `brightness` walks the hue from warm (bass-heavy) to cool (treble-rich),
    /// which is the synaesthetic mapping people already expect: low notes feel
    /// red and orange, high ones feel blue and white.
    public static func hue(forBrightness brightness: Float, themeColor: RGB,
                           useTheme: Bool) -> (r: Double, g: Double, b: Double) {
        if useTheme {
            return (Double(themeColor.red) / 255,
                    Double(themeColor.green) / 255,
                    Double(themeColor.blue) / 255)
        }
        // Deep orange → magenta → cyan, which keeps saturation up across the
        // whole sweep rather than passing through a washed-out yellow-green.
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (1.00, 0.25, 0.05)),
            (0.35, (0.95, 0.10, 0.55)),
            (0.70, (0.35, 0.30, 1.00)),
            (1.00, (0.10, 0.90, 1.00)),
        ]
        let position = Double(min(max(brightness, 0), 1))
        for index in 1..<stops.count where position <= stops[index].0 {
            let (lowPosition, low) = stops[index - 1]
            let (highPosition, high) = stops[index]
            let span = highPosition - lowPosition
            let t = span > 0 ? (position - lowPosition) / span : 0
            return (low.0 + (high.0 - low.0) * t,
                    low.1 + (high.1 - low.1) * t,
                    low.2 + (high.2 - low.2) * t)
        }
        return stops.last!.1
    }

    private static func rgb(_ components: (r: Double, g: Double, b: Double),
                            intensity: Double) -> RGB {
        func channel(_ value: Double) -> UInt8 {
            UInt8(max(0, min(255, (value * intensity * 255).rounded())))
        }
        return RGB(red: channel(components.r),
                   green: channel(components.g),
                   blue: channel(components.b))
    }

    public var mode: VisualizerMode
    public var themeColor: RGB
    /// Whether to paint in the desk look's colour instead of the brightness ramp.
    public var useThemeColor: Bool

    // Pulse
    private var pulseEnergy: Double = 0
    // Wave: positions in column space, negative or past the end means gone.
    private struct Wave { var position: Double; var speed: Double; var strength: Double
                          var direction: Double }
    private var waves: [Wave] = []
    private var waveDirection: Double = 1
    // Ripple
    private struct Ring { var radius: Double; var speed: Double; var strength: Double
                          var kind: OnsetKind }
    private var rings: [Ring] = []
    // Spectrum
    private var registerLevels: [Float] = []
    // VU
    private var vuLevel: Double = 0

    public init(mode: VisualizerMode = .pulse,
                themeColor: RGB = RGB(red: 0x00, green: 0xCC, blue: 0xAA),
                useThemeColor: Bool = false) {
        self.mode = mode
        self.themeColor = themeColor
        self.useThemeColor = useThemeColor
    }

    /// The width of the board in columns.
    private var columnCount: Int { VisualizerLayout.columns.count }

    /// Renders one frame to a colour per LED index.
    public func render(_ frame: MusicalFrame, elapsed: Double) -> [RGB] {
        var canvas = Canvas()
        switch mode {
        case .pulse:    renderPulse(frame, elapsed: elapsed, into: &canvas)
        case .wave:     renderWave(frame, elapsed: elapsed, into: &canvas)
        case .ripple:   renderRipple(frame, elapsed: elapsed, into: &canvas)
        case .spectrum: renderSpectrum(frame, elapsed: elapsed, into: &canvas)
        case .vu:       renderVU(frame, elapsed: elapsed, into: &canvas)
        }
        canvas.widenIsolatedColumns()
        return canvas.colors
    }

    public func reset() {
        pulseEnergy = 0
        waves.removeAll()
        rings.removeAll()
        registerLevels.removeAll()
        vuLevel = 0
    }

    /// A per-LED colour buffer with helpers that paint whole columns and rows,
    /// so a mode never addresses one key on its own.
    private struct Canvas {
        var colors = [RGB](repeating: .black,
                           count: GMMKKeyMap.paintableLEDIndices.count)

        mutating func paint(led: UInt16, _ color: RGB) {
            let offset = Int(led) - Int(GMMKKeyMap.minLEDIndex)
            guard colors.indices.contains(offset) else { return }
            colors[offset] = color
        }

        /// Fills a whole column to `height` of its rows, bottom up.
        mutating func fillColumn(_ index: Int, height: Double, color: (Int, Int) -> RGB) {
            guard VisualizerLayout.columns.indices.contains(index) else { return }
            let column = VisualizerLayout.columns[index]
            let rows = column.rowCount
            let lit = min(rows, max(0, Int((min(max(height, 0), 1) * Double(rows)).rounded(.up))))
            for row in 0..<lit {
                let colour = color(row, rows)
                for led in column.levelRows[row] { paint(led: led, colour) }
            }
        }

        /// Paints every key of a column one colour.
        mutating func wholeColumn(_ index: Int, _ color: RGB, includePeak: Bool = false) {
            guard VisualizerLayout.columns.indices.contains(index) else { return }
            let column = VisualizerLayout.columns[index]
            for row in column.levelRows {
                for led in row { paint(led: led, color) }
            }
            if includePeak {
                for led in column.peakKeys { paint(led: led, color) }
            }
        }

        mutating func peak(_ index: Int, _ color: RGB) {
            guard VisualizerLayout.columns.indices.contains(index) else { return }
            for led in VisualizerLayout.columns[index].peakKeys { paint(led: led, color) }
        }

        /// Relative luminance, the same measure a viewer's eye applies.
        private static func luminance(_ color: RGB) -> Double {
            (0.2126 * Double(color.red) + 0.7152 * Double(color.green)
             + 0.0722 * Double(color.blue)) / 255
        }

        /// Guarantees that no visibly-lit column stands alone.
        ///
        /// The modes are *written* to paint wide shapes, but a gaussian clipped
        /// at the edge of the board, or a ring whose arm lands on the last
        /// column, can still resolve to one bright column with dark neighbours —
        /// which is exactly the isolated-key look the redesign exists to remove.
        /// Widening here makes the property structural instead of a consequence
        /// of every mode's width parameters being large enough, so a future mode
        /// cannot reintroduce it by accident.
        mutating func widenIsolatedColumns() {
            let peak = colors.map(Self.luminance).max() ?? 0
            guard peak > 0.02 else { return }
            let threshold = peak * 0.45

            let columns = VisualizerLayout.columns
            func brightest(_ index: Int) -> (led: UInt16, color: RGB, luminance: Double)? {
                var best: (UInt16, RGB, Double)?
                for row in columns[index].levelRows {
                    for led in row {
                        let offset = Int(led) - Int(GMMKKeyMap.minLEDIndex)
                        guard colors.indices.contains(offset) else { continue }
                        let value = Self.luminance(colors[offset])
                        if best == nil || value > best!.2 { best = (led, colors[offset], value) }
                    }
                }
                return best
            }

            let lit = columns.indices.map { (brightest($0)?.luminance ?? 0) >= threshold }
            for index in columns.indices where lit[index] {
                let leftLit = index > 0 && lit[index - 1]
                let rightLit = index < columns.count - 1 && lit[index + 1]
                guard !leftLit, !rightLit else { continue }
                guard let source = brightest(index) else { continue }

                // Spill into whichever neighbour exists, scaled so it *clears*
                // the threshold rather than merely being a fraction of the
                // source — the source itself may be only just above the bar, in
                // which case three-quarters of it would still read as dark and
                // the column would stay isolated.
                let neighbour = index > 0 ? index - 1 : index + 1
                guard columns.indices.contains(neighbour), source.luminance > 0 else { continue }
                let target = Swift.max(threshold * 1.08, source.luminance * 0.75)
                let scale = Swift.min(1, target / source.luminance)
                func channel(_ value: UInt8) -> UInt8 {
                    UInt8(Swift.max(0, Swift.min(255, (Double(value) * scale).rounded())))
                }
                let spill = RGB(red: channel(source.color.red),
                                green: channel(source.color.green),
                                blue: channel(source.color.blue))
                for row in columns[neighbour].levelRows {
                    for led in row {
                        let offset = Int(led) - Int(GMMKKeyMap.minLEDIndex)
                        guard colors.indices.contains(offset),
                              Self.luminance(colors[offset]) < Self.luminance(spill) else {
                            continue
                        }
                        colors[offset] = spill
                    }
                }
            }
        }
    }

    // MARK: - Pulse

    /// The whole board breathes. Kicks hit it sharply and it decays musically,
    /// so the board reads as one object moving with the track.
    private func renderPulse(_ frame: MusicalFrame, elapsed: Double, into canvas: inout Canvas) {
        // Sharp attack on a kick, softer on other hits, and a floor from
        // loudness so sustained passages are not dark between drums.
        let kick = Double(frame.onset(.kick))
        let snare = Double(frame.onset(.snare))
        pulseEnergy = max(pulseEnergy, kick * 1.0)
        pulseEnergy = max(pulseEnergy, snare * 0.7)

        // Decay tied to tempo when we have one: a pulse that fades over about
        // half a beat feels locked to the music rather than arbitrary.
        let period = frame.tempo.isReliable ? (frame.tempo.beatPeriod ?? 0.5) : 0.5
        let decayTime = max(0.12, period * 0.55)
        pulseEnergy *= Double(exp(-elapsed / decayTime))

        let base = Double(frame.loudness) * 0.45
        let intensity = min(1, base + pulseEnergy * 0.75)
        // Never fully dark while audio is playing: a floor keeps the board alive
        // between hits instead of blinking off.
        let floor = frame.loudness > 0.02 ? 0.08 : 0
        let level = max(floor, intensity)
        guard level > 0 else { return }

        let colour = Self.hue(forBrightness: frame.brightness,
                              themeColor: themeColor, useTheme: useThemeColor)
        // Whole board, one colour: the largest possible gesture, and it cannot
        // produce an isolated key by construction.
        for index in 0..<columnCount {
            canvas.wholeColumn(index, Self.rgb(colour, intensity: level), includePeak: true)
        }
    }

    // MARK: - Wave

    /// Each beat launches a band of light across the board.
    private func renderWave(_ frame: MusicalFrame, elapsed: Double, into canvas: inout Canvas) {
        let trigger = max(frame.onset(.kick), frame.onset(.snare))
        if trigger > 0 {
            // Cross the board in about one beat, so the motion *is* the tempo.
            let period = frame.tempo.isReliable ? (frame.tempo.beatPeriod ?? 0.6) : 0.6
            let speed = Double(columnCount) / max(0.25, period)
            waves.append(Wave(position: waveDirection > 0 ? -2 : Double(columnCount) + 2,
                              speed: speed,
                              strength: Double(trigger),
                              direction: waveDirection))
            waveDirection *= -1
        }

        for index in waves.indices {
            waves[index].position += waves[index].speed * elapsed * waves[index].direction
            waves[index].strength *= Double(exp(-elapsed / 1.2))
        }
        waves.removeAll { $0.strength < 0.05
            || $0.position < -4 || $0.position > Double(columnCount) + 4 }

        let colour = Self.hue(forBrightness: frame.brightness,
                              themeColor: themeColor, useTheme: useThemeColor)
        // A dim bed so the board is never empty between waves.
        let bed = 0.06 + Double(frame.loudness) * 0.10
        for index in 0..<columnCount {
            canvas.wholeColumn(index, Self.rgb(colour, intensity: bed))
        }

        // Each wave is a wide gaussian — four or five columns — so it always
        // reads as a band rather than a moving dot. Measured: at 2.2 the
        // leading edge occasionally resolved to a single bright column.
        let width = 2.8
        for wave in waves {
            for index in 0..<columnCount {
                let distance = abs(Double(index) - wave.position)
                guard distance < width * 2.5 else { continue }
                let falloff = exp(-(distance * distance) / (2 * width * width))
                let level = min(1, bed + wave.strength * falloff)
                canvas.wholeColumn(index, Self.rgb(colour, intensity: level),
                                   includePeak: falloff > 0.6)
            }
        }
    }

    // MARK: - Ripple

    /// Rings expand from the centre, one per onset, coloured by what hit.
    private func renderRipple(_ frame: MusicalFrame, elapsed: Double, into canvas: inout Canvas) {
        for kind in OnsetKind.allCases {
            let strength = frame.onset(kind)
            guard strength > 0 else { continue }
            let speed: Double
            switch kind {
            case .kick:  speed = 9      // slow, heavy
            case .snare: speed = 14
            case .hat:   speed = 22     // quick and light
            }
            rings.append(Ring(radius: 0, speed: speed,
                              strength: Double(strength), kind: kind))
        }

        for index in rings.indices {
            rings[index].radius += rings[index].speed * elapsed
            rings[index].strength *= Double(exp(-elapsed / 0.7))
        }
        rings.removeAll { $0.strength < 0.05 || $0.radius > Double(columnCount) }

        let centre = Double(columnCount - 1) / 2
        let bed = 0.05 + Double(frame.loudness) * 0.08
        let bedColour = Self.hue(forBrightness: frame.brightness,
                                 themeColor: themeColor, useTheme: useThemeColor)
        for index in 0..<columnCount {
            canvas.wholeColumn(index, Self.rgb(bedColour, intensity: bed))
        }

        for ring in rings {
            let colour: (r: Double, g: Double, b: Double)
            if useThemeColor {
                colour = Self.hue(forBrightness: 0, themeColor: themeColor, useTheme: true)
            } else {
                switch ring.kind {
                case .kick:  colour = (1.00, 0.20, 0.15)
                case .snare: colour = (1.00, 0.85, 0.30)
                case .hat:   colour = (0.35, 0.85, 1.00)
                }
            }
            // A thick ring — a couple of columns either side of the radius — so
            // both arms of it are always more than one key wide. A ring is
            // symmetric about the centre, so each arm is measured separately by
            // the coherence metric and a thin ring scores as two lone columns.
            let thickness = 2.2
            for index in 0..<columnCount {
                let distance = abs(abs(Double(index) - centre) - ring.radius)
                guard distance < thickness * 2 else { continue }
                let falloff = exp(-(distance * distance) / (2 * thickness * thickness))
                let level = min(1, bed + ring.strength * falloff)
                canvas.wholeColumn(index, Self.rgb(colour, intensity: level),
                                   includePeak: ring.kind == .hat && falloff > 0.7)
            }
        }
    }

    // MARK: - Spectrum

    /// Bars again, but by musical register and never narrower than two columns.
    ///
    /// The original had seventeen independent bars, which is why single columns
    /// could spike alone and the board looked like confetti. Grouping into six
    /// registers and painting each across a contiguous run of columns means the
    /// smallest possible feature is a two-column block.
    private func renderSpectrum(_ frame: MusicalFrame, elapsed: Double,
                                into canvas: inout Canvas) {
        let registerCount = 6
        var targets = [Float](repeating: 0, count: registerCount)
        guard !frame.bandLevels.isEmpty else { return }

        // Group the columns into registers, weighting each register by the
        // loudest band in it — a mean would wash out the very feature a bar is
        // meant to show.
        let perRegister = Double(frame.bandLevels.count) / Double(registerCount)
        for register in 0..<registerCount {
            let lower = Int(Double(register) * perRegister)
            let upper = min(frame.bandLevels.count, Int(Double(register + 1) * perRegister))
            guard lower < upper else { continue }
            targets[register] = frame.bandLevels[lower..<upper].max() ?? 0
        }

        if registerLevels.count != registerCount {
            registerLevels = [Float](repeating: 0, count: registerCount)
        }
        // Heavier smoothing than the old per-band display: registers should
        // swell and settle, not twitch.
        let release = Float(exp(-elapsed / 0.28))
        for index in 0..<registerCount {
            registerLevels[index] = targets[index] >= registerLevels[index]
                ? targets[index]
                : registerLevels[index] * release
        }

        let colour = Self.hue(forBrightness: frame.brightness,
                              themeColor: themeColor, useTheme: useThemeColor)
        let columnsPerRegister = max(2, columnCount / registerCount)
        for register in 0..<registerCount {
            let start = register * columnsPerRegister
            let end = register == registerCount - 1
                ? columnCount
                : min(columnCount, start + columnsPerRegister)
            guard start < end else { continue }
            let height = Double(registerLevels[register])
            guard height > 0.02 else { continue }
            for index in start..<end {
                canvas.fillColumn(index, height: height) { row, rows in
                    let position = rows > 1 ? Double(row) / Double(rows - 1) : 1
                    return Self.rgb(colour, intensity: 0.35 + 0.65 * position)
                }
            }
        }
    }

    // MARK: - VU

    /// Loudness filling outward from the middle: the calmest mode, and the one
    /// that looks deliberate with any material at all.
    private func renderVU(_ frame: MusicalFrame, elapsed: Double, into canvas: inout Canvas) {
        let target = Double(frame.loudness)
        // Rise quickly, fall slowly — a meter's behaviour.
        let time = target > vuLevel ? 0.08 : 0.35
        vuLevel = target + (vuLevel - target) * Double(exp(-elapsed / time))

        let colour = Self.hue(forBrightness: frame.brightness,
                              themeColor: themeColor, useTheme: useThemeColor)
        let centre = Double(columnCount - 1) / 2
        // How far out from the middle the fill reaches.
        let reach = vuLevel * (Double(columnCount) / 2 + 1)

        for index in 0..<columnCount {
            let distance = abs(Double(index) - centre)
            guard distance <= reach else { continue }
            // Fade at the leading edge so the boundary is soft rather than a
            // hard step, and always at least two columns wide.
            let edge = min(1, (reach - distance) / 1.5)
            let level = min(1, 0.15 + 0.85 * edge * max(0.35, vuLevel))
            canvas.wholeColumn(index, Self.rgb(colour, intensity: level),
                               includePeak: distance <= reach - 1.5)
        }
    }
}
