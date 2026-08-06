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
10. [Verification: the universal test battery and pass metrics](#10-verification)

Appendix A restates every constant in one table. Appendix B is the migration
order.

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

**Mic path:** `MicrophoneCapture.bufferSize` must drop from 2048 (42.7 ms, and
it delivers four hops in a burst) to 256 or 512. The audio callback now only
copies into the ring, so a small buffer is cheap.

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

### 2.3 Tempo and phase

The existing autocorrelation → harmonic-sum → median-lock chain measures well
(120.0 BPM median, 100 % of frames within 3 % on the tuning signal) and is kept.
What changes is what is published and how it is corrected:

* Publish `(bpm, phase φ ∈ [0,1), confidence)` — a **continuously advancing
  phase**, not a stream of beat triggers. `φ` advances as `φ += dt/beatPeriod`
  every analysis hop, always, even when detection fails.
* **Phase is corrected gradually, never snapped.** On a detected beat, `φ` moves
  20 % of the way toward 0 (`φ ← φ · 0.8` modulo wrap, taking the shorter
  direction). Tempo changes are rate-limited to ±2 % per beat and require three
  consecutive agreeing estimates. This is BTrack's prior-weighted design: new
  evidence never overrides an established hypothesis in one step.
* **Confidence gates beat-locked behaviour.** `confidence < 0.35` (ambient,
  rubato, spoken word) cross-fades gestures from beat-scheduled to
  envelope-driven over 1.5 s. Never a hard switch — a visibly wrong beat grid is
  worse than no beat grid.
* **Predictive scheduling.** With tempo locked, beat-driven gestures are
  scheduled at *predicted* beat times minus the measured pipeline latency
  (§8.2), which makes their visible latency ≈ 0.

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

### 8.1 Budget, current vs designed

| stage | today | designed | how it is trimmed |
|---|---|---|---|
| capture buffer | 10.7 ms tap / **42.7 ms mic** | 5.3–10.7 ms | mic buffer 2048 → 256/512; audio callback only copies |
| FFT group delay | ~21 ms | ~21 ms | unchanged — window size is set by frequency resolution, latency by hop |
| hop / peak-pick delay | +10.7 ms (reports `recent[1]`) | +10.7 ms | unchanged; the median window is causal-lagged by one hop and that is the price of the adaptive threshold |
| envelope attack | up to 100 ms on some paths | 5–15 ms on accents | front-load the attack (§4.1). An 80 ms attack *is* 80 ms of latency |
| analysis→render handoff | arbitrary phase, up to 66.7 ms | ≤ 5 ms | interpolate/extrapolate to `t_frame` (§6.1) instead of latching |
| frame quantisation | 66.7 ms | 33.3 ms | fixed 30 fps clock |
| transport | 30–55 ms, **1.5–4 s worst** | 10–25 ms, ≤ 145 ms worst | diffing, tighter timeouts, packet-scoped silence |
| **total** | **95–220 ms, pathological seconds** | **≈ 55–90 ms, worst ≈ 210 ms** | |

### 8.2 Negative latency for beat-locked content

Once tempo confidence > 0.6, beat-driven gestures are scheduled at
`predictedBeatTime − measuredPipelineLatency`, making their *visible* latency
zero or slightly negative. Most of the perceived "liveness" of a music
visualiser is beat-locked content, so this matters more than the raw number.
Non-beat-locked detail (fills, vocal transients) still runs at the measured
budget, which is why that budget must stay under ~90 ms.

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
* colour comes from the theme; hue variation is bounded to ±0.08 to avoid the
  rainbow-vomit failure mode,
* all thresholds are in `CURRENT_RELATIVE` / `AVERAGE_RELATIVE` units,
* all rendering is `f(t_frame)`,
* the §6.3 per-key interlock applies unconditionally.

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

`viz-sim --battery` runs the full matrix (14 signals × 5 modes × 6 arms) and
prints a pass/fail table. It is a CI gate: a change that
regresses any bound is rejected regardless of how it looks on any one track.

### 10.4 What the metrics do NOT cover

Stated so nobody claims more than is measured: these metrics cannot tell you
whether the visualiser is *beautiful*, whether the colour choices are good, or
whether a gesture feels musically apt. They bound jitter, deadness, latency,
hold, false triggering and universality. Aesthetic judgement still requires
watching `animation.mp4` and the hardware.

### 10.5 Open measurement gaps to close first

1. **Frame-interval distribution on real hardware** — p50/p95/max of the render
   tick and of the per-packet echo round trip. The counters exist and are now
   read: `VisualizerController` summarises the render telemetry and the frame
   slot's delivered/dropped counts at the end of every run and shows them on the
   menu item. The echo round trip itself is still unrecorded.
2. **Clap-test end-to-end latency** with a 240 fps camera, to set the §8.3
   default offset.
3. **The discriminating experiment, before any code changes**: ask whether
   `spectrum` and `vu` (the two modes that do not consume onsets) feel calmer
   than `pulse`/`wave`/`ripple`. If yes, the onset detector is confirmed
   dominant and §2.2 is the highest-value change. If all five feel equally
   broken, the aliasing (§6.1), transport (§7) and output-quantisation (§6.5)
   causes carry more weight than ranked here.

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
