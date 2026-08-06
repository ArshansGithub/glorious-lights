import Foundation
import GMMKProtocol

/// How the board interprets the music.
///
/// Identities are unchanged from the first design; what changed in r2 is that
/// every mode now rides the same three timescales. Each one **rides the SECTION
/// bed, swells with the PHRASE, punctuates with TRANSIENTS, and takes its colour
/// from the spatial hue field.** No mode paints a single global hue and no mode
/// owns a bed of its own — what a mode still owns is `shape(x,t)`, *where* the
/// bed sits on the board, and its gestures.
public enum VisualizerMode: String, CaseIterable, Sendable {
    /// The whole board breathes with the beat.
    case pulse
    /// Each beat launches a band of light travelling across the board.
    case wave
    /// Onsets fire rings from the register that made them.
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
        case .ripple:   return "Drum hits fire rings from their own register"
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

    /// Whether this mode schedules gestures on the beat grid, and so whether
    /// §2.3.3's schedule-to-land applies to it — and, correspondingly, whether
    /// M8 is a claim about it.
    public var isBeatScheduled: Bool { self == .pulse || self == .wave }
}

/// Turns one interpolated ``AnalysisState`` plus the onsets that have arrived
/// into a float canvas.
///
/// Owns the gesture population, the beat schedule and the colour field; owns no
/// timing of its own. Every call is `f(t)` for the caller's `t`.
public final class ModeRenderer {

    public var mode: VisualizerMode {
        didSet {
            guard mode != oldValue else { return }
            gestures = GestureList(capacity: max(1, mode.gestureCapacity))
            gestures.removeAll()
        }
    }
    public var themeColor: RGB
    /// Seat the desk look's colour into the field as its base hue instead of
    /// letting the hue drift.
    ///
    /// Note what this does **not** do: it does not collapse the board to one
    /// colour. P11 forbids any display element taking its hue from a single
    /// board-wide number, and a theme is a preference about *where* the palette
    /// sits, not a licence to delete the field.
    public var useThemeColor: Bool
    /// Display frame interval, for the ballistic clamps and the motion blur.
    public var frameInterval: Double

    /// `L̂` — the measured end-to-end latency the beat schedule lands against
    /// (§8.2-R). Written by the engine every frame from a live measurement;
    /// there is deliberately no constant here any more.
    public var latency: Double = 0

    private var gestures: GestureList
    private var colourField = ColourField()
    private var schedule = BeatSchedule()

    /// What the beat schedule actually did, for §10.5's open measurement gaps.
    public var beatTelemetry: (launches: Int, confirmations: Int, misses: Int,
                               credit: Double) {
        (schedule.launches, schedule.confirmations, schedule.misses,
         schedule.predictionCredit)
    }
    /// Beats counted since the session started, for bar-level phrasing.
    private var beatCount: Double = 0
    private var lastPhase: Double = 0
    private var waveDirection: Double = 1
    private var lastStructureChanges = 0
    /// The timestamp of the previous `render` call, so the beat window can be
    /// the time that actually elapsed rather than the nominal frame interval.
    private var lastRenderTime: Double?
    /// Measured elapsed time since the previous frame, seeded with the nominal
    /// interval for the first one.
    private var renderGap: Double = 1.0 / 30

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
        waveDirection = 1
        lastStructureChanges = 0
        colourField.reset()
        schedule.reset()
        lastRenderTime = nil
        renderGap = frameInterval
    }

    private var columnCount: Int { LinearCanvas.columnCount }

    /// What a mode contributes, in the vocabulary §11.4 composes in.
    ///
    /// A mode no longer decides how bright the board is. It decides *where* —
    /// `shape` for the resting bed, `accent` for its own fast field, `fill` for
    /// how much of a column that fast field occupies, `peak` for the marker row.
    /// The levels come from `bed + swell + headroom`, identically for all five.
    private struct Field {
        var shape: [Double]
        var accent: [Double]
        var fill: [Double]
        var peak: [Double]

        init(columns: Int) {
            shape = [Double](repeating: 1, count: columns)
            accent = [Double](repeating: 0, count: columns)
            fill = [Double](repeating: 1, count: columns)
            peak = [Double](repeating: 0, count: columns)
        }
    }

    /// Schedules gestures from this frame's events, then paints.
    public func render(state: AnalysisState, onsets: [OnsetEvent],
                       time: Double) -> LinearCanvas {
        // The window a beat has to fall inside is the gap since the *previous*
        // frame, not one nominal frame interval. P6 drops frames under transport
        // backpressure, so two `render` calls can be two or more frame intervals
        // apart.
        let previousFrame = lastRenderTime ?? (time - frameInterval)
        renderGap = max(time - previousFrame, 0)
        lastRenderTime = time

        trackBeats(state: state)
        schedule(state: state, onsets: onsets, previousFrame: previousFrame, time: time)
        gestures.prune(at: time)

        var field = Field(columns: columnCount)
        var deposits = [(column: Int, weight: Double, hue: Double)]()
        switch mode {
        case .pulse:    buildPulse(state, time: time, into: &field, deposits: &deposits)
        case .wave:     buildWave(state, time: time, into: &field, deposits: &deposits)
        case .ripple:   buildRipple(state, time: time, into: &field, deposits: &deposits)
        case .spectrum: buildSpectrum(state, time: time, into: &field, deposits: &deposits)
        case .vu:       buildVU(state, time: time, into: &field, deposits: &deposits)
        }

        var canvas = LinearCanvas()
        compose(field, state: state, into: &canvas)
        for deposit in deposits {
            colourField.deposit(column: deposit.column, weight: deposit.weight,
                                hue: deposit.hue)
        }
        // The field advances *after* the frame it described has been composed,
        // so a deposit is visible from the next frame onward — which is what
        // makes it a trail rather than a tint on the gesture's own pixels.
        let structureChanged = state.structureChanges > lastStructureChanges
        lastStructureChanges = state.structureChanges
        colourField.advance(brightness: state.brightness, spread: state.spread,
                            phrase: state.phrase, section: state.section,
                            structureChanged: structureChanged,
                            now: time, dt: renderGap)
        canvas.blur(sigma: 1.0)
        return canvas
    }

    /// §11.4 and §12, applied identically to every mode.
    private func compose(_ field: Field, state: AnalysisState,
                         into canvas: inout LinearCanvas) {
        let composition = state.composition
        let base = useThemeColor
            ? hueOfRGB(Double(themeColor.red) / 255, Double(themeColor.green) / 255,
                       Double(themeColor.blue) / 255)
            : nil
        for column in 0..<columnCount {
            let bedPart = composition.resting * clamp(field.shape[column], 0, 1)
            let accentPart = Composition.accentScale * composition.accentGain
                * clamp(field.accent[column], 0, 1) * composition.headroom
            let total = clamp(bedPart + accentPart, 0, 1) * (1 - composition.silenceRamp)
            guard total > 0 else { continue }
            let scale = total / max(bedPart + accentPart, 1e-12)
            let colour = hsvToRGB(hue: colourField.hue(column: column, base: base),
                                  saturation: colourField.saturation(column: column),
                                  value: 1)
            // The bed covers the **peak row** as well as the level rows. A
            // function-row key that is dark except when a gesture passes toggles
            // once per gesture, and M1 is a per-key metric whose p95 is decided
            // by exactly those keys. "The board is never at zero" is a claim
            // about the board, and the function row is part of it.
            canvas.addColumn(column, colour, level: bedPart * scale,
                             peak: bedPart * scale)
            let fill = clamp(field.fill[column], 0, 1)
            if fill >= 1 {
                // A gesture that covers the whole column lights it evenly; only
                // a *bar* has a bottom-weighted ramp, and applying that ramp to
                // the other four modes would dim the bottom of the board for no
                // reason a mode asked for.
                canvas.addColumn(column, colour, level: accentPart * scale)
            } else {
                canvas.fillColumn(column, height: fill, colour: colour,
                                  level: accentPart * scale)
            }
            let peak = clamp(field.peak[column], 0, 1) * total
            if peak > 0 { canvas.add(column: column, row: LinearCanvas.peakRow, colour, level: peak) }
        }
    }

    // MARK: - Beat tracking and scheduling

    /// Follows the published phase and notices when it wraps, which is a beat.
    private func trackBeats(state: AnalysisState) {
        guard state.tempo.bpm > 0 else { return }
        let phase = state.tempo.phase
        if phase < lastPhase { beatCount += 1 }
        lastPhase = phase
    }

    private func schedule(state: AnalysisState, onsets: [OnsetEvent],
                          previousFrame: Double, time: Double) {
        // Onsets are offered to the schedule **before** the schedule is
        // advanced, because advancing is what closes a beat's confirmation
        // window. A kick is detected about 40 ms after it happened and reaches
        // the renderer on the next frame, so on a 33 ms grid its delivery lands
        // 40–75 ms after the beat — close enough to the ±90 ms window that
        // resolving first turned roughly one beat in six on `edm-128` into a
        // miss, which the credit rule then punished twice over. Nothing about a
        // beat's *launch* is affected: a launch happens 50–80 ms before its beat
        // and its confirmation arrives after, so the two never contend for the
        // same frame.
        var consumed = Set<Int>()
        if mode.isBeatScheduled {
            for (index, onset) in onsets.enumerated() {
                // Every arbitrated onset confirms the grid; only the ones this
                // mode paints carry an amplitude and can be absorbed.
                let painted: Bool = mode == .pulse ? onset.kind != .hat : onset.kind == .kick
                let amplitude: Double? = !painted ? nil
                    : (mode == .pulse
                        ? pulseAmplitude(state, confidence: onset.confidence)
                            * (onset.kind == .kick ? 1.0 : 0.85)
                        : clamp(state.bassCurrentRelative / 2.0, 0.4, 1.0)
                            * (0.5 + 0.5 * onset.confidence))
                if schedule.offer(onset: onset, amplitude: amplitude) == .absorbed,
                   let amplitude {
                    gestures.absorb(kind: mode == .pulse ? .pulse : .wave,
                                    amplitude: amplitude)
                    consumed.insert(index)
                }
            }

            let envelope = mode == .pulse ? pulseEnvelope(state) : waveEnvelope()
            let kind: Gesture.Kind = mode == .pulse ? .pulse : .wave
            let carry = gestures.gestures.last { $0.kind == kind }?
                .integratedLevel(at: time, frameInterval: frameInterval) ?? 0
            if let launch = schedule.advance(
                state: state, latency: latency, envelope: envelope,
                frameInterval: frameInterval, carry: carry,
                previousFrame: previousFrame, now: time, grace: renderGap) {
                switch mode {
                case .pulse:
                    // §12.4: a beat-driven pulse is brightest at the **centroid
                    // column**, which moves with the music. A predicted gesture
                    // has no band of its own, and pinning it to the kick
                    // register would park the board's bright spot on one column
                    // for every beat of every four-to-the-floor track — the
                    // exact failure §12.4 exists to remove, just three columns
                    // to the left of where r1 put it.
                    triggerPulse(state: state, at: launch.startTime,
                                 amplitude: launch.amplitude,
                                 origin: colourField.centroidColumn, onsetKind: nil)
                case .wave:
                    triggerWave(state: state, at: launch.startTime,
                                amplitude: launch.amplitude)
                default: break
                }
            }
        }

        switch mode {
        case .pulse:
            // Kicks and snares, not hats. The arbiter has already reduced each
            // physical hit to one event, so a backbeat that arrives as a snare
            // is the same beat and dropping it leaves the board flat on every
            // bar whose kick the detector happened to lose. Hats stay out: they
            // subdivide, and a board breathing at the sixteenth is not
            // breathing.
            for (index, onset) in onsets.enumerated()
            where onset.kind != .hat && !consumed.contains(index) {
                let weight = onset.kind == .kick ? 1.0 : 0.85
                triggerPulse(state: state, at: onset.time,
                             amplitude: pulseAmplitude(state, confidence: onset.confidence)
                                 * weight,
                             origin: ColourField.originColumn(band: onset.band),
                             onsetKind: onset.kind)
            }

        case .wave:
            // Any kick the beat schedule did not consume launches a wave
            // reactively — including on a *confident* grid.
            //
            // r1 gated this on `gridWeight <= 0.5`, i.e. "if the grid is good,
            // waves come only from the grid". With §2.3.4's credit rule that
            // became a hole: a grid can be confident (the tempo is right) while
            // credit is below the launch threshold (the last beats were not
            // confirmed), and in that window the mode produced nothing at all.
            // Measured on `click-90-ramp`, 40 % of beats had no wave. There is
            // no double-fire risk: a beat that *was* predicted absorbs its own
            // confirming onset above, and §9.2's half-beat minimum age catches
            // the rest.
            for (index, onset) in onsets.enumerated()
            where onset.kind == .kick && !consumed.contains(index) {
                triggerWave(state: state, at: onset.time,
                            amplitude: clamp(state.bassCurrentRelative / 2.0, 0.4, 1.0)
                                * (0.5 + 0.5 * onset.confidence))
            }

        case .ripple:
            for onset in onsets { triggerRing(state: state, onset: onset) }

        case .spectrum:
            break   // envelope-driven; no gestures at all

        case .vu:
            // The VU body is an envelope; only the accents are gestures.
            for onset in onsets where onset.kind != .hat {
                let envelope = onset.kind.accentEnvelope(frameInterval: frameInterval)
                gestures.trigger(Gesture(kind: .pulse, startTime: onset.time,
                                         amplitude: clamp(0.4 + 0.6 * onset.confidence, 0, 1),
                                         origin: ColourField.originColumn(band: onset.band),
                                         onsetKind: onset.kind, envelope: envelope),
                                 at: onset.time)
            }
        }
    }

    private func pulseAmplitude(_ state: AnalysisState, confidence: Double) -> Double {
        clamp(state.bassCurrentRelative / 2.0, 0.35, 1.0) * (0.5 + 0.5 * clamp(confidence, 0, 1))
    }

    /// 35 ms rather than the accent's 15 ms. Pulse is the one gesture that
    /// changes every key at once, so its attack *is* the board's frame-to-frame
    /// difference; at 15 ms the whole display steps in a single frame and M2's
    /// smoothness ceiling is exceeded by 40 %.
    private func pulseEnvelope(_ state: AnalysisState) -> AHR {
        let release = clamp(0.35 * state.tempo.beatPeriod, 0.24, 0.8)
        return .clamped(attack: 0.035, hold: 0.100, release: release,
                        frameInterval: frameInterval)
    }

    private func waveEnvelope() -> AHR {
        .clamped(attack: 0.015, hold: 0.100, release: 0.320, frameInterval: frameInterval)
    }

    /// The outgoing gesture's level at `time`, so a replacement inherits the
    /// tail it would otherwise discard (``Gesture/carry``).
    private func carry(_ kind: Gesture.Kind, at time: Double) -> Double {
        gestures.gestures.last { $0.kind == kind }?.level(at: time) ?? 0
    }

    private func triggerPulse(state: AnalysisState, at time: Double, amplitude: Double,
                              origin: Double, onsetKind: OnsetKind?) {
        gestures.trigger(Gesture(kind: .pulse, startTime: time, amplitude: amplitude,
                                 origin: origin,
                                 onsetKind: onsetKind,
                                 carry: min(carry(.pulse, at: time), amplitude * 0.9),
                                 envelope: pulseEnvelope(state)),
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
        // The wave starts **at the edge column**, not three columns outside it.
        // r1 launched it off-board so it could slide in, which puts the board's
        // response to a beat about 60 ms after the gesture's own envelope —
        // a spatial transit delay §2.3.3 has no way to know about, and it showed
        // up as a uniform +25 ms of M8 bias in wave and in no other mode. With
        // σ = 2.8 and §6.2's blur the difference is not visible; the sweep still
        // reads as entering from the side.
        gestures.trigger(Gesture(kind: .wave, startTime: time, amplitude: amplitude,
                                 origin: direction > 0 ? 0 : Double(columnCount - 1),
                                 direction: direction, speed: speed, width: 2.8,
                                 envelope: waveEnvelope()),
                         at: time, minimumAge: period * 0.5)
    }

    /// §12.4: origins come from the register that fired, never from the centre.
    ///
    /// r1's "kick = centre, snare = ±4, hat = ±7" scheme put **every kick** — the
    /// most frequent event on almost any material — at exactly the centre column.
    /// That one line is the largest single contributor to "the colour is
    /// concentrated in the centre".
    private func triggerRing(state: AnalysisState, onset: OnsetEvent) {
        let origin = ColourField.originColumn(band: onset.band)
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

    // MARK: - The five fields

    /// How far the resting bed tilts toward the centroid column (§12.4). r1's
    /// fixed 12 % falloff from column 8 is deleted: this crest *moves*.
    private static let bedTilt: Double = 0.25
    /// The pulse gesture's own crest. Wide enough that the whole board still
    /// breathes, narrow enough that where the register lives is legible — which
    /// is the entire point of §12.4.
    private static let pulseCrestSigma: Double = 3.0
    private static let pulsePedestal: Double = 0.40

    private func bedShape(_ state: AnalysisState) -> [Double] {
        let centre = colourField.centroidColumn
        let width = Double(max(columnCount - 1, 1))
        return (0..<columnCount).map { column in
            1 - Self.bedTilt * abs(Double(column) - centre) / width
        }
    }

    private func buildPulse(_ state: AnalysisState, time: Double, into field: inout Field,
                            deposits: inout [(column: Int, weight: Double, hue: Double)]) {
        field.shape = bedShape(state)
        guard let gesture = gestures.gestures.first(where: { $0.kind == .pulse }) else { return }
        let level = gesture.integratedLevel(at: time, frameInterval: frameInterval)
        guard level > 0.001 else { return }
        let hue = ColourField.depositHue(for: gesture.onsetKind)
        let sigma = Self.pulseCrestSigma
        for column in 0..<columnCount {
            let distance = Double(column) - gesture.origin
            let crest = Self.pulsePedestal + (1 - Self.pulsePedestal)
                * exp(-(distance * distance) / (2 * sigma * sigma))
            field.accent[column] = level * crest
            field.peak[column] = 0.55 * level * crest
            deposits.append((column, level * crest * renderGap / ColourField.depositTime, hue))
        }
    }

    private func buildWave(_ state: AnalysisState, time: Double, into field: inout Field,
                           deposits: inout [(column: Int, weight: Double, hue: Double)]) {
        field.shape = bedShape(state)
        for gesture in gestures.gestures where gesture.kind == .wave {
            let level = gesture.integratedLevel(at: time, frameInterval: frameInterval)
            guard level > 0.001 else { continue }
            let position = gesture.position(at: time)
            let width = gesture.effectiveWidth(frameInterval: frameInterval)
            let hue = ColourField.depositHue(for: gesture.onsetKind)
            for column in 0..<columnCount {
                let distance = Double(column) - position
                let falloff = exp(-(distance * distance) / (2 * width * width))
                guard falloff > 0.01 else { continue }
                field.accent[column] += level * falloff
                field.peak[column] = max(field.peak[column],
                                         level * falloff * smoothstep(0.4, 0.7, falloff))
                deposits.append((column, level * falloff * renderGap / ColourField.depositTime,
                                 hue))
            }
        }
    }

    private func buildRipple(_ state: AnalysisState, time: Double, into field: inout Field,
                             deposits: inout [(column: Int, weight: Double, hue: Double)]) {
        field.shape = bedShape(state)
        for gesture in gestures.gestures where gesture.kind == .ring {
            let level = gesture.integratedLevel(at: time, frameInterval: frameInterval)
            guard level > 0.001 else { continue }
            let radius = gesture.speed * max(0, time - gesture.startTime)
            let width = gesture.effectiveWidth(frameInterval: frameInterval)
            let hue = ColourField.depositHue(for: gesture.onsetKind)
            for column in 0..<columnCount {
                // A shell: both arms of the ring, so the shape is symmetric
                // about its origin.
                let distance = abs(abs(Double(column) - gesture.origin) - radius)
                let falloff = exp(-(distance * distance) / (2 * width * width))
                guard falloff > 0.01 else { continue }
                field.accent[column] += level * falloff
                field.peak[column] = max(field.peak[column],
                                         level * falloff * smoothstep(0.5, 0.8, falloff))
                deposits.append((column, level * falloff * renderGap / ColourField.depositTime,
                                 hue))
            }
        }
    }

    private func buildSpectrum(_ state: AnalysisState, time: Double, into field: inout Field,
                               deposits: inout [(column: Int, weight: Double, hue: Double)]) {
        let perRegister = Double(columnCount) / Double(AnalysisState.registerCount)
        for register in 0..<AnalysisState.registerCount {
            let start = Int((Double(register) * perRegister).rounded())
            let end = register == AnalysisState.registerCount - 1
                ? columnCount
                : Int((Double(register + 1) * perRegister).rounded())
            guard start < end else { continue }
            let height = clamp(state.register(register), 0, 1)
            let peak = clamp(state.registerPeak(register), 0, 1)
            // The register's own hue offset is its position in the register
            // order, so a bar deposits the colour of the register it belongs to.
            let hue = ColourField.depositLimit * (Double(register)
                / Double(AnalysisState.registerCount - 1) - 0.5)
            for column in start..<end {
                field.accent[column] = height
                field.fill[column] = height
                // The peak marker's brightness is a smoothstep of how high the
                // marker sits, not a boolean — a hard-thresholded function-row
                // key flipping on and off is a directly observable flicker
                // source.
                field.peak[column] = smoothstep(0.15, 0.45, peak) * peak
                deposits.append((column, height * renderGap / ColourField.depositTime, hue))
            }
        }
    }

    /// §9.5's identity is deliberately preserved — VU stays a centre-out meter —
    /// but §12.4 makes it **asymmetric**: the left arm is driven by the low
    /// registers and the right by the high, so the meter is symmetric only when
    /// the spectrum is, and its brightness centre of mass moves whenever the
    /// material is tilted.
    private func buildVU(_ state: AnalysisState, time: Double, into field: inout Field,
                         deposits: inout [(column: Int, weight: Double, hue: Double)]) {
        let centre = Double(columnCount - 1) / 2
        let level = clamp(state.vu, 0, 1)
        var low = 0.0, high = 0.0
        for band in 0..<4 { low += state.norm(band) * state.gate(band) }
        for band in 4..<AnalysisState.bandCount { high += state.norm(band) * state.gate(band) }
        low /= 4
        high /= Double(AnalysisState.bandCount - 4)

        let accents = gestures.gestures.filter { $0.kind == .pulse }
        let kick = accents.filter { $0.onsetKind == .kick }
            .map { $0.integratedLevel(at: time, frameInterval: frameInterval) }.max() ?? 0
        let snare = accents.filter { $0.onsetKind == .snare }
            .map { $0.integratedLevel(at: time, frameInterval: frameInterval) }.max() ?? 0

        let reachLow = clamp(0.25 + 0.75 * low + 0.6 * kick, 0, 1) * centre
        let reachHigh = clamp(0.25 + 0.75 * high + 0.6 * snare, 0, 1) * centre
        for column in 0..<columnCount {
            let distance = Double(column) - centre
            let reach = distance <= 0 ? reachLow : reachHigh
            // Smoothstep over ±1 column instead of a `distance <= reach` cliff.
            let edge = smoothstep(reach + 1, reach - 1, abs(distance))
            // The meter's arms are the mode's geometry, and the bed keeps the
            // columns the meter has not reached alive — a meter whose unlit
            // columns are black turns its own swing into a per-key on→off→on
            // cycle at the beat rate.
            field.shape[column] = 0.45 + 0.55 * edge
            var value = (0.10 + 0.55 * level) * edge
            if abs(distance) <= 1.5 { value += kick * 0.5 }
            if abs(abs(distance) - reach) < 1.2 { value += snare * 0.5 }
            field.accent[column] = clamp(value, 0, 1)
            field.peak[column] = smoothstep(reach + 0.5, reach - 0.5, abs(distance))
                * smoothstep(0.05, 0.25, level)
            let hue = distance <= 0
                ? ColourField.depositHue(for: .kick) : ColourField.depositHue(for: .hat)
            deposits.append((column, field.accent[column] * edge * renderGap
                             / ColourField.depositTime, hue))
        }
    }
}
