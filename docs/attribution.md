# Attribution and licensing notes

Draft. Not legal advice — the recommendation below is an engineering judgement
about what we did and did not copy.

## The three reference projects are all GPL-3.0

| Project | License | Notes |
|---|---|---|
| [`paulguy/gmmkctl`](https://github.com/paulguy/gmmkctl) | GPL-3.0 (`LICENSE`, GPL v3, 29 June 2007) | C; framing, checksum, START/END, `0x06`/`0x11`, full-size key map |
| [`dokutan/rgb_keyboard`](https://github.com/dokutan/rgb_keyboard) | GPL-3.0 (`LICENSE`); source headers say **"version 3 … or (at your option) any later version"**, i.e. GPL-3.0-or-later | C++; mode-ID table, config read `0x05`, profile blocks, LED addresses |
| [`hangrydave/GKeyboardController`](https://github.com/hangrydave/GKeyboardController) | GPL-3.0 (`LICENSE`, GPL v3) | Python; packets captured from the official Windows software |

## Can this repo be MIT?

**Yes, on the facts as they stand.** The GPL is a licence on *code*, and it
attaches to derivative works of that code. It does not reach the protocol the
code speaks. What we took from these projects is the wire protocol: command
bytes, a checksum rule, field offsets, address arithmetic, mode IDs. That is
factual interoperability information, unprotected by copyright in both US
(*Baker v. Selden*, 17 U.S.C. §102(b), and the *Oracle v. Google* line on
interface declarations) and EU law (Software Directive Art. 5(3) / 6, which
expressly permits observing and studying a program to determine the ideas
behind it and to achieve interoperability).

Concretely, for this repo:

* **No source was copied.** Every line in `Sources/` is original Swift. Nothing
  was translated line-by-line from the C, C++, or Python.
* **The load-bearing findings are our own.** The 64-byte transport requirement,
  the three-profile write strategy, the `0x03` device-info block, and the reply
  status byte were all determined here — by static analysis of the vendor's own
  Windows binary and by hardware testing. None of the three projects documents
  any of them; two of them get the profile question wrong for this board.
* **The GPL projects were used as references, in the sense the licence
  contemplates**: we read them to learn the protocol, then implemented it.

So: **MIT is compatible.** Attribution is not legally required for facts, but it
is owed as a matter of courtesy and honesty — these projects saved us
substantial work, and a reader deserves to know where the protocol reference
came from.

## Two things to watch

Flagging these rather than burying them; neither blocks MIT, both are cheap to
handle.

1. **The effect-mode display names are `rgb_keyboard`'s wording.**
   `LightingMode.displayName` in `Sources/GMMKProtocol/Types.swift` uses that
   project's descriptive set — "Hurricane", "Waterfall", "Vortex", "Sine" — as
   `docs/protocol.md` §3 already states. A short list of one-word labels for
   functional items sits well below the originality threshold, and the mapping
   from ID to effect is a fact about the firmware. It is still *someone's chosen
   wording* rather than something we observed. Safe options, in order of cost:
   credit it explicitly in the attribution block (recommended), or rename the
   handful of names that are not self-evident from the effect itself.

2. **`docs/protocol.md` reproduces data tables from the references** — the
   full-size key-index map from `gmmkctl`'s keymap files and the mode-ID table.
   These are factual compilations with thin protection, and reproducing them in
   a protocol reference is the ordinary practice of the field. Worth keeping the
   per-table provenance lines that are already there, which is what makes this
   defensible.

Neither creates a GPL obligation: an MIT project may cite, describe, and
re-derive facts from GPL software. What it may not do is copy the code.

## Draft ATTRIBUTION block

For `README.md` or a top-level `ATTRIBUTION.md`:

> ### Attribution
>
> The GMMK v1 lighting protocol implemented here was reverse-engineered from
> scratch for this project, but three earlier open-source projects were
> essential references for the wire format, and this project would have been far
> harder without them:
>
> * [`paulguy/gmmkctl`](https://github.com/paulguy/gmmkctl) (GPL-3.0) — packet
>   framing, checksum, `START`/`END` bracketing, the full-size key-index map.
> * [`dokutan/rgb_keyboard`](https://github.com/dokutan/rgb_keyboard)
>   (GPL-3.0-or-later) — the effect-mode ID table, the config-RAM read command,
>   the profile-block layout, and the per-effect names this project's UI uses.
> * [`hangrydave/GKeyboardController`](https://github.com/hangrydave/GKeyboardController)
>   (GPL-3.0) — packets captured from the official Windows software, which
>   independently confirmed the checksum and brightness range.
>
> **No code from these projects was copied.** They were used to learn the
> protocol — factual interoperability information — and every line here is
> original. This project is MIT-licensed; those projects remain under their own
> licences and nothing here is a derivative work of them.
>
> Protocol details that are *not* from those projects — the 64-byte macOS
> transport requirement, writing config fields at all three profile bases, the
> reply status byte, and the device-info block returned by command `0x03` on
> firmware 1.08 — were determined here and are documented in
> [`docs/protocol-tkl-notes.md`](docs/protocol-tkl-notes.md).
