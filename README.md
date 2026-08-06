# GMMK Lights

Control the RGB lighting of the original **GMMK 1** (Glorious Modular Mechanical
Keyboard, 2018–2021, SONiX `0x0C45:0x652F`) from macOS — the keyboard Glorious
Core doesn't support and the official GMMK Editor (Windows-only) left behind.

A native Swift menu-bar app plus a CLI. No drivers, no kernel extensions.

<img width="383" height="357" alt="image" src="https://github.com/user-attachments/assets/9dc20f23-8a51-429c-ad26-1b70d75b57ca" />

## Why this exists

Glorious CORE does not speak to the GMMK 1 at all (its device database starts at
the GMMK Pro), and the legacy GMMK Editor is Windows-only. On a Mac, this
keyboard was a brick, RGB-wise. This project reverse-engineered the missing
pieces and implements the full lighting protocol natively.

Along the way we discovered several things nobody had documented (see
[`docs/protocol-tkl-notes.md`](docs/protocol-tkl-notes.md)):

- macOS does **not** prepend the HID report ID on this device's output pipe —
  every packet must be sent as the full 64-byte wire frame. Sent short, the
  firmware's error replies get misparsed by macOS as **phantom keypresses**.
- Config writes must target **all three onboard profile blocks** (42-byte
  stride) to apply regardless of the active profile.
- Writes only *latch* into the running effect after a **`0x03` device-info
  "hello" read** — the session-opener the official editor sends on connect.
- The firmware echoes every command with a **status byte** (offset 7):
  `0x00` OK, `0xFF`/`0xFE` error. The transport paces on these echoes,
  exactly like the official editor does.

## Install

```sh
git clone <this repo>
cd gmmk-lights
swift build -c release
```

- **Menu-bar app:** `swift run -c release GMMKLightsApp` — effect picker,
  brightness/speed sliders, color picker, hot-plug aware.
- **Switch-friendly colors:** the easiest fix for a board that mixes clear and
  tinted (cyan Lynx) switch housings is to pick a color the tint barely touches.
  The *Switch-Friendly Colors* submenu has eight green/blue-dominant swatches
  that both housings render about the same, applied as ordinary solid colors.
  Pick a red-heavy color instead and the menu says so, without stopping you.
- **Switch compensation:** if the board mixes clear and tinted switch housings
  (Glorious Lynx housings are cyan, so they eat red and tint everything green),
  *Tune Switch Compensation…* has you press whichever kind you have fewer of —
  each lights white as you go — say which kind that was, then drag one slider
  until the board reads as the colour you actually picked. The tinted keys are
  the ones corrected, whether they're the set you marked or the rest. A second
  slider balances *brightness* between the two sets, because matching the hue
  doesn't match the glow — on green/blue colors the cyan housings diffuse more
  light and read brighter, on reds they read dimmer, so the slider goes both
  ways. Fn is marked with a button, since the keyboard handles that key itself
  and the Mac never sees it.
  Once a profile is tuned, every color change — the picker and the swatches
  above alike — goes out as a per-key paint carrying the correction. Hue
  correction alone can only do so much (a cyan housing filters red out
  subtractively, and on a warm color red is already maxed), so the palette is
  still the better answer for most colors.
- **CLI:** `swift run -c release gmmk-cli help`

```sh
gmmk-cli mode wave1          # any of the 20 onboard effects
gmmk-cli color ffaa00        # solid color (also disables hue-cycling)
gmmk-cli brightness 80       # 0–100
gmmk-cli speed 4             # 1–5
gmmk-cli direction l         # l / r
gmmk-cli paint ffaa00        # custom mode: paint every per-key LED
```

On first use macOS will ask for **Input Monitoring** permission
(System Settings → Privacy & Security → Input Monitoring) — that's the gate for
opening any HID interface of a keyboard-class device. Grant it and relaunch.

## Compatibility

Developed and hardware-verified against a **GMMK 1 TKL ANSI, firmware 1.08**.
Full-size and Compact GMMK 1 boards share the same USB identity and protocol
family and should work; per-effect color rendering varies between LED batches.
GMMK Pro / GMMK 2 / GMMK 3 are **not** supported — those speak different
protocols and have official macOS support via Glorious CORE.

## Safety

The GMMK 1's SN32 microcontroller exposes its flash bootloader via feature
reports on the boot-keyboard interface. This project **never** sends feature
reports there, never sends the keymap/macro command family, and never sends the
four undocumented no-argument commands — see
[`docs/protocol-tkl-notes.md`](docs/protocol-tkl-notes.md) §4 and §10 for what
those hazards are. If your lighting ever ends up in a weird state, unplug and
replug the keyboard; factory reset is `FN+ESC` then `F1+F3+F5`.

## Project layout

| Target | What it is |
|---|---|
| `GMMKProtocol` | Pure packet builders + checksum; golden-byte unit tests |
| `GMMKHID` | IOKit HID transport: vendor-interface matching, 64-byte frames, hello-read session opener, echo-paced sends |
| `gmmk-cli` | User commands plus the bring-up/debug toolkit (`probe0`–`probe3`, `read`, `raw`) |
| `GMMKLightsApp` | The menu-bar app |
| `docs/` | The protocol references — likely the most complete public documentation of this keyboard's protocol |

## Attribution

The wire protocol was reverse-engineered with the help of three earlier
open-source projects — [`paulguy/gmmkctl`](https://github.com/paulguy/gmmkctl)
(GPL-3.0), [`dokutan/rgb_keyboard`](https://github.com/dokutan/rgb_keyboard)
(GPL-3.0-or-later, whose effect names this project's UI uses), and
[`hangrydave/GKeyboardController`](https://github.com/hangrydave/GKeyboardController)
(GPL-3.0) — and by static analysis of the official (freely distributed) GMMK
Editor for interoperability. **No code from any of them was copied**; every
line here is original Swift, and the macOS-specific findings are new. Details in
[`docs/attribution.md`](docs/attribution.md).

## License

MIT — see [`LICENSE`](LICENSE).
