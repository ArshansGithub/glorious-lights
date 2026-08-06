import Foundation
import GMMKProtocol

/// How the board interprets the music.
///
/// Identities are unchanged from the first design; what changed is that each
/// mode is now a *gesture schedule plus an envelope field* over one common
/// foundation, with an explicit lifecycle and no re-triggering mid-gesture.
public enum VisualizerMode: String, CaseIterable, Sendable {
    /// The whole board breathes with the beat.
    case pulse
    /// Each beat launches a band of light travelling across the board.
    case wave
    /// Onsets fire rings expanding from the centre.
    case ripple
    /// Bars, grouped into musical registers.
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

    /// Hard cap on simultaneous gestures (§5.3). Overlapping gestures average
    /// out to a uniform glow, which is the opposite of responding to detail.
    public var gestureCapacity: Int {
        switch self {
        case .pulse:    return 1      // the board *is* the gesture
        case .wave:     return 2
        case .ripple:   return 3
        case .spectrum: return 0      // pure envelope field
        case .vu:       return 3      // the body, plus a kick and a snare accent
        }
    }
}

/// Turns one interpolated ``AnalysisState`` plus the onsets that have arrived
/// into a float canvas.
///
/// Owns the gesture population and the beat schedule; owns no timing of its own.
/// Every call is `f(t)` for the caller's `t`.
public final class ModeRenderer {

    public var mode: VisualizerMode {
        didSet {
            guard mode != oldValue else { return }
            gestures = GestureList(capacity: max(1, mode.gestureCapacity))
            gestures.removeAll()
        }
    }
    public var themeColor: RGB
    /// Paint in the desk look's colour instead of the brightness ramp.
    public var useThemeColor: Bool
    /// Display frame interval, for the ballistic clamps and the motion blur.
    public var frameInterval: Double

    private var gestures: GestureList
    /// Beats counted since the session started, for bar-level phrasing.
    private var beatCount: Double = 0
    private var lastPhase: Double = 0
    private var lastBeatTime: Double = -.infinity
    private var waveDirection: Double = 1
    private var rippleSide: [OnsetKind: Double] = [.snare: 1, .hat: 1]
    /// Measured analysis-to-photon latency used to schedule beat-locked gestures
    /// early (§8.2). Conservative: a wrong prediction that is early by a frame
    /// is far less visible than one that is late.
    public var predictionLead: Double = 0.040

    public init(mode: VisualizerMode = .pulse,
                themeColor: RGB = RGB(red: 0x00, green: 0xCC, blue: 0xAA),
                useThemeColor: Bool = false,
                frameInterval: Double = 1.0 / 30) {
        self.mode = mode
        self.themeColor = themeColor
        self.useThemeColor = useThemeColor
        self.frameInterval = frameInterval
        self.gestures = GestureList(capacity: max(1, mode.gestureCapacity))
    }

    public func reset() {
        gestures.removeAll()
        beatCount = 0
        lastPhase = 0
        lastBeatTime = -.infinity
        waveDirection = 1
    }

    private var columnCount: Int { LinearCanvas.columnCount }

    /// Schedules gestures from this frame's events, then paints.
    public func render(state: AnalysisState, onsets: [OnsetEvent],
                       time: Double) -> LinearCanvas {
        trackBeats(state: state, time: time)
        schedule(state: state, onsets: onsets, time: time)
        gestures.prune(at: time)

        var canvas = LinearCanvas()
        switch mode {
        case .pulse:    paintPulse(state, time: time, into: &canvas)
        case .wave:     paintWave(state, time: time, into: &canvas)
        case .ripple:   paintRipple(state, time: time, into: &canvas)
        case .spectrum: paintSpectrum(state, time: time, into: &canvas)
        case .vu:       paintVU(state, time: time, into: &canvas)
        }
        canvas.blur(sigma: 1.0)
        return canvas
    }

    // MARK: - Beat tracking

    /// Follows the published phase and notices when it wraps, which is a beat.
    private func trackBeats(state: AnalysisState, time: Double) {
        guard state.tempo.bpm > 0 else { return }
        let phase = state.tempo.phase
        if phase < lastPhase { beatCount += 1 }
        lastPhase = phase
    }

    /// Whether a beat is due within the prediction lead — the mechanism that
    /// makes beat-locked gestures land with zero visible latency.
    private func beatIsDue(state: AnalysisState, time: Double) -> Bool {
        guard state.tempo.confidence >= TempoEstimate.usableConfidence,
              state.tempo.bpm > 0 else { return false }
        let period = state.tempo.beatPeriod
        let untilBeat = (1 - state.tempo.phase) * period
        let lead = state.tempo.confidence >= TempoEstimate.predictiveConfidence
            ? predictionLead : 0
        guard untilBeat <= lead + frameInterval else { return false }
        guard time - lastBeatTime >= period * 0.5 else { return false }
        lastBeatTime = time
        return true
    }

    // MARK: - Scheduling

    private func schedule(state: AnalysisState, onsets: [OnsetEvent], time: Double) {
        switch mode {
        case .pulse:
            // Kicks and snares, not hats. The design names the kick, and the
            // kick is what the board should breathe with — but the arbiter has
            // already reduced each physical hit to one event, so a backbeat that
            // arrives as a snare is the same beat, and dropping it leaves the
            // board flat on every bar whose kick the detector happened to lose.
            // Hats stay out: they subdivide, and a board breathing at the
            // sixteenth is not breathing.
            for onset in onsets where onset.kind != .hat {
                let weight = onset.kind == .kick ? 1.0 : 0.85
                triggerPulse(state: state, at: onset.time,
                             amplitude: pulseAmplitude(state, confidence: onset.confidence)
                                 * weight)
            }
            if beatIsDue(state: state, time: time) {
                triggerPulse(state: state, at: time,
                             amplitude: pulseAmplitude(state, confidence: state.tempo.confidence))
            }

        case .wave:
            let launch: [(Double, Double)]
            if state.tempo.gridWeight > 0.5 {
                launch = beatIsDue(state: state, time: time)
                    ? [(time, clamp(state.bassCurrentRelative / 2.0, 0.4, 1.0))] : []
            } else {
                launch = onsets.filter { $0.kind == .kick }
                    .map { ($0.time, clamp(state.bassCurrentRelative / 2.0, 0.4, 1.0)
                            * (0.5 + 0.5 * $0.confidence)) }
            }
            for (start, amplitude) in launch { triggerWave(state: state, at: start, amplitude: amplitude) }

        case .ripple:
            for onset in onsets { triggerRing(state: state, onset: onset) }

        case .spectrum:
            break   // envelope-driven; no gestures at all

        case .vu:
            // The VU body is an envelope; only the kick accent is a gesture, and
            // it is capped at one.
            for onset in onsets where onset.kind != .hat {
                let envelope = onset.kind.accentEnvelope(frameInterval: frameInterval)
                gestures.trigger(Gesture(kind: .pulse, startTime: onset.time,
                                         amplitude: clamp(0.4 + 0.6 * onset.confidence, 0, 1),
                                         onsetKind: onset.kind, envelope: envelope),
                                 at: onset.time)
            }
        }
    }

    private func pulseAmplitude(_ state: AnalysisState, confidence: Double) -> Double {
        clamp(state.bassCurrentRelative / 2.0, 0.35, 1.0) * (0.5 + 0.5 * clamp(confidence, 0, 1))
    }

    private func triggerPulse(state: AnalysisState, at time: Double, amplitude: Double) {
        // Release is musical: 0.35 of a beat, clamped so it is never faster than
        // the display can render and never so slow it smears two beats together.
        let release = clamp(0.35 * state.tempo.beatPeriod, 0.24, 0.8)
        // 35 ms rather than the accent's 15 ms. Pulse is the one gesture that
        // changes every key at once, so its attack *is* the board's
        // frame-to-frame difference; at 15 ms the whole display steps in a
        // single frame and the smoothness ceiling is exceeded by 40 %. Still
        // barely more than one frame, so it still reads as instant.
        let envelope = AHR.clamped(attack: 0.035, hold: 0.100, release: release,
                                   frameInterval: frameInterval)
        gestures.trigger(Gesture(kind: .pulse, startTime: time, amplitude: amplitude,
                                 envelope: envelope),
                         at: time)
    }

    private func triggerWave(state: AnalysisState, at time: Double, amplitude: Double) {
        let period = state.tempo.beatPeriod
        let sweep = musicalDuration(beats: 0.75, beatPeriod: period)
        let speed = clampedSpeed(Double(columnCount) / sweep, frameInterval: frameInterval)
        // Direction alternates per **bar**, not per trigger: per-trigger
        // alternation is not musical, and at high trigger rates it reads as
        // random rather than as a sweep.
        let direction: Double = Int(beatCount / 4) % 2 == 0 ? 1 : -1
        waveDirection = direction
        let envelope = AHR.clamped(attack: 0.015, hold: 0.100, release: 0.320,
                                   frameInterval: frameInterval)
        gestures.trigger(Gesture(kind: .wave, startTime: time, amplitude: amplitude,
                                 origin: direction > 0 ? -3 : Double(columnCount) + 2,
                                 direction: direction, speed: speed, width: 2.8,
                                 envelope: envelope),
                         at: time, minimumAge: period * 0.5)
    }

    private func triggerRing(state: AnalysisState, onset: OnsetEvent) {
        let centre = Double(columnCount - 1) / 2
        let origin: Double
        switch onset.kind {
        case .kick:
            origin = centre
        case .snare:
            origin = centre + 4 * (rippleSide[.snare] ?? 1)
            rippleSide[.snare] = -(rippleSide[.snare] ?? 1)
        case .hat:
            origin = centre + 7 * (rippleSide[.hat] ?? 1)
            rippleSide[.hat] = -(rippleSide[.hat] ?? 1)
        }
        let baseSpeed: Double
        switch onset.kind {
        case .kick:  baseSpeed = 9
        case .snare: baseSpeed = 14
        case .hat:   baseSpeed = 18
        }
        var envelope = onset.kind.accentEnvelope(frameInterval: frameInterval)
        // A ring lives at most 1.2 beats, so at 174 BPM rings do not pile up.
        let lifetime = min(1.2 * state.tempo.beatPeriod, 0.9)
        envelope.release = max(envelope.release, min(lifetime / 3, 0.4))
        gestures.trigger(Gesture(kind: .ring, startTime: onset.time,
                                 amplitude: clamp(0.4 + 0.6 * onset.confidence, 0, 1),
                                 origin: origin, direction: 1,
                                 speed: clampedSpeed(baseSpeed, frameInterval: frameInterval),
                                 width: 1.6, onsetKind: onset.kind,
                                 envelope: envelope),
                         at: onset.time)
    }

    // MARK: - Painting

    /// One gesture, one colour: the theme colour, or the brightness ramp, with a
    /// per-kind hue offset bounded to ±0.08 so the board never turns into
    /// rainbow vomit.
    private func colour(for state: AnalysisState, kind: OnsetKind? = nil)
        -> (r: Double, g: Double, b: Double) {
        var base = Self.hue(forBrightness: Float(state.brightness),
                            themeColor: themeColor, useTheme: useThemeColor)
        if let kind {
            let offset: Double
            switch kind {
            case .kick:  offset = -0.08     // warm
            case .snare: offset = 0
            case .hat:   offset = 0.08      // cool
            }
            base = Self.shiftHue(base, by: offset)
        }
        return base
    }

    /// A mode's resting wash: the level the board sits at when nothing is
    /// happening.
    ///
    /// Every mode specifies one ("the board is never dark", "the breath, not
    /// black"), and its whole purpose is that keys stay lit between gestures. A
    /// wash below the interlock's own rise threshold does the opposite — the
    /// board goes dark between gestures and every gesture becomes an on→off→on
    /// cycle for every key it touches, which is the flicker the user reported.
    /// So the wash is defined as *clearing that threshold*, and faded out only
    /// by genuine silence.
    private func wash(_ designed: Double) -> Double {
        // 1.5× the rise threshold, not 1.15×: what reaches a key is the wash
        // *after* the peak row's 0.85 weighting, the centre-to-edge shaping and
        // the spatial blur, and a wash that only just clears the threshold in
        // the canvas arrives at some keys just under it — where they chatter
        // across it once per gesture.
        max(designed, KeyHold.riseThreshold * 1.5)
    }

    private func paintPulse(_ state: AnalysisState, time: Double, into canvas: inout LinearCanvas) {
        let gesture = gestures.gestures.first { $0.kind == .pulse }
        let hit = gesture?.integratedLevel(at: time, frameInterval: frameInterval) ?? 0
        // The "breath": between beats the board sits at a live, level-following
        // glow rather than decaying to black. This is the direct fix for "the
        // lights don't properly stay on".
        // The breath follows the body of the music as well as its relative
        // level: on sustained material — a string swell, a held chord — the
        // relative value sits at 1.0 by construction and only the body envelope
        // has anything to say about how much is going on.
        let floor = wash(clamp(0.18 * state.overallAverageRelative + 0.25 * state.body,
                               0, 0.45))
        // The hit rides *on top of* the breath rather than replacing it. Taking
        // the maximum means a quiet passage's gestures are swallowed by the same
        // floor that is meant to keep the board alive — on a crescendo the
        // floor rises with the music and the hits disappear into it exactly as
        // the music gets more interesting. Capped below full so a board-wide
        // gesture always has somewhere left to go.
        let level = clamp(floor + hit * 0.85 * (1 - floor), 0, 1)
        guard level > 0 else { return }
        let colour = colour(for: state)
        let centre = Double(columnCount - 1) / 2
        for column in 0..<columnCount {
            // Falls off ~12 % from centre to edge, so the board has shape rather
            // than being a flat flash.
            let shape = 1 - 0.12 * abs(Double(column) - centre) / centre
            canvas.addColumn(column, colour, level: level * shape,
                             peak: level * shape * 0.85)
        }
    }

    private func paintWave(_ state: AnalysisState, time: Double, into canvas: inout LinearCanvas) {
        let colour = colour(for: state)
        let bed = wash(clamp(0.15 * state.midAverageRelative, 0, 0.35))
        // The wash covers the peak row as well. A function-row key that is
        // dark except when a gesture passes toggles once per gesture, and M1
        // is a per-key metric — its p95 is decided by exactly these keys.
        for column in 0..<columnCount {
            canvas.addColumn(column, colour, level: bed, peak: bed)
        }

        for gesture in gestures.gestures where gesture.kind == .wave {
            let level = gesture.integratedLevel(at: time, frameInterval: frameInterval)
            guard level > 0.001 else { continue }
            let position = gesture.position(at: time)
            let width = gesture.effectiveWidth(frameInterval: frameInterval)
            for column in 0..<columnCount {
                let distance = Double(column) - position
                let falloff = exp(-(distance * distance) / (2 * width * width))
                guard falloff > 0.01 else { continue }
                canvas.addColumn(column, colour, level: level * falloff,
                                 peak: level * falloff * smoothstep(0.4, 0.7, falloff))
            }
        }
    }

    private func paintRipple(_ state: AnalysisState, time: Double, into canvas: inout LinearCanvas) {
        let bedColour = colour(for: state)
        let bed = wash(clamp(0.12 * state.overallAverageRelative, 0, 0.30))
        for column in 0..<columnCount {
            canvas.addColumn(column, bedColour, level: bed, peak: bed)
        }

        for gesture in gestures.gestures where gesture.kind == .ring {
            let level = gesture.integratedLevel(at: time, frameInterval: frameInterval)
            guard level > 0.001 else { continue }
            let radius = gesture.speed * max(0, time - gesture.startTime)
            let width = gesture.effectiveWidth(frameInterval: frameInterval)
            let colour = colour(for: state, kind: gesture.onsetKind)
            for column in 0..<columnCount {
                // A shell: both arms of the ring, so the shape is symmetric
                // about its origin.
                let distance = abs(abs(Double(column) - gesture.origin) - radius)
                let falloff = exp(-(distance * distance) / (2 * width * width))
                guard falloff > 0.01 else { continue }
                canvas.addColumn(column, colour, level: level * falloff,
                                 peak: level * falloff * smoothstep(0.5, 0.8, falloff))
            }
        }
    }

    private func paintSpectrum(_ state: AnalysisState, time: Double,
                               into canvas: inout LinearCanvas) {
        let colour = colour(for: state)
        let perRegister = Double(columnCount) / Double(AnalysisState.registerCount)
        for register in 0..<AnalysisState.registerCount {
            let start = Int((Double(register) * perRegister).rounded())
            let end = register == AnalysisState.registerCount - 1
                ? columnCount
                : Int((Double(register + 1) * perRegister).rounded())
            guard start < end else { continue }
            let height = clamp(state.register(register), 0, 1)
            let peak = clamp(state.registerPeak(register), 0, 1)
            let bed = wash(0)
            for column in start..<end {
                canvas.addColumn(column, colour, level: bed, peak: bed)
                canvas.fillColumn(column, height: height, colour: colour)
                // The peak marker's brightness is a smoothstep of how high the
                // marker sits, not a boolean — a hard-thresholded function-row
                // key flipping on and off is a directly observable flicker
                // source.
                canvas.add(column: column, row: LinearCanvas.peakRow, colour,
                           level: smoothstep(0.15, 0.45, peak) * peak)
            }
        }
    }

    private func paintVU(_ state: AnalysisState, time: Double, into canvas: inout LinearCanvas) {
        let colour = colour(for: state)
        let centre = Double(columnCount - 1) / 2
        let level = clamp(state.vu, 0, 1)
        let accent = gestures.gestures.filter { $0.onsetKind == .kick }
            .map { $0.integratedLevel(at: time, frameInterval: frameInterval) }.max() ?? 0
        let snareAccent = gestures.gestures.filter { $0.onsetKind == .snare }
            .map { $0.integratedLevel(at: time, frameInterval: frameInterval) }.max() ?? 0

        // The meter *swings* on a kick rather than only brightening: a needle
        // moving out is the gesture people read a VU by, and confining the
        // accent to three columns of an already-lit centre changes almost
        // nothing on a board this small.
        let reach = clamp(level + 0.6 * accent, 0, 1) * 8.5

        let bed = wash(0)
        for column in 0..<columnCount {
            let distance = abs(Double(column) - centre)
            // Smoothstep over ±1 column instead of a `distance <= reach` cliff.
            let edge = smoothstep(reach + 1, reach - 1, distance)
            // Every column keeps the wash, including the ones the meter has not
            // reached: a meter whose unlit columns are black turns its own
            // swing into a per-key on→off→on cycle at the beat rate.
            // The accent lifts the whole lit body as well as the inner columns:
            // a meter jumps, it does not only glow in the middle.
            // The body deliberately leaves headroom for the accent. A meter
            // whose steady state is already near full has nowhere to jump to,
            // and the jump is the part that reads as musical.
            var value = bed + (0.10 + 0.55 * level) * edge + 0.45 * accent * edge
            // A kick brightens the inner three columns; a snare tips the
            // outermost lit column. Two accents, per §9.5.
            if distance <= 1.5 { value += accent * 0.7 }
            if abs(distance - reach) < 1.2 { value += snareAccent * 0.5 }
            canvas.addColumn(column, colour, level: clamp(value, 0, 1),
                             // PPM marker: fast attack, slow decay, continuous,
                             // over the same wash the body sits on.
                             peak: max(wash(0),
                                       smoothstep(reach + 0.5, reach - 0.5, distance)
                                           * smoothstep(0.05, 0.25, level)))
        }
    }

    // MARK: - Colour

    /// The shared colour ramp: warm for bass-heavy passages through to a bright
    /// blue-white for treble-rich ones — the synaesthetic mapping people already
    /// expect.
    public static func hue(forBrightness brightness: Float, themeColor: RGB,
                           useTheme: Bool) -> (r: Double, g: Double, b: Double) {
        if useTheme {
            return (Double(themeColor.red) / 255,
                    Double(themeColor.green) / 255,
                    Double(themeColor.blue) / 255)
        }
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (1.00, 0.05, 0.02)),
            (0.18, (1.00, 0.35, 0.00)),
            (0.36, (1.00, 0.80, 0.05)),
            (0.54, (0.35, 1.00, 0.15)),
            (0.72, (0.00, 0.95, 0.75)),
            (0.88, (0.10, 0.65, 1.00)),
            (1.00, (0.65, 0.80, 1.00)),
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

    /// Rotates a colour's hue by a fraction of the wheel, keeping saturation and
    /// value. Used only for the ±0.08 per-drum variation.
    static func shiftHue(_ colour: (r: Double, g: Double, b: Double), by offset: Double)
        -> (r: Double, g: Double, b: Double) {
        let maximum = max(colour.r, max(colour.g, colour.b))
        let minimum = min(colour.r, min(colour.g, colour.b))
        let delta = maximum - minimum
        guard delta > 1e-6, maximum > 1e-6 else { return colour }
        var hue: Double
        if maximum == colour.r {
            hue = ((colour.g - colour.b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == colour.g {
            hue = (colour.b - colour.r) / delta + 2
        } else {
            hue = (colour.r - colour.g) / delta + 4
        }
        hue = (hue / 6 + offset).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }

        let saturation = delta / maximum
        let sector = hue * 6
        let index = Int(sector) % 6
        let f = sector - Double(Int(sector))
        let p = maximum * (1 - saturation)
        let q = maximum * (1 - saturation * f)
        let t = maximum * (1 - saturation * (1 - f))
        switch index {
        case 0:  return (maximum, t, p)
        case 1:  return (q, maximum, p)
        case 2:  return (p, maximum, t)
        case 3:  return (p, q, maximum)
        case 4:  return (t, p, maximum)
        default: return (maximum, p, q)
        }
    }
}
