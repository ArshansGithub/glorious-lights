import Foundation

/// The spatial hue field (§12): the answer to *"the colour is concentrated in
/// the centre and isn't diverse / well propagated."*
///
/// r1 had exactly one colour decision per frame — `state.brightness`, the
/// percentile-normalised spectral centroid, mapped through a seven-stop ramp,
/// for all 126 LEDs — plus a ±0.08 per-drum offset on ripple rings. That was the
/// entire colour model. P11 makes it a field:
///
/// ```
/// H(x,t) = wrap01( H0(t) + A(t)·G(x,t) + C(x,t) )
/// ```
///
/// The headline move is in `G`: **the spectral centroid stops being the board's
/// colour and becomes the position of the colour boundary.** Bass-register
/// columns read warm, treble-register columns cool, and the crossover moves with
/// the music instead of the whole board sliding along a ramp together.
public struct ColourField: Sendable {

    // MARK: - Constants (§12, Appendix A)

    /// Base-hue drift, turns per second, scaled by `(0.25 + 0.75·Σ)`: a full
    /// wheel in three minutes at full section energy, twelve at rest. **`H0`
    /// never moves per frame and never randomly** — the drift rate is tied to
    /// `Σ`, and the jumps to structure.
    public static let driftRate: Double = 1.0 / 180
    /// A §11.3 novelty event advances `H0` by this much, eased over
    /// ``structureKickSeconds``. A new section visibly changes the palette.
    public static let structureKick: Double = 0.11
    public static let structureKickSeconds: Double = 2.0

    /// Full fan of the register gradient, in turns, at full spectral spread.
    public static let gradientAmplitude: Double = 0.30
    /// The fan opens and closes on the PHRASE timescale, not per frame.
    public static let gradientAttack: Double = 0.050
    public static let gradientRelease: Double = 0.800

    /// Saturation floor and span (§12.2). Recently-struck columns are more
    /// saturated; the untouched bed is a paler tint of the same hue.
    public static let saturationFloor: Double = 0.45
    public static let saturationSpan: Double = 0.55

    /// The colour trail (§12.3) — what makes motion legible as colour and not
    /// only as brightness.
    public static let trailTime: Double = 0.900
    public static let saturationTrailTime: Double = 0.600
    public static let depositTime: Double = 0.120
    /// A single gesture may tint the board by at most this much — r1's blanket
    /// ±0.08 rule survives here, as a per-*gesture* deposit limit rather than a
    /// bound on the board.
    public static let depositLimit: Double = 0.08
    /// …and the accumulated trail by at most this. Together they keep the field
    /// inside "a tinted board" rather than "rainbow vomit"; M10a's upper guard
    /// is what enforces it rather than asserting it.
    public static let trailLimit: Double = 0.18

    // MARK: - State

    private var baseHue: Double = 0.30
    private var kickRemaining: Double = 0
    private var gradient = AHR(attack: ColourField.gradientAttack, hold: 0,
                               release: ColourField.gradientRelease)
    private var trail: [Double]
    private var saturationTrail: [Double]
    private var pendingHue: [Double]
    private var pendingWeight: [Double]

    public let columnCount: Int

    public init(columnCount: Int = LinearCanvas.columnCount) {
        self.columnCount = columnCount
        trail = [Double](repeating: 0, count: columnCount)
        saturationTrail = [Double](repeating: 0, count: columnCount)
        pendingHue = [Double](repeating: 0, count: columnCount)
        pendingWeight = [Double](repeating: 0, count: columnCount)
    }

    /// The centroid column — where the warm/cool boundary sits this frame.
    public private(set) var centroidColumn: Double = 0
    /// `A(t)`, the smoothed gradient amplitude in turns.
    public var gradientTurns: Double { gradient.value }
    /// `Φ`, kept for the saturation term.
    private var phrase: Double = 0

    /// Advances the field one frame: drift, structure kick, gradient, and the
    /// trail decay. Deposits made since the last call are folded in first.
    public mutating func advance(brightness: Double, spread: Double,
                                 phrase: Double, section: Double,
                                 structureChanged: Bool,
                                 now: Double, dt: Double) {
        let step = max(dt, 0)
        self.phrase = clamp(phrase, 0, 1)

        // Drift, then the eased structure kick on top of it.
        baseHue += Self.driftRate * (0.25 + 0.75 * clamp(section, 0, 1)) * step
        if structureChanged { kickRemaining = Self.structureKick }
        if kickRemaining > 0 {
            let advance = min(kickRemaining,
                              Self.structureKick * step / Self.structureKickSeconds)
            baseHue += advance
            kickRemaining -= advance
        }
        baseHue -= baseHue.rounded(.down)

        centroidColumn = clamp(brightness, 0, 1) * Double(columnCount - 1)
        gradient.update(target: Self.gradientAmplitude * clamp(spread, 0, 1),
                        now: now, dt: step)

        // Decay, then deposit. Deposits arrived during the frame that has just
        // been composed, so they belong after this frame's decay and before the
        // next frame reads the field.
        let trailDecay = exp(-step / Self.trailTime)
        let saturationDecay = exp(-step / Self.saturationTrailTime)
        for column in 0..<columnCount {
            trail[column] = trail[column] * trailDecay
                + clamp(pendingHue[column], -Self.depositLimit, Self.depositLimit)
            saturationTrail[column] = saturationTrail[column] * saturationDecay
                + pendingWeight[column]
            trail[column] = clamp(trail[column], -Self.trailLimit, Self.trailLimit)
            saturationTrail[column] = clamp(saturationTrail[column], 0, 1)
            pendingHue[column] = 0
            pendingWeight[column] = 0
        }
    }

    /// A gesture writes its own hue offset into the board, so that a wave
    /// sweeping left to right leaves a hue wake behind it and a run of hats
    /// warms the right of the board for a second.
    ///
    /// - Parameter weight: `level · kernel(x) · dt / τ_deposit`.
    public mutating func deposit(column: Int, weight: Double, hue: Double) {
        guard column >= 0, column < columnCount, weight > 0 else { return }
        pendingHue[column] += hue * weight
        pendingWeight[column] += weight
    }

    /// `H(x,t)`, in turns.
    public func hue(column: Int, base: Double? = nil) -> Double {
        let x = Double(clampIndex(column))
        let gradientTerm = gradient.value
            * (x - centroidColumn) / Double(max(columnCount - 1, 1))
        var value = (base ?? baseHue) + gradientTerm + trail[clampIndex(column)]
        value -= value.rounded(.down)
        return value
    }

    /// `sat(x,t) = S0 + S1·(0.4·Φ + 0.6·Strail)`.
    public func saturation(column: Int) -> Double {
        let recent = saturationTrail[clampIndex(column)]
        return clamp(Self.saturationFloor
                     + Self.saturationSpan * (0.4 * phrase + 0.6 * recent), 0, 1)
    }

    private func clampIndex(_ column: Int) -> Int {
        min(max(column, 0), columnCount - 1)
    }

    public mutating func reset() {
        baseHue = 0.30
        kickRemaining = 0
        gradient.reset()
        phrase = 0
        centroidColumn = 0
        for index in 0..<columnCount {
            trail[index] = 0
            saturationTrail[index] = 0
            pendingHue[index] = 0
            pendingWeight[index] = 0
        }
    }

    // MARK: - Geometry

    /// **Anti-centre-concentration** (§12.4). Gesture origins are chosen by the
    /// register that fired, never fixed:
    ///
    /// ```
    /// originColumn(b) = round( (b + 0.5)/8 · 16 ) = 1, 3, 5, 7, 9, 11, 13, 15
    /// ```
    ///
    /// **No band maps to column 8.** r1 put every kick ring at exactly the
    /// centre column — the most frequent event on almost any material, at the
    /// one place the complaint names — and that single line is the largest
    /// contributor to "the colour is concentrated in the centre". Kicks now live
    /// on the left, hats on the right, and *where* light appears carries
    /// register information instead of being a constant.
    public static func originColumn(band: Int, columnCount: Int = LinearCanvas.columnCount)
        -> Double {
        let width = Double(columnCount - 1)
        let bands = Double(AnalysisState.bandCount)
        return ((Double(band) + 0.5) / bands * width).rounded()
    }

    /// The per-drum hue offset a gesture deposits (§12.3): kick warm, snare
    /// neutral, hat cool. The r1 per-kind values, now written *into the board*
    /// rather than only tinting the gesture's own pixels.
    public static func depositHue(for kind: OnsetKind?) -> Double {
        switch kind {
        case .kick:  return -Self.depositLimit
        case .snare: return 0
        case .hat:   return Self.depositLimit
        case nil:    return 0
        }
    }
}

/// HSV to linear RGB, with value carried separately so the composition's
/// lightness stays the value channel exactly as §12.2 specifies.
///
/// One conversion per column per frame — seventeen — after which §6.2's blur,
/// the interlock and the single gamma encode proceed unchanged.
@inlinable
public func hsvToRGB(hue: Double, saturation: Double, value: Double)
    -> (r: Double, g: Double, b: Double) {
    let v = clamp(value, 0, 1)
    let s = clamp(saturation, 0, 1)
    var h = hue - hue.rounded(.down)
    h *= 6
    let sector = Int(h) % 6
    let f = h - Double(Int(h))
    let p = v * (1 - s)
    let q = v * (1 - s * f)
    let t = v * (1 - s * (1 - f))
    switch sector {
    case 0:  return (v, t, p)
    case 1:  return (q, v, p)
    case 2:  return (p, v, t)
    case 3:  return (p, q, v)
    case 4:  return (t, p, v)
    default: return (v, p, q)
    }
}

/// The hue of an RGB triple, in turns. Used to seat the user's theme colour into
/// the field as its base hue rather than as a board-wide constant.
@inlinable
public func hueOfRGB(_ r: Double, _ g: Double, _ b: Double) -> Double {
    let maximum = max(r, max(g, b))
    let minimum = min(r, min(g, b))
    let delta = maximum - minimum
    guard delta > 1e-9 else { return 0 }
    var hue: Double
    if maximum == r {
        hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
    } else if maximum == g {
        hue = (b - r) / delta + 2
    } else {
        hue = (r - g) / delta + 4
    }
    hue /= 6
    return hue - hue.rounded(.down)
}
