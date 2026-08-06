# Visualizer architecture — real-time redesign

Status: design, normative. Supersedes the ad-hoc tuning in
`Sources/GloriousVisualizer/*` and `Sources/GMMKLightsApp/VisualizerController.swift`.

The user verdict this document answers, verbatim:

> incredibly jittery — the lights don't properly stay on, they're just so fast —
> and it doesn't feel like it responds in real time to the little details of the song

plus a methodology objection: the current behaviour was tuned against two songs
that happened to be on this machine, and must instead work for **any** song.

Both complaints have the same root: the pipeline has **no time domain of its
own**. Onsets fire at a detector's refractory ceiling on material that contains
no percussion; envelopes are re-slammed faster than they can decay; band levels
are point-sampled at an arbitrary phase by a render loop whose clock is set by
USB round-trip time; and every threshold in the system is an absolute magnitude
rather than a ratio against the signal's own history.

This document specifies the replacement. It is organised as ten sections:

0. [Principles and non-negotiables](#0-principles-and-non-negotiables)
1. [Thread and clock architecture](#1-thread-and-clock-architecture)
2. [Analysis stage](#2-analysis-stage-100-hz)
3. [Universal adaptation — no per-song constants](#3-universal-adaptation)
4. [Ballistics — the AHR envelope](#4-ballistics--the-ahr-envelope)
5. [Animation model — continuous-time gestures](#5-animation-model--continuous-time-gestures)
6. [Render stage, interpolation and per-key hold](#6-render-stage)
7. [Transport and backpressure](#7-transport-and-backpressure)
8. [Latency budget](#8-latency-budget)
9. [The five modes, re-specified](#9-the-five-modes-re-specified)
11. [Multi-timescale energy](#11-multi-timescale-energy-new-in-r2) — *new in r2*
12. [Spatial colour and propagation](#12-spatial-colour-and-propagation-new-in-r2) — *new in r2*
10. [Verification: the universal test battery and pass metrics](#10-verification)

(§11 and §12 are numbered after §10 but placed before it, so that every existing
cross-reference stays valid while §10 remains the last normative section.)

Appendix A restates every constant in one table. Appendix B is the migration
order.

---

# Revision 2 — the second verdict (new)

Revision 1 shipped and runs on hardware. It fixed what it set out to fix: the
board no longer strobes, the sine-wave onset bug is gone, gestures hold. The
user's verdict on **r1 running live** is three new complaints, and none of them
is a tuning error — each is a direct consequence of something r1 specified.

> 1. "The keyboard updates feel off beat."
> 2. "It's like a cliff — the moment a certain sound plays a certain colour
>    happens, it's instantaneous triggered and then goes back to zero. There's
>    no sort of short term accumulation."
> 3. "The colour is concentrated in the centre and isn't diverse / well
>    propagated."

**The three root causes, stated as design faults rather than bugs:**

**F1 — the pipeline is late and the design compensates for the wrong half of
it.** §8.2 already schedules beat-locked gestures early, but by a *fixed*
`predictionLead = 0.040` that nobody measured, applied only in
`ModeRenderer.beatIsDue`, and only when a beat happens to fall inside the
current frame's window. Meanwhile the total is 60–90 ms and the *variance* of
the residual — which is what "off beat" actually feels like — is not measured
anywhere. A constant lead cancels a constant lag; the complaint is about the
part that is not constant. Answered by [§2.3-R](#23-tempo-and-phase--revised-r2),
[§7-R](#7-transport-and-backpressure) and [§8-R](#8-latency-budget--revised-r2).

**F2 — the cliff is what P1 specifies.** Every control signal in r1 is
normalised against its *own* history over 4 s (`RelativeFollower.longTime = 4.0`)
or 10 s (`PercentileNormaliser.window`), and §3.2 states outright that the
relative values "revolve around **1.0** for any material at any volume." M6 then
*enforces* that: `mean(AVERAGE_RELATIVE_b) ∈ [0.85, 1.20]` on every case. A
quantity normalised over τ cannot express variation slower than τ — so the
system is structurally incapable of representing "louder than it was ten seconds
ago". Master brightness makes it worse: it is
`smoothstep(0.02, 0.25, rms·gain)`, which saturates at 1.0 for anything
genuinely playing and therefore carries no dynamics at all. Everything that
remains is impulse-response: trigger → peak → decay to a bed that is itself a
ratio pinned at 1.0. The cliff is not a bug. It is r1 working as written.
Answered by [§11](#11-multi-timescale-energy-new-in-r2) and by amending P1 with
[P9](#p9).

**F3 — hue is one global scalar and the geometry piles light in the middle.**
`ModeRenderer.colour(for:)` maps a single number — the percentile-normalised
spectral centroid, `state.brightness` — through one ramp, for the whole board,
every frame. The only spatial hue variation in the entire system is the ±0.08
per-drum offset in §9.3, which colours a ring and nothing else. Geometrically:
`paintPulse` is brightest at the centre column by construction (`shape` falls
12 % to the edges), `paintVU` fills symmetrically outward from the centre, and
`triggerRing` puts **every kick** — the most frequent event on almost any
material — at exactly the centre column. Answered by
[§12](#12-spatial-colour-and-propagation-new-in-r2).

**What r2 changes, section by section:**

| section | status in r2 |
|---|---|
| §0 principles | **amended** — P1 qualified, P9/P10/P11 added |
| §1 threads and clocks | unchanged, still correct |
| §2 analysis stage | capture note **revised**; §2.3 **rewritten**; §2.4 **new** (the aubio decision) |
| §3 universal adaptation | unchanged, but now explicitly scoped to the *fast* timescale by P9 |
| §4 ballistics | unchanged — the AHR primitive is reused by §11 |
| §5 gestures | unchanged, plus the prediction/absorption interaction in §2.3-R |
| §6 render stage | unchanged; §6.2 composition order gains the colour-field step |
| §7 transport | **revised** — run-detection cost model, scattered-set fallback, budget |
| §8 latency | **rewritten** — unavoidable vs compensated ledger, ≤ 40 ms target |
| §9 modes | **revised** in its common layer; per-mode identities unchanged |
| §10 verification | **extended** — M8, M9, M10; five new battery cases; one new arm |
| §11 multi-timescale energy | **new** |
| §12 spatial colour and propagation | **new** |

§11 and §12 are numbered above §10 but placed *before* it in the document, so
that every existing cross-reference in the codebase and in this file stays
valid and §10 remains the last normative section.

---

## 0. Principles and non-negotiables

These are enforceable rules. A change that violates one is a regression even if
it looks better on some particular track.

**P1 — Nothing absolute.** No threshold, gate, trigger or gain constant may be
compared against an absolute magnitude, dBFS value, or hard-coded epsilon
derived from listening to a track. Every decision compares a quantity to *that
same quantity's own recent history*. The only permissible absolute constants are
(a) time constants in seconds, (b) perceptual constants (gamma, minimum on-time),
and (c) numerical guards that are provably below the ADC's own noise floor
(e.g. `1e-12` in a divisor), never used as a decision threshold.

> **Amended in r2.** P1 says *what* to compare against, and r1 read it as also
> saying *how far back*. It does not. "Its own recent history" is a family of
> statements, one per window length, and r1 picked one window (4 s / 10 s) for
> everything. See P9.

**P2 — Wall-clock ballistics only.** Every filter coefficient is derived per
update as `a = exp(-dt_actual / τ)` with τ in seconds and `dt_actual` measured.
There are no per-frame coefficients anywhere in the codebase. (The current code
gets this right; keep it. `projectM`'s `AdjustRateToFps` is the same commitment.)

**P3 — Analysis rate ≫ render rate, and they never gate each other.** The
analyser runs at ~100 Hz regardless of what the display or the USB transport is
doing. The renderer samples analysis state; it never drives it, and it never
waits for it.

**P4 — Band-limit the control signal to the display.** At the render rate `F`,
frame interval `dt_f = 1/F`. Any brightness envelope whose release is faster than
`3·dt_f` cannot be rendered and will alias into flicker. **Minimum release is a
clamp in code**, not a preset value: `τ_release ≥ 3·dt_f` and never below 200 ms.

**P5 — Absorb, never restart.** A trigger arriving while a gesture is in ATTACK
or HOLD raises that gesture's amplitude (`max`) and extends nothing. It does not
create a second gesture and does not reset phase. Only a gesture in RELEASE past
its refractory window may be replaced.

**P6 — Transport backpressure drops frames, never distorts timing.** The render
clock is fixed-rate and free of the USB echo pacer. If a frame's write cannot
start on time, that frame is *skipped*; the next frame is composed at its own
scheduled timestamp. No render-loop sleep is ever computed from transport
latency.

**P7 — Every displayed frame is a real point on a continuous function.** The
renderer evaluates `f(t_frame)` — envelopes, gesture positions, interpolated
band levels — never a stepped integer state advanced once per frame.

**P8 — Compose in linear light, gamma once at the very end.** All mixing,
envelope maths and interpolation happen in a float 0…1 perceptual/linear space.
Exactly one gamma encode occurs, immediately before the HID byte packing.

<a id="p9"></a>
**P9 — Normalise against a window longer than the structure you want to show
(new in r2).** A signal normalised over τ is high-pass filtered at ≈ 1/τ: it
*cannot* express variation slower than τ, by construction. Therefore every
displayed quantity must name the timescale it lives on, and the system must
carry at least three:

| timescale | window | what it is allowed to express | reference |
|---|---|---|---|
| TRANSIENT | 10–300 ms | individual hits | §4.1 accents |
| PHRASE | 0.5–2 s | this bar is louder than the last one | §11.2 |
| SECTION | 10–30 s | we are in the drop, not the intro | §11.3 |

A quantity normalised at one timescale may not be used to drive a display
element that is supposed to show a different one. `AVERAGE_RELATIVE` (τ = 4 s)
is a **trigger and motion** vocabulary and nothing else; using it as the board's
resting level — which r1 does, in every mode's bed — is why the board has no
memory. §11 supplies the two slower references. M6's `[0.85, 1.20]` bound
continues to apply to the *fast* relative values and explicitly does **not**
apply to the §11 envelopes; asserting it on those would re-impose the defect.

**P10 — Schedule to land, do not fire on detection (new in r2).** Any gesture
whose correct visual instant is *predictable* — an on-grid beat, a bar line, a
section boundary — is scheduled so that its **visible onset**, plus the measured
end-to-end pipeline latency, coincides with that instant. Firing at detection
time is only correct for events that were not predictable. The pipeline latency
used for this must be a *measured, live* quantity, never a constant, and its
residual variance must be reported (M8). A design that compensates a mean it
never measured is indistinguishable from one that got lucky.

**P11 — Colour is a field, not a scalar (new in r2).** Hue and saturation are
functions of `(column, time)`, evolving on the PHRASE and SECTION timescales,
never on the frame. Gestures deposit colour into a decaying spatial buffer, so
that motion is visible in hue as well as in brightness. No display element may
take its hue from a single board-wide number. Correspondingly, no gesture family
may have a fixed origin: gesture origins are chosen from the *register that
fired*, so that where light appears carries information.

---

## 1. Thread and clock architecture

Four independent clocks. They communicate only through lock-free single-slot or
ring handoffs. No stage ever blocks another.

```
┌── AUDIO THREAD ──────────────────────────────────────────────────────────┐
│ CoreAudio tap / mic callback. Smallest stable buffer.                    │
│ Job: copy samples into a lock-free ring. Nothing else. No FFT here.      │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ SampleRing (power-of-two, 1 s capacity)
┌── ANALYSIS THREAD ───────────▼───────────────────────────────────────────┐
│ Own thread, `.userInitiated` QoS. Loop: wait for ≥ hop samples, analyse. │
│ hop = 512 @ 48 kHz → 93.75 Hz     (target ≥ 100 Hz; see §2)              │
│ window = 2048 Hann                                                       │
│   whitening → bands → AHR followers → flux → onsets → tempo/phase        │
│ Publishes:                                                               │
│   • AnalysisState  → SeqLockSlot<AnalysisState>  (latest wins)           │
│   • OnsetEvent[]   → OnsetRing (SPSC, 256 slots, timestamped, never      │
│                      coalesced — coalescing is what destroys detail)     │
│ Every published value carries `hostTime` (mach absolute → seconds).      │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │
┌── MODEL + RENDER THREAD ─────▼───────────────────────────────────────────┐
│ FIXED-RATE clock. `mach_wait_until(nextDeadline)`, deadline advanced by  │
│ a whole `dt_f` each tick (catch-up by whole intervals if we overran).    │
│   1. drain OnsetRing → update gesture list (absorb per P5)               │
│   2. read AnalysisState + its timestamp; interpolate to t_frame (§6.1)   │
│   3. evaluate all envelopes and gesture positions at t_frame (P7)        │
│   4. compose canvas in linear float                                      │
│   5. per-key hold / hysteresis filter (§6.3)                             │
│   6. spatial blur, gamma encode                                          │
│   7. hand the frame to the transport as a *replaceable* single slot      │
│ Never sleeps on the transport. Never sleeps on audio.                    │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ FrameSlot (single slot; a new frame
                               │ overwrites an undelivered one)
┌── TRANSPORT THREAD ──────────▼───────────────────────────────────────────┐
│ Owns the HID device and the echo pacer. Loop: take the frame in the slot │
│ (if any), diff against last-sent, write only changed keys, repeat.       │
│ Slow transport ⇒ frames are dropped in the slot. Timing upstream         │
│ is unaffected. (§7)                                                      │
└──────────────────────────────────────────────────────────────────────────┘
```

### 1.1 The render clock

```swift
var next = now() + dt_f
while running {
    mach_wait_until(next)
    let t = next                 // compose for the SCHEDULED time, not `now()`
    renderFrame(at: t)
    next += dt_f
    if next < now() { next = now() + dt_f }   // catch up by whole intervals
}
```

Two things matter here and both are currently wrong:

* Frames are composed **for their scheduled timestamp**, not for the wall-clock
  instant the thread happened to wake. That removes the render-side contribution
  to motion jitter entirely: even if the thread wakes 8 ms late, the gesture
  position it computes is the one that belongs to that frame's slot in time.
* The deadline advances by a whole `dt_f`, so the loop cannot free-run. The
  current "sleep the remainder" pattern lets USB latency set the frame rate.

**Render rate.** `dt_f = 1/30 s` (33.3 ms) is the target; `F` is a configurable
`{15, 20, 24, 30}`. 30 fps is only reachable if the transport can deliver a
typical diffed frame in < 33 ms — §7 makes that plausible by writing only
changed keys, but the design is correct at 15 fps too and all clamps are
expressed in terms of `dt_f`, not in terms of 30 or 15.

### 1.2 Handoff primitives

* `SeqLockSlot<T>` — writer increments a sequence counter before and after the
  copy; reader retries while odd or changed. Wait-free for the writer, which is
  what the analysis thread needs. Replaces the current unsynchronised
  `latestLevels` / `analysisTime` (a real data race today).
* `OnsetRing` — SPSC ring of `OnsetEvent { time, kind, strength, confidence }`.
  **Events are never merged.** The current `max`-per-kind coalescing is why the
  board "doesn't respond to the little details": three hits inside one display
  frame become one. With a ring, the model sees all three and can schedule them
  at their true times — the third one lands in a later frame naturally, because
  gestures are functions of time.
* `FrameSlot` — single slot with replace semantics; see §7.

---

## 2. Analysis stage (~100 Hz)

Fixed pipeline, run once per hop:

```
ring → window(2048, Hann) → rFFT → |X[k]|
     → per-bin adaptive whitening              (§3.1)
     → log-spaced band summing → 8 bands       (§2.1)
     → per band: AHR follower + short avg + long avg   (§3.2, §4)
     → publish CURRENT_RELATIVE and AVERAGE_RELATIVE
     → whitened spectral flux → adaptive-median peak-pick → OnsetEvent  (§2.2)
     → tempo/phase tracker → (bpm, phase, confidence)  (§2.3)
```

Window 2048 / hop 512 gives 93.75 Hz at 48 kHz. If the capture rate is 44.1 kHz
use hop 448 (98.4 Hz). **Latency is set by the hop, not the window** — do not
shrink the window to chase latency; it costs low-frequency resolution, which is
where kick discrimination lives.

**Capture buffers — REVISED (r2).** r1 said "drop the mic buffer from 2048 to
256 or 512". That is **done**: `MicrophoneCapture.bufferSize = 512`, i.e.
10.7 ms and exactly one analysis hop. The remaining questions are how much
further to go, and what the *other* source does.

* **The floor is the hop, not the buffer.** The analyser cannot run until a
  whole hop of 512 samples exists. A capture buffer smaller than one hop adds
  callback overhead and buys **zero** latency: the first hop still completes at
  the same wall-clock instant. So `bufferSize = hop = 512` is the smallest
  buffer that means anything, and r2 fixes it there rather than chasing 256.
  Buffers *larger* than one hop are the real defect: 2048 delivered four hops in
  a burst, which is not a slow analysis rate but a *stuttering* one, and burst
  delivery is invisible to every metric that averages.
* **System audio is the one still unbounded.** The process tap hands over
  whatever CoreAudio chose. Requirement: request 512 frames via the aggregate
  device's buffer-frame-size property where the API allows, and **count every
  delivery larger than two hops** as a telemetry defect (`burstyDeliveries`).
  Target: `burstyDeliveries / deliveries ≤ 0.01` over a ten-minute run. A source
  that cannot meet it is a latency defect that no amount of scheduling fixes,
  and it must be visible rather than averaged away.
* **Do not shrink the FFT window.** 2048 stays. Its group delay is *compensated*
  (§8.1-R), not paid.

### 2.1 Bands

Eight log-spaced bands, summed from whitened bins, edges in Hz:

| # | name | range | used by |
|---|---|---|---|
| 0 | sub | 20–60 | pulse body, VU |
| 1 | bass | 60–120 | kick detection, pulse |
| 2 | lowmid | 120–250 | body |
| 3 | mid | 250–500 | snare detection |
| 4 | himid | 500–1k | vocal/body |
| 5 | presence | 1k–2.5k | |
| 6 | brilliance | 2.5k–6k | |
| 7 | air | 6k–16k | hat detection, shimmer |

Spectrum mode's six display registers are formed by pairing (0+1, 2, 3, 4, 5+6, 7)
so that the register set is a *view* of the band set, not a second analysis.

### 2.2 Onset detection — the dominant fix

The audit measured **12.1 onsets/s on a pure sine wave**, i.e. 92 % of the
refractory ceiling, on a signal containing zero onsets. Four of five modes are
onset-driven, so the board was free-running on a detector artefact. Three
structural faults caused it, and all three are fixed here.

**Fault 1 — an absolute floor.** `threshold = median * ratio + 1e-5`. `1e-5` has
no relation to the signal and dominates in any band that contains only spectral
leakage. **Replacement:** the floor is relative to the band's own long-term
level and there is a hard SNR test.

```
flux_b(t)  = Σ_{k∈b} max(0, Xw[k,t] − Xw[k,t−1])        // whitened, half-wave rectified
med_b(t)   = median of flux_b over the last 11 hops     (~117 ms)
mad_b(t)   = median absolute deviation over the same window
thresh_b   = med_b + δ · mad_b                          δ = 3.0
onset iff  flux_b > thresh_b
      AND  flux_b > κ · med_b                           κ = 1.6   (relative ratio test)
      AND  CURRENT_RELATIVE_b > 1.25                    (SNR: this band is actually
                                                         louder than its own average)
      AND  band_gate_b is open                          (§3.4)
      AND  t − lastFire_b > refractory                  (§4.4)
```

The MAD term is the key: it makes the threshold scale with the band's own
*variability*, so a stationary tone (variability ≈ 0) can never clear it, while a
quiet-but-punchy acoustic track can. The `CURRENT_RELATIVE > 1.25` test is the
one that would have caught the sine-wave bug on day one — a steady tone's
current-to-long-average ratio sits at exactly 1.0 forever.

**Fault 2 — detectors were fed raw ungated magnitudes**, bypassing every piece of
adaptive machinery in the pipeline. Fixed by construction above: flux is computed
on **whitened** bins, and the gate/relative tests are preconditions.

**Fault 3 — no cross-band exclusivity.** A kick legitimately spans 40–400 Hz and
fired both the kick and the snare detector, doubling the trigger rate on every
real hit and inventing 2.0 snares/s on a kick-only signal. **Replacement — a
winner-take-all arbiter over a 25 ms window:**

```
kick   from bands 0–1 ; snare from 3–4 ; hat from 7
For onsets whose times fall within 25 ms of each other:
  score = (flux/thresh) · bandWeight
  keep the highest-scoring kind; suppress the others for that window.
  bandWeight = 1.0 (kick), 0.9 (snare), 0.8 (hat)   — bass wins ties, because
  a genuine simultaneous kick+snare reads fine as a kick accent, whereas a
  phantom snare on every kick is the failure the audit measured.
```

**Confidence.** Every event carries `confidence = clamp((flux/thresh − 1)/2, 0, 1)`.
Low-confidence events drive dimmer gestures rather than being discarded — the
transition from "hit" to "no hit" must be continuous, or the board chatters at
the detection boundary.

<a id="23-tempo-and-phase--revised-r2"></a>
### 2.3 Tempo and phase — REVISED (r2)

The existing autocorrelation → harmonic-sum → median-lock chain measures well
(120.0 BPM median, 100 % of frames within 3 % on the tuning signal; BPM sd 0.04
on real music) and is kept **unchanged**. What r1 got right and keeps:

* Publish `(bpm, phase φ ∈ [0,1), confidence)` — a **continuously advancing
  phase**, not a stream of beat triggers. `φ` advances as `φ += dt/beatPeriod`
  every analysis hop, always, even when detection fails.
* **Phase is corrected gradually, never snapped.** On a detected beat, `φ` moves
  20 % of the way toward 0, computed at the *beat's own instant* rather than at
  the hop that noticed it (`TempoTracker.align(toBeatAt:now:)`). Tempo changes
  are rate-limited to ±2 % per beat and require three consecutive agreeing
  estimates. BTrack's prior-weighted design: new evidence never overrides an
  established hypothesis in one step.
* **Confidence gates beat-locked behaviour**, cross-faded through `gridWeight`,
  never switched.

**What r2 adds.** r1's predictive scheduling was one line — `predictionLead =
0.040`, a guess, applied only inside `beatIsDue`. Four things are missing and
each of them is part of "off beat":

#### 2.3.1 Publish the beat, not just the phase

`AnalysisState` gains two fields:

```
nextBeatTime  = state.time + (1 − φ) · beatPeriod      // host time, absolute
phaseSigma    = σ_φ, the phase-error spread (below)
```

The renderer must never recompute a beat time from `φ` and its own `now`: `φ` in
an interpolated state has already been advanced by the interpolator, and doing
the arithmetic twice is how a 10–20 ms error enters for free. One absolute
timestamp, computed where the phase actually lives.

#### 2.3.2 Phase stability is the gate, not tempo confidence

The user's complaint is phase, not BPM — the tracker's BPM sd is 0.04, which is
already an order of magnitude better than it needs to be. So measure the thing
that is actually wrong:

```
at each accepted phase correction, record the pre-correction error
    ε_n = wrapped phase error in beats, ∈ [−0.5, 0.5]
σ_φ  = standard deviation of the last 8 values of ε_n            (in beats)
```

`σ_φ` is published and drives the prediction lead directly:

```
leadWeight = smoothstep(0.12, 0.06, σ_φ) · gridWeight
```

i.e. full lead when the grid holds within ±6 % of a beat (≈ 32 ms at 112 BPM),
none when it is worse than ±12 %, continuous in between, and multiplied by the
existing confidence ramp. **This is the term that decides whether the board is
allowed to anticipate at all**, and it is the one number r1 never had.

#### 2.3.3 Schedule to land (P10)

Let `L̂` be the live measured end-to-end latency (§8.1-R). For a predicted beat
at `T_b`, a gesture with AHR attack `τ_a`:

```
visible onset of a gesture  t_vis = startTime + τ_a · ln 2      (half-rise)
we require                  t_vis + L̂ = T_b
therefore                   startTime = T_b − leadWeight · (L̂ + τ_a · ln 2)
```

The half-rise point is used because that is what an eye — and M8 — calls "the
gesture happened". `leadWeight` scales the whole lead, so a shaky grid degrades
continuously to reactive behaviour rather than switching.

Gestures are launched at the *frame whose scheduled time first reaches or passes
`startTime`*, and evaluated as `f(t_frame − startTime)` exactly as §5 requires —
so a gesture launched one frame late is still rendered at the right point of its
own envelope. **`startTime` is immutable once set** (P7). If the confirming
onset says the beat was elsewhere, that is the phase tracker's job, not the
gesture's; moving a live gesture would be a discontinuity in `f(t)`.

#### 2.3.4 Prediction credit — no phantom gestures

A predicted gesture is launched before its evidence exists. Three rules bound
what that can cost:

1. **Provisional amplitude.** A predicted gesture launches at
   `A = γ · A_exp`, `γ = 0.6`, where `A_exp` is an EWMA (τ = 4 beats) of the
   amplitude of the last *confirmed* on-grid onsets. A phantom is therefore
   always a modest accent, never a full flash.
2. **Confirmation absorbs (this is P5, unchanged).** If an arbitrated onset
   arrives with timestamp inside `[T_b − W, T_b + W]`, `W = 90 ms`, it is
   **consumed** by the in-flight predicted gesture: `amplitude =
   max(amplitude, A_actual)`, phase and `startTime` untouched. It does **not**
   create a second gesture. This is exactly §5.2's absorption rule and requires
   no new mechanism — but the consumption must be explicit, or prediction and
   detection double-fire on every beat, which reads as a flam.
3. **Credit.** A counter `credit ∈ [−4, +4]`, starting at 0: `+1` on
   confirmation, `−2` on a beat that passes `T_b + W` unconfirmed. Predicted
   launches are permitted only while `credit ≥ +1`. Two consecutive misses
   therefore stop prediction, and two consecutive confirmations restart it. An
   unconfirmed gesture already in flight is **not** cancelled — cancelling it
   would be a visible pop-out, which is worse than a dim accent — it simply
   decays on its own envelope at 0.6 amplitude.

Credit is also zeroed whenever the liveliness gate closes or `grounded` falls
(the analyser already abandons the grid 4 s after the last onset), so the board
cannot go on beating at a tempo the music has stopped playing.

#### 2.3.5 Reactive path unchanged

Onsets that are *not* consumed by a predicted gesture behave exactly as in r1:
they are timestamped back by the group delay and fire immediately. Fills,
vocal transients and everything off the grid stay reactive by design — they were
not predictable, so there is nothing to schedule against.

---

### 2.4 Decision record: aubio versus the in-house detector (new in r2)

**Decision: keep the in-house detector and tempo tracker. Do not link aubio.**
Recorded here with its reasoning and its revisit trigger, because it is the
obvious alternative and it should not have to be re-argued.

**The option.** [aubio](https://aubio.org) is a mature, streaming/causal C
library: complex-domain and HFC onset detection, a comb-filter beat tracker in
the Davies/Böck lineage, well-tested on MIREX-style corpora. Linking it would
replace §2.2 and the measurement half of §2.3 with code that is better validated
than ours.

**Why not:**

1. **Licence — decisive on its own.** aubio is **GPL-3** (a commercial licence
   exists but is not free). This repository is **MIT** (`LICENSE`, "Copyright (c)
   2026 Glorious Lights contributors"). Linking aubio into `GloriousVisualizer`
   would relicense the shipped application under GPL-3, and — because `viz-sim`
   links the same engine so that a measured number is a claim about the app
   rather than about a copy of it — it would relicense the test harness too.
   That is a project-level decision about how this software may be redistributed,
   traded for an improvement in a component that is not the one failing.
2. **The complaint is phase and latency, not BPM.** The in-house estimate is
   already stable: 120.0 BPM median, 100 % of frames within 3 %, sd 0.04 on real
   music. aubio would not measurably improve a number that is already at the
   noise floor of the question. What is unmeasured is `σ_φ` — and §2.3.2 adds
   it, in about twenty lines, to the tracker we already own.
3. **aubio's beat tracker emits the wrong shape of output.** It reports *beat
   events*, causally, after the beat. This design has deliberately moved to a
   continuously advancing **phase** precisely because a phase can be projected
   forward and an event stream cannot (§2.3.1, P10). Adopting aubio would mean
   building the continuous-phase and prediction-credit layer *on top of it*
   anyway — i.e. keeping all the new work and adding a dependency.
4. **The onset defect aubio would have fixed is already fixed.** The 12.1
   onsets/s on a 440 Hz sine is gone, and M5 now asserts *exactly zero* on four
   stationary cases. Buying a better detection function to solve a solved problem
   is not a trade.
5. **Integration cost is real.** A C dependency in SwiftPM, an FFI bridge on the
   analysis thread, a second build configuration for CI, and no Swift-native
   fallback for anyone building the app from source.

**What we take anyway** — ideas, not code, and the ideas are not the licensed
thing: the adaptive-median peak-picker with a delayed decision (already in
§2.2), and the multi-hypothesis idea behind aubio's tempo agents, which is what
`σ_φ` and the prediction credit are a cheap scalar version of.

**Revisit if, and only if, both hold:** (a) M8 mean absolute beat-alignment
error cannot be brought under 30 ms after §2.3-R and §8-R are implemented and
measured, **and** (b) the project accepts relicensing to GPL-3. Failing (a)
alone is a reason to fix the scheduling, not to change the licence.

---

## 3. Universal adaptation

Nothing in this section contains a constant derived from any piece of music.
Every constant is a time constant, a percentile, or a dimensionless ratio.

### 3.1 Per-bin adaptive whitening (Stowell & Plumbley, ICMC'07)

Fixes spectral tilt and "the highs never light up", with no per-song EQ and no
training:

```
peak[k] ← max( |X[k]| , floorLevel , m · peak[k] )     m = exp(−hop/τ_w), τ_w = 3.7 s
Xw[k]   = |X[k]| / peak[k]                              ∈ [0,1]
```

`floorLevel` is **not** a constant: it is `2 × p10(|X[k]|)` from the per-bin
noise-floor tracker (§3.3). Without it, silent bins get amplified to full scale
and hiss becomes a light show.

This replaces the existing static pink-noise equalisation curve, which is a fixed
tilt correction — better than nothing, worse than whitening, and wrong for any
material that is not pink.

### 3.2 Relative band values (projectM's trick)

Per band, maintain three followers and publish two dimensionless ratios:

```
short_b : τ_rise 20 ms, τ_fall 50 ms      (asymmetric)
long_b  : τ 4.0 s steady state,
          τ 0.32 s for the first 50 analysis hops   ← fast-converge warm-up
CURRENT_RELATIVE_b = current_b / max(long_b, ε)     // instantaneous — for triggers
AVERAGE_RELATIVE_b = short_b   / max(long_b, ε)     // attenuated  — for motion
```

Both revolve around **1.0 for any material at any volume**. The universal
threshold vocabulary is therefore: `< 0.7` very quiet, `≈ 1.0` normal,
`> 1.3` loud/hit. Every mode in §9 states its thresholds in these units.

The warm-up is copied deliberately: it is what stops the first five seconds after
pressing play from looking wrong.

**Rule: anything that moves continuously uses AVERAGE_RELATIVE. Only triggers use
CURRENT_RELATIVE.** (MilkDrop's `bass` vs `bass_att`.) Driving motion from the
instantaneous value is a flicker source in itself.

### 3.3 Percentile AGC and adaptive floors

Instead of a PI controller with presets, use percentile normalisation — inherently
outlier-robust, and it needs no gain constants at all:

```
Per band, a 10 s history (coarse 64-bucket log histogram, updated per hop,
buckets decayed by exp(−hop/10s) so it is a moving window without a ring buffer):
    p10_b  = noise floor estimate
    p90_b  = "loud but not a click" reference
    x_norm = clamp( (x − p10_b) / max(p90_b − p10_b, ε), 0, 1 )
```

Properties that matter:

* A single click cannot move p90 (max would be hostage to it — this is why the
  current `LoudnessReference` breathes).
* A momentary dip cannot pin the floor. The current `NoiseFloorTracker` drops
  *instantly* to any new minimum and takes 12 s to recover, so one unluckily
  phased quiet sample changes gate behaviour for twelve seconds. A p10 over a
  10 s window cannot do that.
* Global brightness scale = `p90` of the *board-wide* normalised energy, with
  gain hard-clamped to `[1/16, 16]` so a silent passage cannot be amplified into
  fireworks.
* **Freeze the histogram update while the master gate is closed** (§3.4), so
  silence does not wind the gain up.

**Dual-speed escape hatch** (from WLED's emergency zones, restated in percentile
terms): if `x_norm` sits above 0.98 or below 0.02 for more than 0.5 s, the
histogram decay τ temporarily drops from 10 s to 0.5 s until it is back in range.
This survives a sudden loud drop and a quiet intro without breathing on normal
material.

### 3.4 Gates — and gates decay, never snap

Per-band gate with hysteresis expressed in relative units, not dB above an
absolute:

```
open  when CURRENT_RELATIVE_b > 1.30 and x_norm > p10-derived floor
close when AVERAGE_RELATIVE_b < 1.10
hold-open minimum: 120 ms after opening (gate hold — this is the anti-chatter
                   term noise-gate designers add for exactly this reason)
```

When a gate closes, its band's contribution **decays to zero over τ 400 ms**. It
never snaps. Silence always ramps out. The current pipeline has four hard
cutoffs to black (`displayEpsilon = 0.05`, `height > 0.02`, `level > 0`,
`distance <= reach`), each one a cliff a value can oscillate across; all four are
replaced by smoothstep ramps over the bottom 10 % of range.

---

## 4. Ballistics — the AHR envelope

One primitive, used everywhere. It runs **at the analysis rate**, not the frame
rate, so attacks shorter than one frame are meaningful and the renderer merely
samples a properly-formed envelope.

```swift
struct AHR {
    var attack: Double      // seconds (time constant)
    var hold: Double        // seconds (absolute hold at peak)
    var release: Double     // seconds (time constant)
    private var value = 0.0
    private var holdUntil = 0.0

    mutating func update(target: Double, now: Double, dt: Double) -> Double {
        if target > value {
            let a = exp(-dt / attack)
            value = target + (value - target) * a
            holdUntil = now + hold
        } else if now < holdUntil {
            // hold: value unchanged
        } else {
            let a = exp(-dt / release)
            value = target + (value - target) * a
        }
        return value
    }
}
```

### 4.1 The values

Attack:release ratios of 1:5 to 1:20 across the board — that ratio is the whole
game. Front-load the attack, back-load the release: a 10 ms attack with a 400 ms
release feels *instant*; 100/100 feels late **and** twitchy.

| element | attack | hold | release | why |
|---|---|---|---|---|
| Kick accent | 15 ms | **100 ms** | 320 ms | hold ≥ 3·dt_f guarantees visibly on in ≥3 consecutive frames at 30 fps |
| Snare accent | 8 ms | 80 ms | 240 ms | |
| Hat / shimmer | 5 ms | 60 ms | 200 ms | never below 200 ms — P4 |
| Mid / vocal body | 50 ms | 0 | 500 ms | |
| Spectrum column | 0 (instant) | peak-hold | gravity fall, §6.4 | |
| Overall wash (VU) | 150 ms | 0 | 1000 ms | VU-like; keeps the board from going dark |
| Mouse / structural | 200 ms | 0 | 700 ms | 6 LEDs, no spatial averaging to hide twitch |
| Master brightness | 300 ms | 0 | 1200 ms | |

### 4.2 The clamps (enforced in code, not in presets)

```swift
release = max(release, 3 * dt_f, 0.200)     // P4
hold    = max(hold, 2 * dt_f)               // visible in ≥2 frames
attack  = min(attack, release / 4)          // maintain ≥1:4 asymmetry
```

At 15 fps `3·dt_f = 200 ms`; at 30 fps it is 100 ms and the 200 ms absolute floor
binds. The 200 ms floor is deliberate: it is the same number the audit derived
independently as the minimum on→off→on period the current system accidentally
achieved.

### 4.3 What this fixes concretely

The current pulse envelope is `τ = max(0.12, period·0.55)`, i.e. ×0.57 per 66.7 ms
frame — full to near-black in three frames — while being re-triggered five times
a second by phantom onsets. That *is* "the lights don't properly stay on".
Under the table above a kick accent is at full for 100 ms, then decays with
τ = 320 ms, and cannot be re-triggered within 120 ms.

### 4.4 Refractory

Minimum 120 ms between accepted accent triggers of the same kind (WLED uses 100 ms
for its peak detector; LedFx uses `beat_min_time_since = 0.1`). At 30 fps this
caps triggers at ~8/s; combined with the §2.2 arbiter and the relative tests,
measured trigger rate on real music lands in 0.5–5 Hz, which is the target band.
Faster than that is invisible anyway and produces only flicker.

---

## 5. Animation model — continuous-time gestures

No per-frame integer state. A gesture is a record; the display is a pure function
of the gesture list and the current time.

```swift
struct Gesture {
    let kind: Kind              // .pulse, .wave, .ring, .peak
    let startTime: Double       // seconds, host clock
    let durationBeats: Double   // musical time — see below
    var amplitude: Double       // 0…1, raised by absorption
    let hue: Double
    let origin: Double          // column, for wave/ring
    let direction: Double       // ±1
    var phase: Phase            // .attack / .hold / .release
}
```

Rendering is `f(now − startTime)`. Consequences, all of them free:

* frame jitter does not become motion jitter,
* a dropped frame skips nothing — the gesture is still where it should be,
* sub-frame positions are exact.

### 5.1 Musical durations

`durationBeats`, not milliseconds. A flash decay of `0.4 × beatPeriod` stays
musical at 80 BPM and at 170 BPM; a fixed 250 ms does not. This is also the fix
for double-time material — gestures stretch automatically when the tempo halves.
When beat confidence < 0.35, `beatPeriod` falls back to a 0.5 s nominal and
gestures cross-fade to envelope-driven amplitudes (§2.3).

Clamp: `durationSeconds = clamp(durationBeats · beatPeriod, 0.20, 2.0)`.

### 5.2 The lifecycle — trigger → attack → sustain → release

```
        trigger (passes refractory + arbiter)
             │
             ▼
     ┌───► ATTACK ──(attack τ elapsed)──► HOLD ──(hold elapsed)──► RELEASE ──► dead
     │        ▲                            ▲                          │
     │        └──── absorb (amplitude=max) ┘                          │
     └───────────────── new trigger accepted ONLY here ───────────────┘
                        (and only past refractory)
```

**A trigger arriving during ATTACK or HOLD is absorbed**: `amplitude =
max(amplitude, newAmplitude)`, phase and start time untouched. It never restarts
the animation from zero. Restarting is exactly what makes lights "not stay on" —
the gesture is perpetually re-launched and never gets to display its body. This
is the same `if (barHeight > previousBarHeight[x])` max-hold that WLED uses.

### 5.3 Gesture population caps

Hard caps, oldest-first eviction, per mode:

| mode | max simultaneous gestures |
|---|---|
| pulse | 1 (the board *is* the gesture) |
| wave | 2 |
| ripple | 3 |
| spectrum | 0 (envelope-driven) + 6 peak markers |
| vu | 1 + 2 accents |

The audit measured up to 8 overlapping rings and 2–3 counter-travelling waves
alive at once under the phantom-onset rate. Even with correct detection, caps are
required: overlapping gestures average out to a uniform glow, which is the
opposite of "responds to the detail".

### 5.4 Velocity clamp

With 17 columns, motion faster than ~2 cells per frame is unreadable — it reads
as a shape reappearing elsewhere, not as motion. The current wave runs at 2.27
cells/frame against a σ = 2.8 kernel: it advances nearly its own width every
frame.

```
speed_cells_per_second ≤ 2.0 / dt_f          (30 fps → 60 c/s; 15 fps → 30 c/s)
full-width sweep therefore ≥ 17/speed ≥ 0.28 s (30 fps) / 0.57 s (15 fps)
```

Beat-synchronised sweeps are sized to the beat period first, then clamped.

### 5.5 Motion blur (temporal integration)

A 15/30 fps sample-and-hold display point-sampling a moving gesture aliases. The
renderer therefore **integrates each moving gesture over the frame's exposure
window**:

```
effective_width = sqrt(σ² + (velocity · dt_f · 0.5)²)
```

i.e. the spatial kernel widens by the distance travelled during the frame. Cheap,
exact enough, and it converts strobing into streaking. Alternative for gestures
with non-Gaussian profiles: accumulate 3 sub-steps at `t − dt_f`, `t − dt_f/2`,
`t` and average.

---

## 6. Render stage

### 6.1 Interpolation between analysis states — P7 in practice

The analyser publishes at ~94 Hz; the renderer samples at 30 Hz. Today the
renderer latches whichever `latestLevels` it happens to see, at an arbitrary
phase — 5 of every 6 analysis frames are simply discarded, and a transient that
peaks between display frames is either caught at full or missed entirely
depending on phase. That aliasing then poisons `decisionAverage`, the noise floor
and the auto-gain, so the *whole board's* brightness inherits the sampling jitter.

Replacement: the analysis thread publishes the last **three** states in the seqlock
slot (a tiny ring, `AnalysisState[3]` with timestamps). The renderer, composing
for `t_frame`:

```
1. Find the bracketing pair (s_i, s_{i+1}) with s_i.time ≤ t_frame < s_{i+1}.time.
2. Continuous quantities (band levels, envelope values, tempo phase, master
   brightness) are Catmull-Rom interpolated across the three states —
   C¹ continuous, so there is no velocity discontinuity at a state boundary.
3. If t_frame is ahead of the newest state (normal: analysis is ~5 ms behind),
   EXTRAPOLATE at most 20 ms using the envelope's own known decay:
       value(t) = newest.value · exp(−(t − newest.time)/τ_release)
   Extrapolating with the envelope's real time constant is safe because the
   envelope IS an exponential; extrapolating linearly is not.
4. Beyond 20 ms of extrapolation, hold the last state and mark the frame `stale`.
   (Consecutive stale frames are a telemetry counter, §10.5.)
```

Additionally, **peak-hold across dropped analysis hops**: the analyser maintains
`peakSinceLastRead` per band, cleared when the renderer reads. Bar heights use
`max(interpolated, peakSinceLastRead)` so a transient between display frames is
never lost. This is the treatment onsets already get correctly today and levels
never got.

### 6.2 Composition order

```
for each mode: paint gestures + envelope fields into a float canvas
             ↓ linear float RGB per LED, 0…1
spatial blur: separable Gaussian, σ = 1.0 cell across the 17×6 grid
             ↓  (hides quantisation enormously; LedFx blurs every effect)
per-key hold / hysteresis filter                      (§6.3)
             ↓
master brightness (AHR, §4.1) × user brightness
             ↓
gamma encode: out = round(255 · L^2.2)                (§6.5)
             ↓
HID bytes
```

`Canvas.widenIsolatedColumns` is **deleted**. It applies a frame-relative
threshold (`peak · 0.45`) with no temporal state and no hysteresis, at the very
end of the pipeline, for every mode — whether a column is "lit" can flip between
consecutive frames purely because the frame's own brightest key changed. The
σ = 1.0 blur does the same job (making single-column gestures readable) with no
temporal non-linearity.

### 6.3 Per-key hold and hysteresis — the flicker interlock

This is the last line of defence, and it is what makes the flicker metric in §10
a *guarantee* rather than a hope. Every LED carries a small state machine,
independent of what any mode did:

```swift
struct KeyHold {
    var lit: Bool          // the hysteresis state
    var litSince: Double
    var darkSince: Double
    var displayed: Double  // the slew-limited output level
}
```

Rules, evaluated per key per frame against the composed level `x ∈ [0,1]`:

| rule | value | rationale |
|---|---|---|
| rise threshold | `x > 0.14` | Schmitt trigger — 2.3:1 hysteresis |
| fall threshold | `x < 0.06` | |
| **minimum on-time** | **150 ms** | once lit, a key stays lit for ≥150 ms regardless of `x`. At 30 fps that is ≥5 frames; at 15 fps ≥3 (P4-consistent) |
| **minimum off-time** | **100 ms** | once dark, it cannot relight for 100 ms. Bounds the toggle rate at ≤4 Hz per key by construction |
| slew limit (down) | ≤ `1/0.200` per second | a key cannot fall from full to black faster than 200 ms |
| slew limit (up) | unbounded | attacks must stay instant (P4/§4.1) |
| snap-to-zero | none | fades to zero via the ramp; there is no epsilon cliff |
| **snap-to-threshold** | **none** | a held key shows the level the model composed, never the rise threshold. Clarified in r2.1: the implementation displayed `max(x, 0.14)` while lit, which *creates light the model did not ask for* — and, because 0.14 sits above M1 and M4's 0.10 on-level, it also made both metrics unfailable |

The minimum on-time and off-time together give a **hard ceiling of 4 on→off→on
transitions per key-second** (one full cycle needs ≥150+100 = 250 ms). The
verification ceiling in §10 is set below that, at 1.5, so the metric measures the
*model's* behaviour and not just the interlock — if the interlock is the thing
holding the metric down, the model upstream is still wrong.

The interlock is a filter, not a source: it can only delay a key going dark and
delay it relighting. It cannot create light that the model did not ask for.

### 6.4 Peak markers — gravity ballistics

For spectrum and VU peak markers, do not smooth: **snap up instantly, fall at a
fixed rate.** It reads as physical rather than noisy (WLED's 2D GEQ and the
Gravcenter family both do exactly this).

```
if barHeight > peak { peak = barHeight }        // instant
else                { peak -= dt / fallSeconds } // constant velocity
fallSeconds per row: 110 ms  → full 6-row fall in 0.66 s
```

Faster than ~60 ms/row and the marker becomes flicker; slower than ~150 ms/row
and it looks stuck.

All boolean `includePeak:` flags (`falloff > 0.6`, `falloff > 0.7`,
`distance <= reach - 1.5`, `level >= 0.85`) become **continuous** — the peak key's
brightness is a smoothstep of the same quantity over a ±0.1 band. Hard-thresholded
function-row keys flipping on and off as a wave passes is a directly observable
flicker source today.

### 6.5 Gamma and fractional fills

**Gamma.** Perceived brightness is roughly a power law; a linear PWM ramp spends
most of its visible change in the bottom 20 % of the range and looks like an
abrupt jump at the top. Keep an internal float lightness `L`, output
`round(255 · L^2.2)` once, at the very end. Effects at our frame rate: a fade
over four frames actually looks like a fade instead of four steps, and low-level
detail — *the little details of the song* — becomes visible instead of collapsing
into the bottom few code values.

**Fractional column fills.** `Canvas.fillColumn` currently computes an integer
row count and gives each row a brightness that depends only on its index, so the
top row of every bar is pure on/off. On the three navigation columns
(`rowCount = 2`) a level crossing 0.5 toggles half the column. Replacement:

```
h = height · rowCount
for row r: coverage = clamp(h − r, 0, 1)
           level    = coverage · rampBrightness(r)
```

The top row now fades in continuously as the bar rises. This alone removes a
large fraction of the visible per-frame toggling on quiet material.

---

## 7. Transport and backpressure

Today: 9 echo-paced packets per frame (a full 126-LED repaint, `START` + 7 colour
packets + `END`), 135 packets/s, no dirty-region diffing, a 10 ms sleep before
`END`, and — the pathological case — `replyTimeout 0.300 × maxSendAttempts 4`
followed by `blindPacingDelay 0.350` for the rest of the transaction, i.e. a
**multi-second stall** from one unacknowledged packet. During that stall the
board freezes, then teleports. That reads as exactly "doesn't respond to the
details".

**Design:**

1. **The render loop never touches the transport.** It writes into `FrameSlot`
   and returns. `FrameSlot.put` overwrites any undelivered frame and increments
   `droppedFrames`. Backpressure therefore shows up as a lower *delivered* frame
   rate, never as a distorted render clock (P6).
2. **Dirty-region diffing.** The transport keeps `lastSent[126]` and writes only
   keys whose gamma-encoded byte triple changed. An unchanged board costs one
   `END`-less no-op instead of 9 packets. On typical material (pulse, VU) the
   changed-key count per frame is far below 126, so the packet count per frame
   drops several-fold — this is what makes 30 fps reachable at all.

   > **REVISED (r2) — the packet builder, specified exactly.** Diffing is
   > implemented (`VisualizerController.packets(for:lastSent:)`) but its cost
   > model was never written down, and "1–3 packets per frame" is a *target* that
   > nothing currently asserts. The rules below are normative.
   >
   > The wire constraint: a `0x11` write carries **≤ 18 keys** at
   > `address = keyIndex · 3`, one **contiguous run** per packet. So the cost of
   > a frame is `Σ over runs ceil(runLength / 18)`, and the builder's only
   > freedom is where it ends a run.
   >
   > **Run detection.** Walk the 126 keys. Open a run at the first changed key.
   > Continue through unchanged keys while the gap since the last changed key is
   > `≤ G`, `G = 4`. Close the run at the last *changed* key (never at the
   > padding). Rationale for `G = 4`: repainting `g` unchanged keys costs
   > nothing extra until the run crosses an 18-key packet boundary, whereas
   > splitting always costs a whole extra packet — so bridging is free up to the
   > point where it is not, and 4 keeps the expected bridged length well inside
   > one packet. `G` is a constant of the *wire format*, not of any song (P1).
   >
   > **Scattered-set fallback.** A sparse but spread-out change set is the
   > pathological case: 20 changed keys at stride 6 produce 20 runs and 20
   > packets — worse than the 7-packet full repaint it replaced. So, after run
   > detection, if
   >
   > ```
   > packetCount(runs) ≥ ceil(changedKeyCount / 18) + 2      // fragmentation test
   >   OR packetCount(runs) > 5                              // absolute budget
   > ```
   >
   > the builder discards the runs and emits a **single full repaint** (7 colour
   > packets, indices 1…126). The full repaint is the ceiling, and no frame may
   > ever cost more than it. `5` is chosen because 5 colour packets + `START` +
   > `END` = 7 wire writes, which is under the 9 of a full frame, so the fallback
   > can only ever reduce the worst case.
   >
   > **Bracketing.** `START` … `END` still brackets **every** frame, including a
   > one-packet frame: `END` is the commit. A frame with zero changed keys sends
   > nothing at all — not even the bracket.
   >
   > **Budget, asserted in telemetry, not hoped for:**
   >
   > | quantity | target | hard ceiling |
   > |---|---|---|
   > | median colour packets per delivered frame | ≤ 2 | — |
   > | p95 colour packets per delivered frame | ≤ 4 | — |
   > | max colour packets per delivered frame | — | 7 (the full repaint) |
   > | frames falling back to full repaint | ≤ 5 % on musical cases | — |
   >
   > If the fallback rate exceeds 5 %, the *renderer* is producing scattered
   > change sets — which is itself a defect (§6.2's σ = 1.0 blur should leave
   > spatially coherent regions), and the fix belongs upstream, not in the packet
   > builder.
3. **Coalesce, don't queue.** Since the slot holds exactly one frame, a slow
   transport skips intermediate frames. Because gestures are continuous functions
   of time (§5), a skipped frame loses nothing structurally — the next delivered
   frame shows the gesture where it genuinely is.
4. **Stall containment.** `replyTimeout` drops to 60 ms, `maxSendAttempts` to 2,
   and `replyChannelIsSilent` is scoped to the *packet*, not the rest of the
   transaction, with a 2 s exponential recovery back to paced mode. Worst-case
   added latency from one lost echo: 120 ms, not 4 s.
5. **Telemetry.** The transport records per-packet round-trip time and the
   delivered-frame interval; the render loop records its own tick interval and
   `droppedFrames`. Exposed via a debug menu and via `viz-diag`. The audit's
   single biggest measurement gap ("does the board actually run at 15 fps?") has
   no answer today because nothing counts anything. It must have one before any
   frame-rate decision is defended.

---

## 8. Latency budget

Perceptual anchors (ITU-R BT.1359-1): detectability +45 ms / −125 ms,
acceptability +90 ms / −185 ms, where positive means the sound precedes the
visual. Humans are markedly more tolerant of light *lagging* audio than leading
it. Targets: **≤ 60 ms indistinguishable from live; 60–120 ms tight; > 180 ms
reads as "not responding to the song"** — which the current chain, at 95–220 ms
typical and multi-second pathological, plainly does.

<a id="81-budget--revised-r2"></a>
### 8.1 Budget — REVISED (r2): unavoidable versus compensated

r1's budget added every stage into one number and then hoped a constant
`predictionLead` would cancel it. That is the wrong shape. Latency splits into
two kinds, and only one of them can be scheduled away:

* **Unavoidable** — a delay between the sound existing and photons being
  physically able to change. Nothing can cancel it; it can only be made smaller.
* **Compensated** — a delay whose magnitude is *known* at the time the decision
  is made, so the decision can simply be made earlier. Group delay is the
  canonical case: the analyser already knows a transient happened 26.7 ms ago
  and timestamps the event back accordingly.

**The target: `T_unavoidable ≤ 40 ms`, everything else compensated.**

| stage | ms @ 48 kHz / 30 fps | class | note |
|---|---|---|---|
| capture buffer | 10.7 (mic, = 1 hop) | **unavoidable** | already at the hop; smaller buys nothing (§2) |
| hop quantisation | 5.3 mean, 10.7 worst | **unavoidable** | analysis fires on whole hops |
| FFT window group delay | 21.3 | *compensated* | `MusicAnalyzer.groupDelay` = (1024 + 256)/48000 = 26.7 ms, subtracted from every event timestamp |
| peak-pick causal lag | 10.7 (1 hop) | *compensated* | folded into the same `groupDelay` term |
| analysis → render handoff | ≤ 5 | *compensated* | §6.1 interpolates/extrapolates to `t_frame` |
| envelope attack to half-rise | `τ_a · ln 2` = 10 (kick), 24 (pulse) | *compensated* | §2.3.3 subtracts it explicitly |
| display frame quantisation | 16.7 mean, 33.3 worst | **unavoidable** | fixed 30 fps clock |
| transport (diffed, 1–3 packets) | 6–9 median, ≤ 25 p95 | **unavoidable** (median), *compensated statistically* | §7.2-R budget |
| transport worst case | ≤ 145 | **unavoidable, bounded** | 60 ms timeout × 2 attempts, packet-scoped |
| **T_unavoidable** | **10.7 + 5.3 + 16.7 + 7 ≈ 39.7 ms** | | **the number that must stay ≤ 40** |
| T_total, uncompensated | ≈ 39.7 + 21.3 + 10.7 + 5 + 10 ≈ 87 ms | | what the board would show with no scheduling |

The 40 ms figure is not arbitrary: ITU-R BT.1359-1 puts the detectability
threshold for a *lagging* visual at −125 ms and for a *leading* one at +45 ms.
At 40 ms the board sits inside the region where the eye cannot separate light
from sound at all — so the residual, and only the residual, is what "off beat"
can be about. Which is why r2 measures the residual's **variance** (M8) and not
just its mean.

Two consequences r1 did not state:

* **Frame quantisation is now the largest single unavoidable term.** If, after
  §7.2-R, the transport genuinely delivers a 1–3-packet frame in under 10 ms,
  the render rate may be raised to 40–48 fps, which takes the mean frame term
  from 16.7 to 10–12 ms and `T_unavoidable` to ≈ 33 ms. This is the only lever
  left, and it is gated on the M7 delivered-frame telemetry, not on a guess.
* **`p95` matters more than the median.** A pipeline whose median is 40 ms and
  whose p95 is 120 ms feels worse than one at a flat 70 ms, because the eye
  tracks the *jitter* of the audio-visual offset. M7 already bounds the render
  tick; M8 bounds what actually reaches the board.

<a id="82-latency-compensation--revised-r2"></a>
### 8.2 Latency compensation — REVISED (r2)

r1: "beat-driven gestures are scheduled at `predictedBeatTime −
measuredPipelineLatency`" — but nothing measured it, and the shipped value is a
literal `predictionLead = 0.040`.

**`L̂` is a live measurement, updated every frame:**

```
deliveryLag_n = t_END_echoed(n) − t_scheduled(n)      // per delivered frame
D             = EWMA of deliveryLag over τ = 5 s, plus its p95
L̂             = 0.5·dt_f            // mean display quantisation
              + D                   // transport, measured
              + 0.5·hopSeconds      // mean hop quantisation
              + captureBufferSeconds
              + userOffset           // §8.3, signed
```

Everything already compensated by timestamping (group delay, peak-pick lag,
handoff) is **excluded** — including it would double-count and push gestures
early by ~30 ms, which is the failure mode `TempoTracker.align` already had to
be fixed for once ("two errors that agree numerically is not the same as either
being right").

`L̂` is clamped to `[0, 0.150]` s and rate-limited to 5 ms of change per second,
so a single transport hiccup cannot yank the whole beat grid.

**`L̂` is used only through `leadWeight` (§2.3.2/§2.3.3).** With a shaky grid the
lead collapses to zero and the board is reactive — which is correct, because
anticipating a beat you cannot locate is worse than being late.

Non-beat-locked detail (fills, vocal transients) still runs at the full
uncompensated ≈ 87 ms, which is why `T_unavoidable` and the transport budget
must hold: there is nothing to schedule those against.

### 8.3 User offset

A single global offset control, ±100 ms, defaulted to the measured value from the
clap test. Fixed capture latency differs per machine and per output device; it
should be dialled out, not designed around.

**Measurement protocol:** clap test with a phone slow-motion camera (240 fps),
20 claps, report median and p95 of clap-to-photon. Don't estimate the total —
estimate the stages, measure the sum.

---

## 9. The five modes, re-specified

Identities are preserved. What changes is that each mode is now a *gesture
schedule plus an envelope field* over the common foundation, with an explicit
lifecycle and no re-triggering mid-gesture.

Common to all five:
* ~~colour comes from the theme; hue variation is bounded to ±0.08 to avoid the
  rainbow-vomit failure mode~~ — **superseded by §12.** Colour comes from the
  spatial hue field `H(x,t)`; the ±0.08 bound survives as a limit on what a
  single *gesture* may deposit, not as a bound on the board,
* all thresholds are in `CURRENT_RELATIVE` / `AVERAGE_RELATIVE` units,
* all rendering is `f(t_frame)`,
* the §6.3 per-key interlock applies unconditionally.

> **REVISED (r2) — the common layer.** Two things move out of the individual
> modes and into the shared foundation:
>
> **1. The bed is no longer per-mode.** Every mode in r1 invents its own resting
> wash out of a ratio pinned at 1.0 (`pulseFloorShare · overallAverageRelative`,
> `waveBedShare · midAverageRelative`, `rippleBedShare · …`), and spectrum and VU
> have no bed at all. All of them are deleted and replaced by the single
> §11.4 composition `bed(t) + swell(t)`, which is the same for every mode. What a
> mode still owns is `shape(x,t)` — *where* the bed sits on the board — and its
> gestures.
>
> **2. Gesture origins come from the register that fired (P11).** r1 puts every
> kick ring at the exact centre column, which is the single largest contributor
> to "the colour is concentrated in the centre". §12.4 gives the mapping. Per
> mode:
>
> | mode | r1 origin | r2 origin |
> |---|---|---|
> | pulse | board-wide, brightest at centre | board-wide, brightest at the **centroid column** `x_c(t)` (§12.4) |
> | wave | edge → edge | unchanged; now leaves a colour trail (§12.3) |
> | ripple | kick = centre always | `originColumn(band)` — kick left, snare mid, hat right (§12.4) |
> | spectrum | registers left→right | unchanged; it was already the good case |
> | vu | symmetric from centre | **asymmetric**: left arm driven by low registers, right by high (§12.4) |

### 9.1 Pulse — "the board breathes with the beat"

One gesture, board-wide.

```
trigger:  kick onset with confidence > 0.3, OR (beat confidence > 0.6 AND
          predicted downbeat) — whichever comes first, refractory 120 ms
attack:   15 ms to amplitude = clamp(CURRENT_RELATIVE_bass / 2.0, 0.35, 1.0)
hold:     100 ms at full
sustain:  the board never goes below a floor of
          0.18 · AVERAGE_RELATIVE_overall   ← the "breath", not black
release:  τ = 0.35 · beatPeriod, clamped to [0.24 s, 0.8 s]
absorb:   a louder kick during attack/hold raises amplitude only
```

The sustain floor is the fix for "the lights don't properly stay on": between
beats the board sits at a live, level-following glow rather than decaying to
0.02. Spatially, brightness falls off ~12 % from centre to edge so the board has
shape rather than being a flat flash.

### 9.2 Wave — "light travels across on every beat"

```
trigger:  beat (predicted, when confidence > 0.5; else kick onset), refractory
          = 0.5 · beatPeriod — a wave cannot be launched while one is younger
          than half a beat
direction: alternates per BAR, not per trigger. Per-trigger alternation is not
          musical and at high trigger rates it reads as random.
speed:    17 columns / (0.75 · beatPeriod), clamped by §5.4 to ≤ 2 cells/frame
profile:  Gaussian σ = 2.8 cells, widened by §5.5 motion blur
amplitude: clamp(CURRENT_RELATIVE_bass / 2.0, 0.4, 1.0), AHR 15/100/320 ms
cap:      2 waves; a third trigger is absorbed into the youngest
background: 0.15 · AVERAGE_RELATIVE_mid wash so the board is never dark
```

### 9.3 Ripple — "drum hits fire rings from the centre"

```
trigger:  arbitrated onset (§2.2) — kick / snare / hat, each with its own
          refractory (120 / 120 / 160 ms)
origin:   kick = centre, snare = ±4 columns alternating, hat = ±7 alternating
speed:    kick 9, snare 14, hat 18 cells/s — all clamped by §5.4
ring:     Gaussian shell σ = 1.6, widened by motion blur
lifetime: min(1.2 · beatPeriod, 0.9 s); amplitude AHR per kind (§4.1)
cap:      3 rings, oldest evicted. Was up to 8 — "confetti in time".
colour:   kick warm, snare bright, hat cool; each within ±0.08 of theme hue
```

### 9.4 Spectrum — "bars by musical register"

No gestures; a pure envelope field, and the mode where §6.1 interpolation and
§6.5 fractional fill matter most.

```
6 registers from the 8 bands (§2.1)
height_r  = smoothstep( x_norm_r )            percentile-normalised (§3.3)
ballistic = instant rise, peak-hold, gravity fall 110 ms/row (§6.4)
fractional top row per §6.5 — no integer quantisation
peak marker: separate, gravity fall, continuous brightness
floor:    every register keeps ≥0.05 so the board shows its shape in quiet
          passages instead of blinking sections out
```

### 9.5 VU — "loudness fills out from the middle"

```
level     = AVERAGE_RELATIVE_overall, AHR 150 ms / 0 / 1000 ms  (VU ballistic)
reach     = level · 8.5 columns from centre, both directions
edge      = smoothstep over ±1 column — no `distance <= reach` cliff
accents   = up to 2 gestures: a kick brightens the inner 3 columns
            (AHR 15/100/320 ms), a snare tips the outermost lit column
peak marker: PPM ballistic — fast attack, 650 ms decay TC, per §6.4
```

A deliberate blend: VU body for smoothness, PPM marker for aliveness. That
contrast is why real meters look musical.

### 9.6 Mouse (6 LEDs) — structural layer

With six elements and no spatial averaging, per-frame twitch is maximally
visible. The mouse is therefore the **slow layer**: driven by
`AVERAGE_RELATIVE` and bar-level phase (downbeats, section changes), releases
400–800 ms, sparse accents with ≥150 ms minimum visible on-time and a hard cap of
2–3 accents per second. The keyboard grid carries all fast detail.

---

<a id="11-multi-timescale-energy-new-in-r2"></a>
## 11. Multi-timescale energy (new in r2)

> The user's exact words: *"it's like a cliff — the moment a certain sound plays
> a certain colour happens, it's instantaneous triggered and then goes back to
> zero. There's no sort of short term accumulation."*
>
> This section is the answer, and the first thing it has to do is undo something
> §3 asserts.

### 11.0 Why r1 cannot accumulate

Everything r1 displays is built from quantities that are, by explicit design,
memoryless beyond 4 s:

* `AVERAGE_RELATIVE_b = short_b / long_b`, `long τ = 4.0 s` — §3.2 states it
  "revolves around **1.0** for any material at any volume", which is precisely
  the property that destroys structure.
* `x_norm` is percentile-normalised over a 10 s window with a 0.5 s escape
  hatch — so a build lasting 16 s is normalised *while it is happening*.
* `master = smoothstep(0.02, 0.25, rms·gain)` saturates at 1.0 for anything
  audible, so the one place with an absolute reference deliberately throws the
  dynamics away.
* Every mode's bed is one of those ratios × a share constant, so the resting
  level of the board is pinned near a constant.

Result: trigger → peak → decay to a constant. A cliff. Per **P9**, the fix is a
second and third reference at longer windows, feeding a bed that the transients
ride *on top of* rather than replace.

### 11.1 The common source: a long-referenced energy `E(t)`

All three envelopes are driven from one dimensionless scalar, computed per
analysis hop.

```
Λ(t)  = 20·log10( max(rms(t), 1e-7) )              // log domain: music is multiplicative
R_lo  = p05 of Λ over a 60 s decayed-histogram window
R_hi  = p95 of Λ over the same window
E(t)  = clamp( (Λ(t) − R_lo) / max(R_hi − R_lo, 6.0), 0, 1 )
```

* **60 s, not 10 s.** P9: to show a 20 s build you must normalise over something
  longer than 20 s. 60 s is ~2 sections of typical popular music and comfortably
  longer than any phrase.
* **The 6 dB divisor floor** is the one place a decibel appears as a constant,
  and it is a statement about *perception*, not about a track (P1(b)): a master
  with less than 6 dB of programme dynamics genuinely has no structure to show,
  and stretching its noise to full range would be inventing one. A heavily
  limited EDM master reads flatter than a live recording — correct.
* **Freeze while the master gate is closed**, exactly as §3.3 requires, so
  silence cannot wind the reference down.
* The same `QuantileTracker` type already in `Adaptive.swift` implements
  `R_lo`/`R_hi`; only the window differs.
* `E` starts undefined and is **held at 0 until the master gate has opened at
  least once**. A session that begins in silence does not light the board.

### 11.2 PHRASE — `Φ(t)`, the 0.5–2 s layer

```
Φ = AHR(attack τ = 0.35 s, hold = 0.25 s, release τ = 1.6 s).update(target: E)
```

* **The hold is the anti-cliff term at this timescale.** Side-chain ducking at
  128 BPM has a 469 ms period; a beat gap in a ballad is ~800 ms. A 0.25 s hold
  plus a 1.6 s release means neither of those starts a meaningful fall, while a
  genuine 4-bar decrescendo (≈ 7.5 s at 128 BPM) is tracked almost exactly.
* Rise is faster than fall (0.35 vs 1.6) because musical energy arrives faster
  than it leaves, and because a build that lags its own crest reads as broken.

### 11.3 SECTION — `Σ(t)`, the 10–30 s layer

```
Σ = one-pole on E with   τ_up = 8 s,   τ_down = 20 s
```

Asymmetric on purpose: a section arrives faster than it leaves, so a 2-bar
breakdown inside a drop does not discard the drop.

**Structure escape hatch.** A pure 20 s time constant makes a real section
change take 20 s to show, which is its own failure. Reuse §3.3's dual-speed
pattern, restated for structure:

```
D(t) = |Φ(t) − Σ(t)|                        // novelty
if D > 0.35 sustained for > 1.5 s:
      τ_up   ← 3 s        (accelerate upward only)
      τ_down ← 3 s   ONLY IF  E < 0.15 sustained for ≥ 3 s
until D < 0.15, then restore.
```

**The downward asymmetry is the anti-cliff guarantee at this timescale**, and it
is normative: `Σ` may accelerate its *rise* on any novelty, but may accelerate
its *fall* only on sustained genuine quiet. A filter sweep to nothing, a
one-bar stop, a badly gain-staged verse — none of them can collapse the bed.
Additionally `Σ` is rate-limited to a fall of **0.25 per second** at all times,
so even the accelerated path takes ≥ 4 s from full to zero.

**True silence still darkens the board.** Once the gate has opened, if the
master gate is closed **or** `E < 0.05` *and* `Σ < 0.15` continuously for
`T_silence = 4.0 s`, a ramp-out multiplier is applied to the whole composition:

*(Amended in r2.1. `E < 0.05` alone cannot be the condition: `E` is a percentile
of the last sixty seconds, so a passage that is genuinely playing but quiet sits
at `E ≈ 0` by construction, and `cut-transitions`' five seconds of −34 dBFS
piano ramped itself to black while the music was audible — 26 % of the frames the
ground truth calls playing, against a 5 % bound. The master gate alone cannot be
the condition either: it is `smoothstep(0.018, 0.030, rms·gain)` with the AGC
gain clamped at 16×, so it decides "is anything playing" inside a 4.4 dB window
centred on −57 dBFS, and a −45 dBFS room-tone floor — where a microphone in a
quiet room actually sits — reads as music. Measured, the board went dark,
**relit**, and held a board mean of 0.10 indefinitely on nothing but room tone.
`Σ` is what separates the two, using the mechanism this section already
specifies rather than a new threshold: SECTION falls with τ = 20 s and is
rate-limited to 0.25 per second, so five seconds of quiet piano cannot pull it
under `quietLevel` while a minute of room tone certainly does. Quiet music keeps
its section; a room does not have one. The new `music-then-room` case in §10.1 is
what asserts this.)*

```
outAmount = smoothstep(4.0, 8.0, secondsSinceContinuousSilence)     // 0 → 1
L ← L · (1 − outAmount)
```

so the board reaches black about 8 s after the music genuinely stops, and never
sooner. Any `E ≥ 0.05` hop resets the timer instantly (rise is unrestricted).

### 11.4 Composition — the exact formula

Per column `x`, per frame `t`, in linear lightness before the §6.3 interlock:

```
bed(t)        = B0 + B1 · Σ(t)                        B0 = 0.09,  B1 = 0.15
swell(t)      = S1 · max(0, Φ(t) − k · Σ(t))          S1 = 0.55,  k  = 0.85
headroom(t)   = 1 − bed(t) − swell(t)
accent(x,t)   = A1 · Σ_g  level_g(t) · kernel_g(x)    A1 = 0.90     (§5 gestures)

L(x,t) = clamp( (bed(t) + swell(t)) · shape(x,t)
                + accent(x,t) · headroom(t),          0, 1 ) · (1 − outAmount)
```

Ranges: `bed ∈ [0.09, 0.24]`, `swell ∈ [0, 0.55]`, and the accent scales into
whatever is left, so a gesture always has somewhere to go — which is the
property r1's `paintPulse` had to hand-roll (`hit · 0.85 · (1 − floor)`) and
which is now structural.

**The three properties this formula must deliver, stated so they can be
falsified (M9):**

1. **Never at zero while music plays.** `bed ≥ B0 = 0.09` whenever the gate is
   open, so board-mean lightness `≥ 0.09 · mean_x shape(x,t)`. With every mode's
   `shape` having a mean ≥ 0.7 this is ≥ 0.06, which is M9c's floor.
   **This is deliberately a *board-mean* guarantee, not a per-key one.** A
   per-key floor above the interlock's 0.14 rise threshold would make M1 and M4
   vacuous — the exact circularity `ModeRenderer` was already corrected for once.
   Individual keys must still be able to go dark.
2. **Builds visibly build, drops visibly drop.** `swell = Φ − 0.85 Σ` is the
   PHRASE energy *above* the section floor. Through a 16 s build, `Φ` tracks the
   rise with a 1.6 s lag while `Σ` lags 8 s, so `swell` grows monotonically and
   peaks at the drop; through a breakdown `Φ` falls in ~2 s while `Σ` holds, so
   `swell → 0` and the board sits on the section bed. Target: `ρ_slow ≥ 0.80`
   (M9b).
3. **Transients punctuate without resetting the bed.** The accent term is
   *added*, scaled by `headroom`. **Nothing in the accent path may write to `Φ`,
   `Σ`, `E` or the trail buffers.** That one-way dependency is the whole
   anti-cliff mechanism: a hit can only add light, never remove it, and can never
   be followed by a return to zero because zero is not where the bed is.

### 11.5 What this replaces

| deleted | replaced by |
|---|---|
| `ModeRenderer.pulseFloorShare / waveBedShare / rippleBedShare` | `bed(t) + swell(t)` |
| `ModeRenderer.bedEnvelope` (AHR 50/0/600 ms on a ratio) | `Φ` and `Σ` on `E` |
| `paintPulse`'s `0.18·overallAverageRelative + 0.25·body` | ditto |
| `master = smoothstep(0.02, 0.25, rms·gain)` as a *level* | `master` keeps its "is anything playing" role only; dynamics come from `bed + swell` |
| spectrum's and VU's `bed = 0.0` | the common bed × their own `shape(x,t)` |

`AnalysisState` gains three channels: `phrase`, `section`, `energy` (`Φ`, `Σ`,
`E`), interpolated by the existing flat-vector interpolator for free.

---

<a id="12-spatial-colour-and-propagation-new-in-r2"></a>
## 12. Spatial colour and propagation (new in r2)

> *"The colour is concentrated in the centre and isn't diverse / well
> propagated."*

r1 has exactly one colour decision per frame: `state.brightness`, the
percentile-normalised spectral centroid, mapped through a seven-stop ramp, for
all 126 LEDs. Plus a ±0.08 per-drum offset on ripple rings. That is the entire
colour model. Per **P11** it becomes a field.

### 12.1 The hue field

Hue is a function of column (rows within a column share it — the board is a
17-wide instrument and per-row hue fights the bar metaphor; an optional ±0.02
row tilt is permitted, no more):

```
H(x,t) = wrap01( H0(t)  +  A(t) · G(x,t)  +  C(x,t) )
```

**`H0(t)` — the drift term (SECTION timescale).** A slowly rotating base hue:

```
dH0/dt = ω0 · (0.25 + 0.75 · Σ(t))            ω0 = 1/180  turns per second
```

— a full wheel in 3 minutes at full section energy, 12 minutes at rest. Plus a
**structure kick**: on a §11.3 novelty event (`D > 0.35` sustained 1.5 s), `H0`
advances by `0.11` of the wheel, eased over 2 s. A new section therefore
visibly changes the palette. **`H0` never moves per frame and never randomly** —
the drift rate is tied to `Σ`, and the jumps to structure.

**`A(t)·G(x,t)` — the register gradient, advected.** This is the key move: the
spectral centroid stops being *the board's colour* and becomes *the position of
the colour boundary*.

```
x_c(t) = brightness(t) · (N − 1)                  // N = 17; the centroid column
G(x,t) = ( x − x_c(t) ) / (N − 1)      ∈ [−1, 1]  // warm below, cool above
A(t)   = A_max · spread(t)                        A_max = 0.30 turns
```

`spread(t)` is the normalised spectral entropy over the existing per-band
shares — how much of the spectrum is actually occupied:

```
s_b    = share(b) / Σ_b share(b)
spread = −Σ_b s_b · ln s_b / ln 8        ∈ [0, 1]
```

So a bass-only passage (`spread` low) collapses the board toward one hue, and a
full-band passage fans it across ±0.30 of the wheel. Bass-register columns read
warm, treble-register columns cool, and the crossover **moves with the music**
instead of the whole board sliding along a ramp together. `A(t)` is smoothed by
an AHR (50 ms / 0 / 800 ms) so the fan opens and closes on the PHRASE timescale,
not per frame.

In `spectrum` mode the columns *are* registers, so `G` is literally register
order and the mapping is exact. In the other four it reads as a warm-left,
cool-right wash whose boundary tracks the centroid — which is what the "colour
is not propagated" complaint is asking for.

### 12.2 Saturation and value

```
sat(x,t)   = S0 + S1 · ( 0.4 · Φ(t) + 0.6 · Strail(x,t) )      S0 = 0.45, S1 = 0.55
value(x,t) = L(x,t)                                            // §11.4, unchanged
```

Recently-struck columns are more saturated; the untouched bed is a paler tint of
the same hue. HSV → linear RGB is done once per column per frame (17
conversions), then §6.2's blur, interlock and single gamma encode proceed
unchanged.

### 12.3 The colour trail — motion visible in hue

Two per-column decaying buffers that gestures write into. This is what makes
motion legible as colour and not only as brightness.

```
per frame, per column x:
    C(x,t)      ← C(x, t−dt) · exp(−dt / τ_trail)          τ_trail   = 0.90 s
    Strail(x,t) ← Strail(x, t−dt) · exp(−dt / τ_sat)       τ_sat     = 0.60 s

    for each live gesture g:
        w = level_g(t) · kernel_g(x) · dt / τ_deposit      τ_deposit = 0.12 s
        C(x,t)      += ν(g) · w
        Strail(x,t) += w

    C      clamped to ±0.18 turns
    Strail clamped to  [0, 1]
```

`ν(g)` is the gesture's own hue offset — the r1 per-kind values, now *deposited
into the board* instead of only tinting the gesture's own pixels: kick `−0.08`
(warm), snare `0.00`, hat `+0.08` (cool), beat-driven `0.00`.

A wave sweeping left to right therefore leaves a ~0.9 s hue wake behind it; a
run of hats warms the right of the board for a second; a kick leaves a warm
patch where its ring started. The ±0.08 deposit limit and the ±0.18 accumulation
clamp together keep this inside "a tinted board", not "rainbow vomit" — and M10a
puts an explicit upper bound on hue spread so the limit is enforced rather than
asserted.

### 12.4 Anti-centre-concentration

**Gesture origins are chosen by the register that fired**, never fixed:

```
originColumn(band b) = round( (b + 0.5) / 8 · (N − 1) )
                     = 1, 3, 5, 7, 9, 11, 13, 15   for b = 0…7
```

No band maps to column 8. Within an onset's kind, the band used is the one with
the **higher flux** on that hop (kick: band 0 or 1 → column 1 or 3; snare: band
3 or 4 → column 7 or 9; hat: band 7 → column 15), plus a deterministic ±1
alternation so repeated hits of the same drum do not stack on one column. Kicks
therefore live on the left, hats on the right, and *where* light appears carries
register information instead of being a constant.

**Per-mode geometry changes:**

* **pulse** — `shape(x,t) = 1 − 0.25 · |x − x_c(t)| / (N − 1)`. Brightest at the
  centroid column, which moves; r1's fixed 12 % falloff from column 8 is
  deleted.
* **vu** — stays a centre-out meter (that identity is deliberate) but becomes
  **asymmetric**: `reach_left` from the low registers (bands 0–3),
  `reach_right` from the high (bands 4–7). The meter is symmetric only when the
  spectrum is, so its brightness centre of mass moves whenever the material is
  tilted.
* **ripple** — origins per the table above; the r1 "kick = centre, snare = ±4,
  hat = ±7" scheme is deleted.
* **wave**, **spectrum** — geometry unchanged; both gain the trail.

### 12.5 The spatial-uniformity target

Normative, and measured by M10:

> Over any 30 s musical run, in any mode: let `V(x)` be the time-averaged mean
> lightness of column `x`. Then **`0.5 · mean_x V(x) ≤ V(x) ≤ 1.8 · mean_x V(x)`
> for every column** — no column starved, no column hogging.
>
> And, simultaneously, the per-frame brightness centre of mass `x̄(f)` must have
> **`sd_f(x̄) ≥ 1.5` columns** and **`p95(x̄) − p05(x̄) ≥ 4.0` columns** — the
> bright region must actually visit different parts of the board.

The two clauses are deliberately in tension: a uniformly lit board satisfies the
first trivially and fails the second, and a board that parks a bright spot in one
place fails the first. Both must hold.

---

## 10. Verification

The audit's finding about the current tooling is the important one: **every
metric in `viz-sim` is spatial or aggregate, and none is temporal.** There is not
one frame-to-frame difference metric in the tool. `gestureCoherence` reports a
perfect **1.000 in all five modes** on the very signal the user calls unusable.
The tool literally cannot see the defect it was used to tune away.

So the verification work is in two parts: temporal metrics, and a corpus that
spans the failure axes rather than two songs that happen to be on this machine.

### 10.1 The synthetic battery

Every case is generated — no copyrighted audio, no machine-specific files, fully
reproducible in CI. Added to `Sources/viz-sim/Signals.swift`; each runs for 30 s
unless stated.

| id | signal | what it catches |
|---|---|---|
| `edm-128` | four-on-floor: 128 BPM kick (60 Hz sine burst, 12 ms attack, 180 ms decay), offbeat hat (8 kHz noise burst), snare on 2 & 4 (200 Hz + noise), sustained saw bass, side-chained | the main case; beat lock, gesture pacing |
| `ballad-72` | sparse acoustic: 72 BPM, soft kick on 1&3, brushed snare, decaying guitar-like harmonic stack, 18 dB crest factor, 2 s gaps | "does it die on quiet material"; gate chatter |
| `speech` | formant-modulated noise + pitch pulses, 3–6 syllables/s, natural pauses, **zero periodic beat** | false tempo lock; onset firing on voiced sustains |
| `crescendo` | classical-style: string-like harmonic stack, −45 dBFS → −6 dBFS over 20 s, then back down over 10 s | AGC breathing, dual-speed escape, floor tracking |
| `cut-transitions` | 5 s loud EDM → 0.5 s pure silence → 5 s quiet piano → hard cut → 5 s loud, ×2 | gate ramp-out, AGC recovery, warm-up path |
| `sustained-tone` | steady 110 Hz / 440 Hz / 1 kHz sines, 20 s each | **the ground-truth case: zero onsets required.** The current code emits 12.1/s |
| `pink` | pink noise | flat board; no spurious structure |
| `white` | white noise | high-band whitening sanity |
| `near-silence` | −60 dBFS noise | must stay dark; must not be amplified into fireworks |
| `dnb-174` | double-time breakbeat, 174 BPM | gesture durations must stretch, not overlap |
| `polyrhythm` | 3-against-4, ambiguous tempo | low-confidence cross-fade; must not free-run a wrong grid |

**New cases (r2)** — these exist so the three new complaints become falsifiable:

| id | signal | what it catches |
|---|---|---|
| `click-120` | bare click track: 10 ms 2 kHz sine burst, −12 dBFS, 8 ms exponential decay, exactly every 0.500 s, on digital silence. 30 s = 60 beats | **M8 ground truth.** Beat times are known exactly, so alignment error is a real number rather than an estimate |
| `click-112` | as above at 112 BPM (0.5357 s), the tempo the user was listening to | the same, at a period that is not a round number of frames |
| `click-90-ramp` | 90 BPM for 10 s, ramping linearly to 100 BPM over 10 s, then 100 BPM for 10 s | prediction must not overshoot on a tempo change; the ±2 %/beat rate limit is exercised here |
| `click-120-gap` | `click-120` with beats 21–28 muted (4 s of silence mid-run) | **phantom-gesture test.** §2.3.4's credit rule must stop the board beating through the gap |
| `build-drop` | 128 BPM: 8 s filtered intro → 16 s build (kick + rising noise sweep, RMS rising ~18 dB monotonically) → 1 s pre-drop silence → 12 s full-energy drop → 8 s breakdown. 45 s | **M9's main case.** The generator emits its own per-hop RMS as ground truth |

**New case (r2.1):**

| id | signal | what it catches |
|---|---|---|
| `music-then-room` | 20 s of 128 BPM four-on-the-floor, then 55 s of −45 dBFS room tone. 75 s | **M9c's silence complement.** The clause "board-mean ≤ 0.03 after 10 s of silence" was emitted **zero** times in 13 138 checks: `cut-transitions`' silences are 0.5 s and the clause needs ten seconds, so `DeadFrac` ran entirely uncoupled and a board glowing on room noise passed the whole table. −45 dBFS, not `near-silence`'s −60: the AGC's own gain clamp already decides −60 dBFS, and the question is what happens in the 15 dB above it |

`build-drop` is the case r1 has no answer to at all, and it is deliberately not
a synthetic abstraction: it is the shape of the material the user was listening
to when they used the word "cliff".

Plus the **orthogonal axes** applied to every case, one battery arm each. The
matrix was one axis at one frame rate and one sensitivity, which left three
user-reachable settings and the headline backpressure principle gated by
nothing:

| arm | what it varies | why |
|---|---|---|
| — | nothing | the reference |
| `/jitter` | 8 ms Gaussian on the display wake-up | §7.5 |
| `/stall` | 200 ms transport stall at 0.5 Hz | **P6**: the render clock must not move and the bounds must still hold on what the board shows. M3 is not asserted here — a 200 ms stall *is* latency |
| `/15fps` | `dt_f = 1/15` | §1.1 claims the design is correct at 15 fps; only 30 was ever run |
| `/quiet`, `/loud` | sensitivity 0.5 and 2.0 | the menu's own range. M2's *lower* bound is not asserted here: a monotone output gain scales the frame-to-frame difference by construction, so "is the board inert" is asked at unity gain |
| `/latency` **(new in r2)** | `--output-latency 12` — the composed frame is recorded as *visible* 12 ms after its scheduled time | **M8 is only meaningful with this arm on.** A simulator that shows a frame the instant it is composed is measuring the model, not the pipeline, and would report a beat alignment the hardware cannot achieve. 12 ms = the §7.2-R transport median plus latch |

`--jitter <ms>` on the render
interval is driven from the distribution measured on real hardware (§7.5).
`viz-sim` is temporally deterministic today — fixed `frameInterval`, audio fed in
exact lockstep with the display — so the aliasing class of bug **cannot occur in
the simulator at all**. That is why it survived. Required additions to viz-sim:

* `--jitter <ms>` — Gaussian jitter on the frame interval, plus a `--stall <ms>@<hz>`
  injector reproducing transport stalls,
* decoupled analysis/display phase (feed audio on its own clock, sample the
  display asynchronously) so the interpolation path in §6.1 is actually exercised,
* per-frame CSV export of every LED level, which is what all the metrics below
  are computed from.

**Further additions required by r2:**

* `--output-latency <ms>` — the display-side delay described above. The frame
  composed for `t` is recorded as visible at `t + L_out`. Without it M8 is
  measuring a pipeline that does not exist.
* **Per-frame colour export, not only lightness.** `SimRun.Result.colors`
  already exists; M10 needs it exposed in the CSV as RGB triples, because hue is
  the thing being measured and lightness discards it.
* **Ground-truth beat and RMS tracks.** `Signal.track` must return, alongside
  `events`, a `beats: [Double]` list (exact beat times, for M8) and an
  `rmsEnvelope: [(time, rms)]` at the analysis rate (for M9b). Deriving either
  from the audio inside the metric would be measuring our own analyser against
  itself.
* **A packet-count model.** `viz-sim` must run the real
  `VisualizerController.packets(for:lastSent:)` over consecutive frames and
  report the §7.2-R budget (median / p95 / max packets, fallback rate). It is
  the only place that budget can be checked without hardware.

### 10.2 Metric definitions

All metrics are computed from the per-frame LED-level CSV. A key is **on** in a
frame when its gamma-decoded linear level ≥ 0.10 (the same value in every
metric, so the metrics are mutually consistent).

---

**M1 — Flicker rate `flicker` (primary).**

> For each LED *k*, count the number of complete **on→off→on** transitions over
> the run. Divide by the run duration in seconds. Report the mean over LEDs and
> the 95th percentile over LEDs.
>
> `flicker_k = toggles_k / duration` — units: **on→off→on cycles per key-second**.

* **Hard ceiling: `p95(flicker_k) ≤ 1.5` and `mean(flicker_k) ≤ 0.8`** on every
  case in the battery, in every mode.
* Rationale: the §6.3 interlock makes 4.0 structurally impossible; a ceiling of
  1.5 therefore tests the *model*, not the interlock. On `sustained-tone`,
  `pink` and `near-silence` the requirement is stricter: **`p95 ≤ 0.1`** — a
  stationary signal must produce a stationary board.
* This metric is the direct numerical statement of "incredibly jittery". Nothing
  in the current tool measures it.

---

**M2 — Smoothness `Δframe` (bounded on both sides).**

> Mean over frames of the mean over LEDs of `|L_k(f) − L_k(f−1)|`, where `L` is
> the linear 0…1 level. Report mean and p95 over frames.

* **Bound: `0.010 ≤ mean(Δframe) ≤ 0.075 · (30 · dt_f)`** and
  **`p95(Δframe) ≤ 0.22 · (30 · dt_f)`**. The *upper* bounds are per frame — the
  same motion at half the frame rate is twice the step from one frame to the
  next — so they scale with `dt_f` like every other clamp (§1.1). The lower bound
  is about the board not being dead, which is a statement about the display
  rather than about a frame, and does not scale.
* Bounded *both* ways deliberately. Too high is strobing. Too low means the board
  is inert — a smoothing filter can trivially satisfy an upper bound alone by
  making the visualiser dead, which is the other way to fail the user's
  complaint. The lower bound must be met on `edm-128`, `ballad-72` and
  `crescendo`; it is waived on `near-silence` and `sustained-tone`, where inert
  is correct.

---

**M3 — Responsiveness `onsetLatency` (in frames).**

> For each ground-truth event in a synthetic signal (the generator emits an event
> list alongside the audio), find the first display frame at or after the event
> in which board-mean linear brightness rises by ≥ 0.05 above its pre-event
> 100 ms baseline. Latency = `(frameTime − eventTime) / dt_f`, in frames.
> Report median and p90.

* **Bound: `median ≤ 2.0 frames` and `p90 ≤ 3.5 frames`** at 30 fps
  (≈ 67 ms / 117 ms), on `edm-128`, `ballad-72` and `dnb-174`.
* **Miss rate** (events with no response within 6 frames) **≤ 5 %**.
* This is the numerical statement of "doesn't respond in real time to the little
  details".

---

**M4 — Hold behaviour `onDuration`.**

> For each LED, collect the durations of every contiguous run of on-frames.
> Report the median over all runs across all LEDs, and the 10th percentile.

* **Bound: `median(onDuration) ≥ 0.25 s` and `p10(onDuration) ≥ 0.15 s`** on
  every musical case.
* The p10 bound is what the §6.3 minimum on-time guarantees; the median bound
  tests that gestures actually get to display their body rather than being
  re-launched. This is the numerical statement of "the lights don't properly stay
  on".

---

**M5 — Onset ground truth (regression gate).**

> Compare detected onsets against the generator's event list, with a ±50 ms
> matching window.

* `sustained-tone`, `pink`, `white`, `near-silence`: **0 onsets. Exactly zero.**
  (Current code: 12.1/s on a 440 Hz sine. This one assertion would have caught
  the dominant bug on day one.)
* `edm-128`: kick recall ≥ 0.95, precision ≥ 0.90; **snare false-positive rate on
  kick-only variants ≤ 0.05/s** (tests the §2.2 arbiter; current code invents
  2.0 phantom snares/s).
* `speech`: total onset rate ≤ 2.0/s and tempo confidence stays < 0.4 for ≥ 90 %
  of the run.
* All musical cases: total accepted trigger rate within **0.5–5.0 Hz**.

---

**M6 — Universality (the anti-per-song-tuning gate).**

> For every case in the battery, log the *normalised control signals* — not the
> visuals. Within 5 s of start, and for the remainder of the run:
> `mean(AVERAGE_RELATIVE_b) ∈ [0.85, 1.20]` for every band with signal present,
> and the board-mean brightness across cases has a coefficient of variation
> ≤ 0.25.

* Any case that needs a per-genre constant to pass **means the normalisation
  layer is wrong**, not that the case is unusual. There is no case-specific
  tuning knob in the harness and none may be added.
* `near-silence` is exempt from the relative-value bound (there is no signal) but
  must satisfy board-mean brightness ≤ 0.03.

---

**M7 — Timing integrity (telemetry, from hardware and from viz-sim).**

* Render tick interval: `p95 ≤ 1.15 · dt_f`, `max ≤ 2 · dt_f`. This is a property
  of the fixed clock and must hold *regardless* of transport behaviour (P6).
* Delivered-frame rate ≥ 80 % of render rate on typical material; dropped frames
  are reported, never hidden.
* Stale-frame rate (interpolation ran out of analysis states, §6.1) ≤ 1 %.
* Worst observed end-to-end stall ≤ 250 ms.

---

**M8 — Beat alignment `beatError` (new in r2). The numerical statement of "the
keyboard updates feel off beat".**

Computed on the click-track cases, where the true beat times `B_i` are exact,
**with the `/latency` arm on** so the simulated pipeline latency is included.
Let `b(t)` be board-mean linear lightness sampled at the *displayed* frame times
(i.e. `t_scheduled + L_out`), and `P` the true beat period.

> For each beat `B_i`:
> ```
> f_i = min  b(t)  over t ∈ [B_i − 0.45·P, B_i]          // pre-beat trough
> p_i = max  b(t)  over t ∈ [B_i − 0.25·P, B_i + 0.35·P] // the gesture's crest
> h_i = f_i + 0.5·(p_i − f_i)                            // half-rise level
> G_i = the earliest t in that window with b(t) ≥ h_i,
>       LINEARLY INTERPOLATED between the two bracketing displayed frames
> e_i = G_i − B_i                                        // signed, seconds
> ```
> Report `MAE = mean |e_i|`, `bias = mean e_i`, `sd = sd(e_i)`, all in ms.

The half-rise crossing is used because it is the same instant §2.3.3 schedules
against (`t_vis = startTime + τ_a·ln 2`), so the metric and the mechanism agree
on what "the gesture happened" means. **Linear interpolation between frames is
mandatory**: quantising `G_i` to `dt_f` would put a 33 ms floor under a metric
whose threshold is 30 ms.

* **Bounds** on `click-120`, `click-112`, `edm-128`, `dnb-174`, in **pulse** and
  **wave** (the two beat-scheduled modes), at 30 fps, `/latency`:
  * **`MAE ≤ 30 ms`** — pass. 30–45 ms warn, > 45 ms fail.
  * **`sd(e_i) ≤ 25 ms`** — *this is the important one.* A constant offset is
    dialled out by §8.3's user control; the spread is what an offset cannot fix
    and what "off beat" actually feels like.
  * **`|bias| ≤ 20 ms`** — reported separately from MAE precisely so that a
    systematic lead/lag is not confused with a wandering one.
  * **miss rate ≤ 5 %**, where a miss is a beat with `p_i − f_i < 0.04`.
* On `click-90-ramp`: `MAE ≤ 45 ms` during the 10 s tempo ramp, and back under
  30 ms within 4 s of the ramp ending.
* **Anti-vacuity, both asserted:**
  1. the run must produce **≥ 0.8 gestures per beat** (`p_i − f_i ≥ 0.04` on
     ≥ 95 % of beats) — otherwise "no gesture at all" passes trivially, since a
     flat board has no alignment error;
  2. **`click-120-gap`: zero frames** with a rise of ≥ 0.04 above the pre-gap
     baseline during the last 3 s of the 4 s gap. One phantom beat after the
     music stops is allowed (the credit counter needs two misses to react); a
     board that keeps beating is a fail. This is the direct test of §2.3.4.

---

**M9 — Accumulation and memory (new in r2). The numerical statement of "there's
no short-term accumulation — it's like a cliff".**

Let `b(f)` be board-mean linear lightness per displayed frame, `f = 0 … F−1`,
sampled at `1/dt_f`.

**M9a — slow-band fraction `SBF`.**

> `b'(f) = b(f) − mean(b)`. Welch power spectrum: 8 s Hann segments, 50 %
> overlap, one-sided, → `S(ν)`.
> ```
> SBF = Σ_{0 < ν ≤ 0.5 Hz} S(ν)  /  Σ_{0 < ν ≤ 8 Hz} S(ν)
> ```
> DC is excluded (that is the bed, measured by M9c). 8 Hz is the ceiling because
> it is the display's own Nyquist at 15 fps.

* **`SBF ≥ 0.35`** on `edm-128`, `ballad-72`, `dnb-174`;
  **`SBF ≥ 0.55`** on `crescendo` and `build-drop`.
* Defined as **0 (fail)** when total power `< 1e-8` — a frozen board must not
  score infinity.
* **Anti-vacuity: M9a counts as passed only if M2's *lower* bound passes on the
  same run.** Otherwise the trivial way to win is to smooth everything into
  mush, which is the opposite failure and is already the reason M2 is bounded on
  both sides.

**M9b — a build shows as a build.**

> On `build-drop` and `crescendo`, using the generator's own ground-truth RMS:
> `r(t)` = input RMS low-passed with a 1.0 s one-pole, resampled to the frame
> grid. `b(t)` as above. Both z-scored over the run.
> ```
> ρ_build = Pearson(r, b)                                     // whole-run
> ρ_slow  = Pearson(lowpass_0.25Hz(r), lowpass_0.25Hz(b))     // multi-second
> dropContrast = mean(b) over the drop − mean(b) over the intro   // linear
> ```

* **`ρ_slow ≥ 0.80`**, **`ρ_build ≥ 0.60`**, **`dropContrast ≥ 0.18`**.
* `dropContrast` is there because a correlation of 0.9 across a 3 % slice of the
  range is invisible on hardware. Correlation says the shape is right; contrast
  says it is big enough to see.

**M9c — never dead while playing `DeadFrac`.**

> Over frames whose *input* satisfies `rms(t) ≥ p20(rms)` over the run — i.e.
> music is genuinely playing, defined from the ground-truth track and not from
> our own analyser:
> ```
> DeadFrac = fraction of those frames with b(f) < 0.06
> ```

* **`DeadFrac ≤ 0.01`** on every musical case; **`≤ 0.05`** on `cut-transitions`
  (which contains real silences by construction, and §11.3's 4 s hold + 8 s
  ramp-out means only their tails count).
* **The complement is asserted at the same time**, so the two cannot both be
  satisfied by a constant glow: `near-silence` board-mean `≤ 0.03` (M6,
  restated), and in `cut-transitions` the board-mean must be `≤ 0.03` by 10 s
  into any silence.

**M9d — memory horizon `τ_mem` (diagnostic, reported, not gated).**

> Autocorrelation of `b'(f)`; report the lag at which it first falls below
> `1/e`. Expected `≥ 1.5 s` once §11 lands.

Reported rather than gated so that a change which shortens the board's memory is
*visible* even while `SBF` still passes, which is exactly how the cliff got
through r1's battery.

---

**M10 — Spatial diversity (new in r2). The numerical statement of "the colour is
concentrated in the centre and isn't diverse".**

Computed from the per-frame **RGB** export. Per LED per frame, convert to HSV:
hue `h_k(f) ∈ [0,1)`, saturation `s_k(f)`, value `v_k(f)`.

**M10a — within-frame hue spread `σ_h`.**

Hue is circular, and a hue on a dark key is not visible, so: brightness-weighted
circular standard deviation.

> ```
> w_k = v_k(f)
> C = Σ w_k cos(2π h_k) / Σ w_k ;  S = Σ w_k sin(2π h_k) / Σ w_k
> R = sqrt(C² + S²)
> σ_h(f) = sqrt( −2 · ln R ) / (2π)          // in TURNS
> ```
> Computed only on frames where `(Σ w_k)/K ≥ 0.06` — the board is showing
> something. Report `median_f σ_h` and `p05_f σ_h`.

* **`median_f σ_h ≥ 0.035` turns (≈ 12.6°)** on all musical cases;
  **`≥ 0.055` turns (≈ 20°)** on `edm-128` and in `spectrum` mode.
* **Upper guard: `median_f σ_h ≤ 0.20` turns (≈ 72°)** — this is what stops the
  fix becoming rainbow vomit, and it *replaces* r1's blanket ±0.08 rule, which
  is now a per-gesture deposit limit (§12.3) rather than a board-wide one.
* **`p05_f σ_h ≥ 0.015`** — no frame may be monochrome.
* r1 scores **≈ 0** here by construction: one hue for the whole board.

**M10a hue motion `μ_h` — the anti-vacuity companion (new in r2.1), and it is a
coupling, not an independent row.**

> Per frame, let `h(x,f)` be column `x`'s brightness-weighted circular mean hue
> and `p(x,f) = wrap(h(x,f) − mean_x h)` the frame's hue *profile* — the shape of
> the field with the palette's own rotation removed. Let `p̄(x)` be the circular
> mean profile over the run. Then
> ```
> μ_h = median_f  sqrt( mean_x wrap(p(x,f) − p̄(x))² )
> ```
> **Bound: `μ_h ≥ 0.010` turns** on every case M10a applies to.

Why it is load-bearing: **M10a and M10b can both be passed with no audio input at
all.** A board built from a static ±0.30-turn hue gradient plus §12.1's constant
`1/180` turn-per-second clock — literally `H0` and `A·G` with the music taken
out — scores `median σ_h` 0.091, `p05` 0.079 and hue drift 0.048 through the
shipped measurement, i.e. it passes M10a and M10b outright. What that board
cannot do is change the *shape* of the gradient, and §12.1 makes the shape
follow the music twice over: the boundary `x_c` is the spectral centroid and the
fan width `A` is the spectral spread. `μ_h` is exactly zero for any hue field
that is a fixed function of column, however fast the palette rotates.

**M10b — hue must also move in time, but not spin.**

> `sd over time of the brightness-weighted circular mean hue`, over a 30 s
> musical run.

* **`≥ 0.02` turns** (the palette follows the music, §12.1's drift and structure
  kicks) and **`≤ 0.25` turns** (it is not a rainbow cycle).
* Stated separately from M10a so that neither can substitute for the other: a
  board that changes colour over time but is monochrome in every frame fails
  M10a, and a fixed rainbow gradient fails M10b.

**M10c — brightness centre of mass.**

> Per frame, with `v̄(x,f)` the mean value over column `x`'s LEDs, `x ∈ 0…16`:
> ```
> x̄(f) = Σ_x v̄(x,f)·x / Σ_x v̄(x,f)
> ```
> Counted only on frames with `Σ_x v̄ ≥ 0.06 · 17`. Report `mean_f x̄`,
> `sd_f x̄`, `p05`, `p95`.

* **`|mean_f x̄ − 8.0| ≥ 0.5` columns** on `edm-128`, `dnb-174`, `ballad-72`, in
  **pulse**, **ripple** and **spectrum**. *VU is exempt from this clause only* —
  it is a centre-out meter by design (§9.5) — but not from the two below.
* **`sd_f x̄ ≥ 1.5` columns** on every musical case, every mode.
* **`p95(x̄) − p05(x̄) ≥ 4.0` columns** — the bright region must visit different
  parts of the board, not merely wobble.

**M10d — column starvation (§12.5's uniformity target).**

> `V(x) = mean_f v̄(x,f)` over the run.

* **`0.5 · mean_x V(x) ≤ V(x) ≤ 1.8 · mean_x V(x)`** for every column.
* **This clause and M10c are checked together and are deliberately in tension.**
  A uniformly lit board passes M10d trivially and fails M10c's `sd` and M10a's
  hue spread; a board that parks a bright spot fails M10d. Neither degenerate
  solution passes the pair, which is what makes the metric non-vacuous.

---

### 10.3 Pass criteria summary

| metric | bound | applies to |
|---|---|---|
| M1 flicker p95 | ≤ 1.5 cycles/key-s (≤ 0.1 on stationary) | all cases, all modes |
| M1 flicker mean | ≤ 0.8 cycles/key-s | all |
| M2 Δframe mean | 0.010 … 0.075 | musical cases |
| M2 Δframe p95 | ≤ 0.22 | all |
| M3 latency median | ≤ 2.0 frames | rhythmic cases |
| M3 latency p90 | ≤ 3.5 frames | rhythmic cases |
| M3 miss rate | ≤ 5 % | rhythmic cases |
| M4 onDuration median | ≥ 0.25 s | musical cases |
| M4 onDuration p10 | ≥ 0.15 s | all |
| M5 false onsets | 0 on stationary/noise | stationary, noise |
| M5 trigger rate | 0.5 … 5.0 Hz | musical cases |
| M6 AVERAGE_RELATIVE mean | 0.85 … 1.20 | all with signal |
| M7 tick p95 | ≤ 1.15 · dt_f | hardware + sim |
| M7 tick max | ≤ 2 · dt_f | hardware + sim |
| M7 delivered frames | ≥ 80 % of render rate | hardware + sim |
| M7 stale frames | ≤ 1 % | hardware + sim |
| **M8 MAE** | **≤ 30 ms** | click cases, edm-128, dnb-174 · pulse, wave · `/latency` |
| **M8 sd(e)** | **≤ 25 ms** | as above |
| **M8 bias** | **\|bias\| ≤ 20 ms** | as above |
| **M8 miss rate** | **≤ 5 %** | as above |
| **M8 gestures/beat** | **≥ 0.8** (anti-vacuity) | as above |
| **M8 phantom beats** | **0 in the last 3 s of the gap** | `click-120-gap` |
| **M9a SBF** | **≥ 0.35** (≥ 0.55 on crescendo, build-drop) | musical cases — *only counts if M2 lower bound passes* |
| **M9b ρ_slow / ρ_build** | **≥ 0.80 / ≥ 0.60** | `build-drop`, `crescendo` |
| **M9b dropContrast** | **≥ 0.18** | `build-drop` |
| **M9c DeadFrac** | **≤ 0.01** (≤ 0.05 on cut-transitions) | musical cases |
| **M9c silence complement** | board-mean ≤ 0.03 after 10 s of silence | `near-silence`, `cut-transitions` |
| **M9d τ_mem** | reported, expect ≥ 1.5 s | all — diagnostic only |
| **M10a median σ_h** | **0.035 … 0.20 turns** (≥ 0.055 on edm-128, spectrum) | musical cases |
| **M10a p05 σ_h** | **≥ 0.015 turns** | musical cases |
| **M10a hue motion μ_h** | **≥ 0.010 turns** | musical cases — *the anti-vacuity coupling for M10a and M10b* |
| **M10b hue drift sd** | **0.02 … 0.25 turns** | musical cases |
| **M10c \|mean x̄ − 8\|** | **≥ 0.5 col** | pulse, ripple, spectrum (VU exempt) |
| **M10c sd(x̄)** | **≥ 1.5 col** | all musical, all modes |
| **M10c p95−p05(x̄)** | **≥ 4.0 col** | all musical, all modes |
| **M10d column starvation** | **0.5× … 1.8× the column mean** | all musical, all modes |
| **§7.2-R packets/frame** | median ≤ 2, p95 ≤ 4, **max ≤ 7 (invariant, unit-tested)**, fallback ≤ 5 % | sim + hardware |
| **M8 credit misses** | **≥ 2** — §2.3.4's counter must be what stopped the board | `click-120-gap` |
| **M9c silence complement** | board-mean ≤ 0.03, 10 s into a ground-truth silence | `music-then-room` |

`viz-sim --battery` runs the full matrix (**20** signals × 5 modes × **7** arms)
and prints a pass/fail table. It is a CI gate: a change that
regresses any bound is rejected regardless of how it looks on any one track.

**Five anti-vacuity couplings are load-bearing and must be implemented as
couplings, not as independent rows** — an implementer who evaluates them
separately can satisfy every bound with a board nobody wants to look at:

1. **M9a requires M2's lower bound.** Slow variance is trivially maximised by a
   board that barely moves.
2. **M10c and M10d are a pair.** Uniform passes one and fails the other;
   parked-bright-spot does the reverse.
3. **M8 requires the gestures-per-beat floor.** A flat board has perfect beat
   alignment because it has no beats.
4. **M10a and M10b require `μ_h`** (added in r2.1). Both are satisfied by a
   static gradient on a timer, with the audio disconnected.
5. **M9c's `DeadFrac` requires its silence complement**, and the complement must
   be *emitted*: a bound that no case in the battery can reach is not a coupling,
   it is a comment. `music-then-room` exists for this and for nothing else.

**And the couplings must be asserted on every arm.** M9a's coupling to M2 was
switched off wherever M2's lower bound was, which was the `/quiet` and `/loud`
arms — so on two arms in seven the slow-band fraction was asserted with its
liveliness half missing. The user's sensitivity is `1 − (1 − x)^s`, monotone and
exactly invertible, so the fix is to measure the *model's* levels rather than the
output gain's: `viz-sim` inverts the curve before computing any metric, and M2's
lower bound, M3's rise threshold, M9a's coupling and M9c are then asked
everywhere.

Equally, the r1 couplings still stand: M1/M4 must keep measuring the *model*,
which is why §11.4's bed guarantee is a board-mean and not a per-key floor.

**Two bounds are invariants, not measurements, and are reported rather than
gated in `viz-sim` (r2.1).** A check that cannot fail is not a gate:

* **M7's two tick clauses.** In the simulator the render clock is not measured,
  it is *defined* — every frame is composed for `frame · dt_f` — so across 665
  runs the interval took exactly two values, `dt_f` and `2·dt_f`, and neither
  bound could ever fail. The clauses stay normative **on hardware**, where the
  wake-up is real; in the simulator they are telemetry, and the invariant is
  proved directly by a unit test.
* **§7.2-R's `max ≤ 7`.** `FramePackets.plan` falls back to a repaint above five
  packets and a repaint of 126 keys is `ceil(126/18) = 7`, so the value lies in
  `{0…5, 7}` by construction. Proved as an invariant over random change sets
  including the pathological strides, and reported here.

### 10.4 What the metrics do NOT cover

Stated so nobody claims more than is measured: these metrics cannot tell you
whether the visualiser is *beautiful*, whether the colour choices are good, or
whether a gesture feels musically apt. They bound jitter, deadness, latency,
hold, false triggering and universality. Aesthetic judgement still requires
watching `animation.mp4` and the hardware.

> **Amended (r2).** M8, M9 and M10 widen the net but do not change this
> disclaimer, and it is worth being precise about how:
>
> * M10 bounds *hue diversity and spatial distribution*. It says nothing about
>   whether the palette is **attractive** — a board fanning garish magenta
>   through lime scores identically to one fanning amber through teal. The
>   0.20-turn upper guard is the only taste-adjacent bound in the system, and it
>   is a bound on quantity, not on choice.
> * M9 bounds *whether the board has memory*. It cannot say whether the memory
>   is on the **right** timescale for a given genre; a visualiser that tracked
>   the wrong structural layer consistently would pass.
> * M8 bounds *alignment to a click*. Real music has swing, rubato, and
>   producers who place the kick 8 ms early on purpose. A perfect M8 on a click
>   track is necessary and not sufficient.
>
> The three complaints r2 answers are now falsifiable. Whether the answer is
> *good* is still a question for the hardware.

### 10.5 Open measurement gaps to close first

1. **Frame-interval distribution on real hardware** — p50/p95/max of the render
   tick and of the per-packet echo round trip. The counters exist and are now
   read: `VisualizerController` summarises the render telemetry and the frame
   slot's delivered/dropped counts at the end of every run and shows them on the
   menu item. The echo round trip itself is still unrecorded.
2. **Clap-test end-to-end latency** with a 240 fps camera, to set the §8.3
   default offset.
3. ~~**The discriminating experiment, before any code changes**: ask whether
   `spectrum` and `vu` (the two modes that do not consume onsets) feel calmer
   than `pulse`/`wave`/`ripple`.~~ **Closed by r1's ship:** all five feel calmer,
   the detector fix landed, and the surviving complaints are the three §r2
   answers.

**Open gaps added in r2** — in the order they block the migration:

4. **The echo round-trip time is still unrecorded**, and it is now load-bearing:
   `L̂` (§8.2-R) is built from it, and the §7.2-R packet budget cannot be
   checked without it. This is the single highest-value instrumentation left.
5. **`σ_φ` has never been measured on real music.** BPM sd is 0.04; phase sd is
   unknown. The entire "off beat" complaint lives in that number and §2.3.2 is
   the first thing that will look at it. Measure it *before* implementing the
   scheduling, so that the scheduling has something to be judged against.
6. **The system-audio tap's delivered buffer size** — assumed, never logged.
   §2 requires the `burstyDeliveries` counter before any claim about capture
   latency on that path is defensible.
7. **Which timescale the user is actually missing.** §11 asserts PHRASE
   (0.5–2 s) and SECTION (10–30 s) as the two additions. That is a hypothesis
   drawn from the phrase "short term accumulation" plus the structure of popular
   music; it is not measured. Once §11 ships, the falsifiable follow-up is
   whether varying `Φ`'s release between 0.8 s and 3 s changes the verdict, and
   the answer belongs in this document rather than in a commit message.

**Open gaps added in r2.1** — these are places where two clauses of *this
document* are in tension, found by making the metrics able to fail. None of them
is a tuning error and none should be swept for again without reading this first.

8. **`E`'s single dynamic-range floor cannot serve both `crescendo` and
   `build-drop`.** `E = (Λ − R_lo)/max(R_hi − R_lo, floor)` with a slow `R_lo`
   saturates exactly `floor` decibels above where a monotone rise started.
   `crescendo`'s RMS envelope spans 66 dB and `build-drop`'s spans 20 dB, so
   `crescendo` needs a wide floor and `build-drop`'s `dropContrast ≥ 0.18` needs
   a narrow one. Letting `R_hi` chase the ramp instead makes `E ≡ 1` for the
   whole rise — §11.0's own defect by another route — because *no causal
   percentile normaliser can represent a monotone ramp*. Measured at HEAD:
   `crescendo/pulse` ρ_slow 0.218, `build-drop/pulse` ρ_slow 0.725, against
   0.80. Either M9b's bound on `crescendo` is a claim P1 cannot support, or `E`
   needs a second, non-percentile reference. This has to be settled in the
   design before it is settled in a constant.
9. **M9a's `SBF ≥ 0.35` on `edm-128` and `dnb-174` asks a strictly periodic loop
   to produce sub-0.5 Hz power.** Both generators repeat exactly every one or two
   beats — 1.07 Hz and above — so their input contains no energy below 0.5 Hz at
   all, and a display that tracked them perfectly would score near zero. The
   bound is well posed on `crescendo` and `build-drop`, which have structure; on
   the two steady loops it is asking the board to invent some. Measured at HEAD:
   `edm-128/pulse` 0.153, `dnb-174` 0.044.
10. **M10c's `sd(x̄) ≥ 1.5` columns is stated for every mode, including the two
    whose identity is to be symmetric.** `pulse` is "the board breathes" and `vu`
    is a centre-out meter; both have a brightness centre of mass pinned near
    column 8 by construction, and §12.4's own `shape` — a 25 % tilt across 16
    columns — can move it by at most ±0.4. Reaching 1.5 requires the accent to
    carry roughly half the board's light, which is a different mode. Measured at
    HEAD: 230 of 245 checks fail, values 0.31–2.17.
11. **M1/M4's on-level (0.10) sits between the interlock's fall (0.06) and rise
    (0.14) thresholds**, so "lit" and "on" are not the same predicate: a key the
    interlock is holding can be measured off, and §6.3's minimum on-time
    therefore does *not* guarantee M4's `p10 ≥ 0.15 s` the way §10.2 says it
    does. Closing the gap means moving one of the three numbers, and which one is
    a design question: 0.10 in linear lightness is PWM code 2 of 255, i.e. all
    three thresholds describe a nearly-black key.

---

## Appendix A — every constant, in one table

Time constants in seconds. Nothing here was derived from a song.

| symbol | value | §|
|---|---|---|
| analysis hop | 512 @ 48 kHz (93.75 Hz) | 2 |
| analysis window | 2048 Hann | 2 |
| render `dt_f` | 1/30 s (configurable 15/20/24/30) | 1.1 |
| whitening τ_w | 3.7 s | 3.1 |
| whitening floor | 2 × p10 per bin | 3.1 |
| short avg τ_rise / τ_fall | 20 ms / 50 ms | 3.2 |
| long avg τ | 4.0 s (0.32 s for first 50 hops) | 3.2 |
| percentile window | 10 s (0.5 s in escape zones) | 3.3 |
| percentiles | p10 floor, p90 reference | 3.3 |
| gain clamp | 1/16 … 16 | 3.3 |
| gate open / close | CURRENT_REL > 1.30 / AVERAGE_REL < 1.10 | 3.4 |
| gate hold-open | 120 ms | 3.4 |
| gate ramp-out τ | 400 ms | 3.4 |
| flux median span | 11 hops (~117 ms) | 2.2 |
| flux threshold | med + 3.0·MAD, and > 1.6·med | 2.2 |
| onset SNR test | CURRENT_REL > 1.30, the same margin as the gate | 2.2 |
| onset weakest-band test | > 1.00 (kick, hat), > 1.15 (snare, where the voice lives) | 2.2 |
| arbiter window | 25 ms, weights 1.0/0.9/0.8 | 2.2 |
| arbiter same-precedence block | 330 ms | 2.2 |
| arbiter cross-kind shadow | 330 ms over a snare, 200 ms over a hat | 2.2 |
| liveliness gate | floor 1.30, full 1.55 — a ramp, not a switch | 2.2 |
| beat grid grounding | full within 2 s of an onset, abandoned after 4 s | 2.3 |
| refractory | 120 ms (160 ms hat) | 4.4 |
| kick AHR | 15 / 100 / 320 ms | 4.1 |
| snare AHR | 8 / 80 / 240 ms | 4.1 |
| hat AHR | 5 / 60 / 200 ms | 4.1 |
| body AHR | 50 / 0 / 500 ms | 4.1 |
| VU AHR | 150 / 0 / 1000 ms | 4.1 |
| master AHR | 300 / 0 / 1200 ms | 4.1 |
| release clamp | ≥ max(3·dt_f, 200 ms) | 4.2 |
| phase correction | 20 % per beat; tempo ±2 %/beat | 2.3 |
| confidence cross-fade | below 0.35, over 1.5 s | 2.3 |
| velocity clamp | 2 cells/frame | 5.4 |
| key rise / fall threshold | 0.14 / 0.06 | 6.3 |
| **key minimum on-time** | **150 ms** | 6.3 |
| **key minimum off-time** | **100 ms** | 6.3 |
| key down-slew | ≥ 200 ms full→black | 6.3 |
| peak gravity fall | 150 ms per row — the slow end of §6.4's window | 6.4 |
| register peak-hold | 150 ms, the §6.3 minimum on-time | 6.4 |
| resting wash AHR | 50 / 0 / 600 ms, over §9's own floors | 9 |
| analysis-clock slew | 2 % per buffer, resync above 250 ms | 1.1 |
| user sensitivity | 0.5 … 2.0, as `1 − (1 − x)^s` after the interlock | 6.3 |
| spatial blur σ | 1.0 cell | 6.2 |
| gamma | 2.2 | 6.5 |
| extrapolation limit | 20 ms | 6.1 |
| replyTimeout / attempts | 60 ms / 2 | 7 |

**Added in r2.** Still nothing derived from a song: time constants, perceptual
constants, wire-format constants, and dimensionless ratios.

| symbol | value | § |
|---|---|---|
| capture buffer | = 1 hop (512 @ 48 kHz); larger is a defect, smaller is a no-op | 2 |
| bursty-delivery budget | ≤ 1 % of deliveries > 2 hops | 2 |
| phase-error window | last 8 corrections → `σ_φ` | 2.3.2 |
| lead weight ramp | `smoothstep(0.12, 0.06, σ_φ) · gridWeight` | 2.3.2 |
| gesture visible onset | `startTime + τ_a · ln 2` (half-rise) | 2.3.3 |
| provisional amplitude γ | 0.6 of the 4-beat EWMA of confirmed amplitudes | 2.3.4 |
| confirmation window W | ±90 ms | 2.3.4 |
| prediction credit | +1 confirm / −2 miss, clamp [−4, +4], launch at ≥ +1 | 2.3.4 |
| run-bridge gap G | 4 unchanged keys | 7.2 |
| scattered-set fallback | `packets ≥ ceil(changed/18) + 2` or `packets > 5` → full repaint | 7.2 |
| packet budget | median ≤ 2, p95 ≤ 4, max 7, fallback ≤ 5 % | 7.2 |
| `T_unavoidable` target | ≤ 40 ms | 8.1 |
| `L̂` smoothing / clamp | EWMA τ 5 s; clamp [0, 150 ms]; ≤ 5 ms change per second | 8.2 |
| energy reference window | 60 s (p05 / p95 of `Λ`) | 11.1 |
| energy dynamic-range floor | 6 dB | 11.1 |
| PHRASE `Φ` AHR | 350 ms / 250 ms hold / 1600 ms | 11.2 |
| SECTION `Σ` | τ_up 8 s, τ_down 20 s (asymmetric) | 11.3 |
| section novelty escape | `D > 0.35` for 1.5 s → τ 3 s; **upward only** unless `E < 0.15` for 3 s | 11.3 |
| `Σ` fall rate limit | 0.25 per second, always | 11.3 |
| silence ramp-out | starts at 4 s of `E < 0.05`, black by 8 s | 11.3 |
| bed `B0` / `B1` | 0.09 / 0.15 | 11.4 |
| swell `S1` / `k` | 0.55 / 0.85 | 11.4 |
| accent `A1` | 0.90, scaled by `headroom` | 11.4 |
| hue drift ω0 | 1/180 turns per second, × `(0.25 + 0.75 Σ)` | 12.1 |
| structure hue kick | 0.11 turns, eased over 2 s | 12.1 |
| gradient amplitude `A_max` | 0.30 turns × spectral spread | 12.1 |
| gradient AHR | 50 ms / 0 / 800 ms | 12.1 |
| saturation `S0` / `S1` | 0.45 / 0.55 | 12.2 |
| hue trail τ | 900 ms; deposit τ 120 ms; clamp ±0.18 turns | 12.3 |
| saturation trail τ | 600 ms | 12.3 |
| per-gesture hue deposit ν | kick −0.08, snare 0, hat +0.08 turns | 12.3 |
| gesture origin map | `round((b + 0.5)/8 · 16)` → cols 1,3,5,7,9,11,13,15 | 12.4 |
| pulse shape | `1 − 0.25 · abs(x − x_c(t)) / 16` | 12.4 |
| column uniformity band | 0.5× … 1.8× the column mean | 12.5 |
| simulated output latency | 12 ms (`/latency` arm) | 10.1 |

**Added in r2.1 — constants the implementation introduced and this table did
not name.** Every one of them was in the code and in none of the deviation
tables; a constant that is not in Appendix A is a constant nobody can audit.

| symbol | value | § | why it is not in the r2 table above |
|---|---|---|---|
| energy dynamic-range floor | **18 dB**, not §11.1's 6 dB | 11.1 | at 6 dB `E` saturates six decibels above the noise floor and carries no dynamics at all. See §10.5 gap 6: no single value satisfies both `crescendo` and `build-drop` |
| energy reference max range | 40 dB (`R_lo ≥ R_hi − 40`) | 11.1 | a p05 falls nineteen times faster than it rises, so one stretch of digital silence pins the floor for minutes and `E` reads 1.000 for ever. A ratio between two observed quantities, so P1 holds |
| energy soft knee | starts at 0.5 of the span | 11.1 | §11.1 writes a hard clamp; a clamp makes every level above p95 identical, which is the failure §11 exists to remove |
| accent context gain | `0.70 + 0.30·Φ` | 11.4 | §11.4 scales the accent by `headroom`, which *shrinks* as the section gets loud, so a soft intro kick painted the same board as a drop kick and `dropContrast` measured 0.05 |
| pulse gesture crest | σ = 3.0 columns, pedestal 0.40 | 12.4 | §12.4 specifies pulse's `shape` and says nothing about the gesture's own kernel. The pedestal is what keeps "the board breathes" true while the crest carries the register |
| VU arm bed floor | 0.62 (not 0.45) | 12.4 | a meter that only occasionally reaches its outermost columns starves them, and M10d bounds every column to 0.5…1.8× the board's own column mean |
| M8 warm-up | 8 s | 10.2 | §2.3's tracker autocorrelates over 8 s and requires three agreeing estimates; alignment measured before any of that is the lock-in transient |
| M10a hue motion floor | 0.010 turns | 10.2 | new in r2.1 — the anti-vacuity companion to M10a and M10b, below |

## Appendix B — migration order

Highest leverage first; each step is independently shippable and independently
measurable against §10.

1. **viz-sim temporal metrics + battery + ground-truth onset assertions** (§10).
   Nothing else can be defended until the tool can see the defect. This step
   alone should reproduce every number in the audit.
2. **Onset detector** (§2.2): whitening, MAD threshold, relative SNR test,
   cross-band arbiter. Dominant cause; four of five modes get better at once.
3. **AHR ballistics with enforced clamps** (§4) and the per-key interlock (§6.3).
   Together these make M1/M4 pass structurally.
4. **Relative band values + percentile AGC** (§3.2–3.4), retiring
   `NoiseFloorTracker` and `LoudnessReference`.
5. **Fixed-rate render clock + FrameSlot + transport diffing** (§1.1, §7).
6. **Interpolation and peak-hold across analysis hops** (§6.1), fractional fills
   and gamma (§6.5), delete `widenIsolatedColumns` (§6.2).
7. **Modes re-specified as gestures** (§5, §9).
8. **Mouse structural layer** (§9.6).

## Appendix B2 — migration order for r2 (new)

Steps 1–8 above are done and shipped. What follows is ordered by *how much of
the user's three complaints each step retires per unit of risk*, and each step is
independently shippable and independently measurable.

1. **Metrics first, again** (§10.1, §10.2): the five new signals, the
   `/latency` arm, the RGB and ground-truth exports, and M8/M9/M10. Nothing
   below can be defended until the tool can see the three defects — and it
   currently cannot see any of them. Expect this step to *fail loudly* on the
   shipped build: M9a ≈ 0, M10a ≈ 0, M8 sd large. If it does not, the metric is
   wrong, not the build.
2. **§11 multi-timescale energy.** The largest single perceptual change, and the
   one with no dependencies: `E`, `Φ`, `Σ`, the composition formula, and the
   deletion of every per-mode bed. Retires complaint 2 on its own and improves
   complaint 3 for free, because a board that is never at zero has something for
   colour to live on.
3. **§12 spatial colour and propagation.** Depends on §11 only for `Φ`/`Σ` in
   the drift and saturation terms. Retires complaint 3.
4. **§2.3-R phase publication and `σ_φ`.** Small, self-contained, and it is the
   measurement that tells you whether step 5 is even worth doing.
5. **§8.2-R measured `L̂` + §2.3.3 schedule-to-land + §2.3.4 credit.** Retires
   complaint 1. Do not attempt this before step 4: scheduling against an
   unmeasured latency is what r1 already did.
6. **§7.2-R packet builder budget and telemetry**, then re-evaluate the render
   rate against §8.1-R's note — 40–48 fps is the only remaining lever on
   `T_unavoidable`, and it is gated on measured delivery, not on optimism.
7. **§2 system-audio buffer bounding** and the `burstyDeliveries` counter.
8. Re-run the clap test (§8.3) and set the shipped default user offset from the
   measured `bias` in M8 rather than from the r1 default.
