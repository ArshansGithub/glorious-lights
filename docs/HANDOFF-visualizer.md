# Handoff — the audio visualizer

**Written 2026-08-06 for a fresh session (Codex) taking over the visualizer.**
Everything else in this project works and is not your problem. The visualizer is.

Read this whole file before writing code. Then **step back and ideate before
implementing** — that is an explicit instruction from the project owner, not a
suggestion.

---

## 1. What the product is

`Glorious Lights` — a macOS menu-bar app that drives RGB on hardware the vendor
abandoned: a **GMMK 1 TKL keyboard** (87 keys, individually addressable) and a
**wired Glorious Model O- mouse** (6 LEDs). Both protocols were reverse
engineered from scratch in this project and both work reliably. Published:
<https://github.com/ArshansGithub/glorious-lights>, MIT, installable via
Homebrew cask.

The visualizer is one feature of that app: **listen to what is playing and make
the keyboard visualize it.**

## 2. The goal, in the owner's own words

Collected verbatim across the effort. These are the requirement; the design docs
are not.

> "i want it to like show/react to my music in a cool way"

> "its more so understood as like make my keyboard light up when hear noise.
> theres no taste rn or configuration in how it listens to music"

> "all of the modes feel incredibly jittery... it doesn't feel like its in real
> time responding to all the little details in the song... the lights don't
> properly stay on, they are just so fast"

> "its like a cliff — the moment a certain sound plays and a certain color
> happens its like instantaneous triggered and then goes back to zero. theres no
> sort of short term accumulation"

> "the color is concentrated in the center and isn't diverse / well propagated"

> "i want colors to represent the specific details of a song, like i want it to
> be consistent... if a song has a repetition of a certain aspect of the song, if
> it happened 30 seconds ago and there were certain colors that represented that
> aspect, they should repeat again similarly visually the next time around"

> "you see how fast the colors change? its like theres no consistent / gradual
> baseline and then the more loud dynamic layers on top changing and propagating.
> like if you look at some sort of graph of the song, yeah if you look closely and
> zoom in a ton theres huge jagged ups and downs. but if you zoom out, you can
> smoothen and see how the song plays"

**And the most recent, which is the clearest statement of the target:**

> "theres like multiple intricate sounds in the song but the main effect is just
> the one major song... it doesn't have the complexity of having like spatialness
> where that sort of secondary beat triggers over there and the 3rd/4th + nth one
> over here. its literally just blinking to the main beat. its not to the actual
> song itself. the idea is that its literally visualizing the song."

> "i think its picking up on like micro changes to the song cause theres weird
> changes subtly here and there. and like for example when the song does like a
> quiet moment that is like high speed/bpm the lights dont capture that."

> "Are you sure we cant just use a library that can already ingest/understand
> music in realtime and just make the LED layer on top? we dont need to
> overengineer a music realtime analyzer."

> "stop overengineering pls"

### Distilling the target

1. **Simultaneous musical elements should occupy different places on the board.**
   The kick lives somewhere, the hi-hats somewhere else, the bassline somewhere
   else, the vocal/lead somewhere else. Right now everything collapses into one
   board-wide pulse on the dominant beat. **This is the headline requirement.**
2. **A slow, legible baseline** that follows the zoomed-out shape of the song,
   with fast dynamics layered on top — not everything reacting at once.
3. **Colour means something and is consistent** — the same musical content should
   look the same way when it comes back later in the track.
4. **Ignore micro-detail.** Subtle spectral wobble should not visibly change
   anything.
5. **Capture character, not just loudness** — a quiet but fast passage should
   read as quiet-and-fast, not as "nothing happening".
6. **One mode, done well.** Do not build five. Pulse was the closest of the five
   that exist; expand later from whatever actually works.
7. **Prefer an existing library** for music understanding. Do not hand-roll
   another analyzer.

## 3. Hard constraints (measured, do not re-derive)

| Constraint | Value | Source |
|---|---|---|
| Keyboard grid | 17 columns × 6 rows, 87 keys, 126 addressable LED indices | `GMMKKeyMap` |
| Max frame rate | ~15 fps sustained | echo-paced USB transport, measured |
| Frame cost | 9 packets for a full 126-LED repaint; dirty-region diffing exists | `§7.2`, `GMMKKeyboard` |
| Sound → LED latency | ~95–120 ms typical, ~220 ms worst | measured, audit in git history |
| Per-LED depth | 8-bit, gamma ≈ 2.2; decoded steps 0 → 0.081 → 0.110 | measured |
| Mouse | 6 LEDs, **every colour change costs a flash write cycle** | measured — accents only, never per-beat |

**The latency and frame rate are the hard part of the medium.** At 15 fps and
~100 ms lag, tight rhythmic precision is marginal. Several rounds were spent
fighting for millisecond beat-lock. Consider designing *for* the medium — slow
washes, sustained regions, big legible gestures — rather than against it.

## 4. Where the code is

```
Sources/GloriousVisualizer/     analysis + modes (the thing to replace/rework)
  SpectrumAnalyzer.swift        FFT (Accelerate), band levels
  MusicalAnalysis.swift         onset detection, tempo tracking
  Energy.swift                  multi-timescale energy (E / Φ / Σ)
  ColourField.swift             spatial hue field
  Modes.swift                   the five modes
  VisualizerPipeline.swift      wiring
Sources/GloriousAudioCapture/   mic + system-audio (CoreAudio process tap)
Sources/GMMKLightsApp/VisualizerController.swift   app-side, render thread, transport lease
Sources/viz-sim/                offline simulator — THE MOST USEFUL TOOL HERE
docs/visualizer-design.md       2300-line spec. See §7 before trusting it.
```

### viz-sim — use this constantly

Runs the **identical** pipeline offline and renders what the keyboard would show,
as PNG frames plus an `animation.mp4`.

```sh
swift build -c release
.build/release/viz-sim --file "/path/to/song.mp3" --mode pulse --duration 60 --out /tmp/out
.build/release/viz-sim --signal bass-pulses --duration 20 --mode pulse --out /tmp/out
.build/release/viz-sim --battery        # the full synthetic battery
```

**Mux the audio in so alignment is watchable** (the owner explicitly asked for
this and it is how they review):

```sh
ffmpeg -ss 38 -i /tmp/out/animation.mp4 -ss 38 -i "song.mp3" -t 24 \
       -c:v libx264 -c:a aac -shortest -y /tmp/look.mp4
```

Test music on this machine: `~/Downloads/Mareux - Blackmail (Official Lyric
Video).mp3` and `Mareux - Night Vision`. **Do not tune constants to these two
tracks** — the owner called that out explicitly. Use them as sanity checks only.

## 5. Current state

- HEAD is green: `swift build` and `swift test` clean, **468 tests pass**, zero warnings.
- `viz-sim --battery` **FAILS**: ~1257 of 13929 checks. Do not trust that number
  as a defect count — see §7.
- The app is installed and runs; the visualizer works in the sense that it
  reacts to audio, and does not satisfy the owner.

### Recent real fixes worth keeping

- **Energy-reference collapse (blackout).** On sparse material the reference
  quantile climbed to the signal's own level and the board went **completely
  black for ~20 s while music played**. Fixed in `d5365e1` + `7817383`. If you
  rewrite the energy model, do not reintroduce this: test with a periodic
  impulse train at several tempos and confirm the board stays alive.

### Two saved leads (not committed, deliberately)

| Patch | What it is |
|---|---|
| `scratchpad/centroid-smoothing-lead.patch` | Slows the hue boundary from per-frame to a ~3.5 s follower + slower gradient attack. Directly targets "colours change too fast / no gradual baseline". **Breaks `testRenderingIsDrivenByTheTimestampNotTheWallClock`** because the follower carries state across calls — needs to be made idempotent per timestamp. |
| `scratchpad/accent-layer-prototype.patch` | Redefines "lit" as `level − bed` so metrics measure gesture light rather than the resting bed. Vindicated M10c. Blocked on transport fragmentation (109 → 214 packets) and the same idempotency invariant. |

**Both patches are committed to `docs/leads/` in this repo** — they are durable, not session-scoped.

## 6. What was tried and what it cost

Three full rebuilds. Summary so you do not repeat them:

1. **Spectrum bars** (v1). Read as noise — 17 twitchy independent columns on a
   6-row grid. Verdict: "no taste".
2. **Musical modes + onset/tempo** (v2). Root cause found: the onset detector
   fired **~12 phantom onsets/second on a pure sine tone**, saturating its own
   refractory ceiling, because detectors were fed raw magnitudes with an
   absolute `1e-5` floor and no SNR test. Fixed. Verdict: still jittery.
3. **Multi-timescale + prediction + spatial colour** (v3, current). Real
   findings: the "cliff" was *caused by the design itself* — every control signal
   was normalised over 4–10 s windows, which makes it mathematically impossible
   to express "louder than ten seconds ago". Verdict: still not visualizing the
   song.

**Pattern to notice:** each round produced more machinery and better internal
metrics; none produced a result the owner liked. The loop from "change" to
"owner sees it" got longer each time. Invert that.

## 7. About `docs/visualizer-design.md` — read this before trusting it

It is 2300 lines and it is **the main artifact of the over-engineering the owner
objected to**. It contains genuinely useful measured facts, and it also contains
internal contradictions that were proven, not suspected:

- **§10.5 items 8–11 document four places where two clauses of the spec
  contradict each other.** They were never resolved.
- **M9a demands the board show ≥35 % sub-0.5 Hz power on material that itself
  contains 0.3–14 %.** Verified by running each case's own ground-truth RMS
  envelope through the metric's own estimator. The metric asks the display to
  invent slowness that is not in the audio. It is wrong, not the code.
- **M1/M4/M10c measure absolute LED level**, but the design later added a
  permanent bed on every key — so they measure the bed, not the gestures.
  Raising the bed makes them vacuous; lowering it makes everything strobe.
- **§10.5 item 8's stated mechanism is false** — the tradeoff it describes was an
  artifact of a bad reference seed and disappears once the seed is fixed.

**Recommendation: treat the doc as an archive of measurements and a cautionary
tale, not as a contract.** Roughly four checks would have done the job the
fourteen metric families do: doesn't strobe, doesn't go dark during music,
isn't monochrome, isn't all in one place.

## 8. The library question — the owner is probably right

The owner has asked twice to use an existing real-time music-understanding
library instead of hand-rolling one. Prior rounds only *borrowed design ideas*
from WLED Sound Reactive and LedFX. **Evaluate actually linking something.**

Starting points, with the honest tradeoffs:

| Option | Real-time? | Licence | Notes |
|---|---|---|---|
| **aubio** | Yes, streaming/causal, ~11 ms hops | **GPL-3** | Onset, tempo, pitch, MFCC. Two decades of use. Linking relicenses this repo (MIT today). A prior round declined it on licence + "our BPM is already stable (sd 0.04)" — but that argument addressed tempo *accuracy*, and the current complaint is *musical structure*, which is different. |
| **Essentia** | Yes (streaming mode) | AGPL-3 | Much richer MIR: onsets per band, beat tracking, key/chord detection, timbre descriptors. Heavier C++ dep. |
| **BTrack** | Yes | GPL-3 | Small, focused real-time beat tracker. |
| **Apple `SoundAnalysis` / CoreML** | Yes | Apple SDK, no relicensing | Classification-oriented. Could host a small CoreML model. |
| **Source separation** (Demucs / open-unmix, CoreML-converted) | Marginal on M-series, needs a lookahead buffer | varies | **This is the one that most directly serves the headline requirement** — real stems (drums / bass / vocals / other) would give genuinely independent musical elements to place in different board regions, instead of frequency bands pretending to be instruments. Latency and CPU are the open questions. Worth a spike before dismissing. |

**Licence note:** the repo is MIT. GPL/AGPL linking relicenses the shipped app.
The owner treats this project as open-source-for-fun, so that is likely
acceptable — **but confirm with them before committing to it**, since it changes
the published cask.

## 9. Suggested approach for the new session

The owner asked, explicitly: **step back, evaluate the goal, and ideate first.**

1. **Ideate before coding.** What does "visualizing the song" mean on a 17×6 grid
   at 15 fps? Sketch two or three genuinely different concepts. Consider that
   the answer may be closer to an ambient, slowly-evolving picture of the music
   than to a reactive light show.
2. **Decide the analysis stack deliberately** — library vs. what exists — with
   the spatial/multi-element requirement as the deciding criterion, and take the
   licence question to the owner.
3. **Solve the spatial-element problem first.** It is the headline complaint and
   nothing else matters if the board is still one blinking blob. Whether that is
   stems, per-band onset streams with fixed spatial homes, or something else is
   the key design decision.
4. **Iterate through video, not through metrics.** Render `viz-sim` clips with
   audio muxed in, show them to the owner, take the verdict, change one thing.
   Minutes per round. Their taste is the only oracle that has ever mattered here.
5. **One mode.** Pulse is the base to beat.
6. **Keep exactly the sanity checks you need**, and delete or ignore the rest of
   the battery. It is not load-bearing.

### Do not

- Do not write another 2000-line spec.
- Do not tune to the two Mareux tracks.
- Do not chase millisecond beat-lock before confirming the medium can express it.
- Do not touch the mouse at visualizer rates (flash wear — accents only).
- Do not commit anything that breaks the timestamp-idempotency invariant
  (`testRenderingIsDrivenByTheTimestampNotTheWallClock`); two changes have
  already been correctly held back for exactly that.
- Do not make a failing metric pass by weakening it. If the spec contradicts
  itself, say so and escalate — that has happened four times and was correct
  each time.

## 10. Quick reference

```sh
cd ~/Desktop/gmmk-lights
swift build -c release && swift test          # 468 tests, must stay green
bash Scripts/make-app.sh                      # builds "Glorious Lights.app"
open "build/Glorious Lights.app"              # run it (menu-bar icon)
.build/release/gmmk-cli list                  # keyboard present?
.build/release/gmmk-cli mouse info            # mouse present?
```

**Permissions:** the app needs Input Monitoring (HID) and audio capture. It is
signed with a real Apple Development certificate so grants survive rebuilds —
**do not switch back to ad-hoc signing**, that silently invalidates every grant
while still showing them enabled in System Settings.

**Hardware verification:** the owner has an iPhone camera pointed at the
keyboard; `ffmpeg -f avfoundation -i "1"` captures it. Camera index 0 is a Razer
webcam, 1 is the iPhone. This is how "does it actually look right" gets answered
when the simulator is not enough.
