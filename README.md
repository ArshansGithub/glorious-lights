# Glorious Lights

Control the RGB lighting of the original **GMMK 1** keyboard (Glorious Modular
Mechanical Keyboard, 2018–2021, SONiX `0x0C45:0x652F`) and the wired **Glorious
Model O / O-** mouse (SinoWealth `0x258A:0x0036`) from macOS — the devices
Glorious Core doesn't support and the official Windows-only editors left behind.

A native Swift menu-bar app plus a CLI. No drivers, no kernel extensions.

The two devices share nothing but this repository: different vendors, different
transports, different protocols. The keyboard speaks 64-byte output reports with
a checksum, START/END bracketing and echo pacing; the mouse speaks feature
reports carrying one 520-byte configuration blob and no checksum at all. Each has
its own targets and its own protocol reference, and the app shows whichever
devices are plugged in.

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

**Homebrew:**

```sh
brew tap ArshansGithub/tap
brew trust arshansgithub/tap        # Homebrew 6+ gates third-party taps
brew install --cask glorious-lights
```

The `brew trust` step is not optional on Homebrew 6 — without it `brew install`
refuses to load the cask at all.

**Or download** `Glorious-Lights-1.0.0.zip` from the
[latest release](https://github.com/ArshansGithub/glorious-lights/releases/latest),
unzip it, and drag *Glorious Lights.app* to `/Applications`.

### First launch

Two prompts, both one-time, both unavoidable:

1. **Gatekeeper.** The app is signed ad-hoc rather than with a paid Apple
   Developer ID, so macOS will refuse a plain double-click and say it "cannot be
   opened because the developer cannot be verified". **Right-click (or
   Control-click) the app → Open → Open.** After that it launches normally
   forever. Homebrew installs are quarantined the same way, so the same dance
   applies. If you would rather not, build from source below — a locally built
   binary is not quarantined.
2. **Input Monitoring.** macOS gates opening *any* HID interface of a
   keyboard-class device behind Input Monitoring, so the app asks for it on
   first run (System Settings → Privacy & Security → Input Monitoring). Grant it
   and relaunch. Without it the menu says the keyboard was found but is not
   usable.

The app has no Dock icon: it lives in the menu bar.

### Build from source

```sh
git clone https://github.com/ArshansGithub/glorious-lights.git
cd glorious-lights
swift build -c release
Scripts/make-app.sh          # assembles build/Glorious Lights.app
```

`Scripts/make-app.sh` builds the release binary, renders the icon
(`Scripts/make-icon.swift`, drawn from primitives — no SF Symbols, whose licence
does not permit use in app icons), writes `Info.plist` with the version from the
`VERSION` file, and ad-hoc signs the result. Pass `--zip` to also produce the
release archive and print its SHA-256.

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
- **Mouse:** when a Model O / O- is attached, the menu grows a mouse section —
  firmware version, RGB effect, color, brightness, speed, DPI stages, polling
  rate and debounce. It reads the mouse's settings on connect and never writes
  anything until you pick something.
- **Per-LED mouse colors:** *Per-LED Colors…* drives the mouse's six LEDs
  individually — a mode present in the firmware that Glorious's own software
  doesn't expose and neither OpenRGB nor libratbag implements. Both side strips
  carry all six in index order front to back and are mirrored, so a color lights
  the same position on each side, and the scroll wheel follows LED 1. There's a
  "copy LED 1 to all" button for getting back to one flat color.
- **One desk, one look:** *Desk Themes* applies a curated look to every device
  that's plugged in, translating it into each one's own vocabulary. Two groups:
  *Easy on the switches* (Mint Uniform, Seafoam Wave, Ocean, Ember, Ice,
  Midnight) stays in the greens and blues a mixed-switch board renders evenly,
  and *Loud* (Magenta Blast, Ultraviolet, Acid, Electric, Toxic, Synthwave,
  Crimson, Sunset) doesn't hold back. Crimson and Sunset are red-heavy on
  purpose — they'll show a mixed-switch board's mix, and they route through your
  compensation profile exactly like a manual color pick rather than being
  softened. *Sync Devices* keeps them
  together after that: a color, effect or brightness change made to either
  device is applied to the other as well. The two disagree about almost every
  scale (the keyboard's speed field is a *delay* running backwards, and its
  brightness has an "off" level the mouse can't express), so the translation
  lives in one tested place — see `Sources/GloriousSync`.
- **CLI:** `swift run -c release gmmk-cli help`

```sh
gmmk-cli mode wave1          # any of the 20 onboard effects
gmmk-cli color ffaa00        # solid color (also disables hue-cycling)
gmmk-cli brightness 80       # 0–100
gmmk-cli speed 4             # 1–5
gmmk-cli direction l         # l / r
gmmk-cli paint ffaa00        # custom mode: paint every per-key LED
```

## The mouse

`gmmk-cli mouse help` lists everything. The common ones:

```sh
gmmk-cli mouse info                 # decoded configuration + firmware + DPI stages
gmmk-cli mouse dump before.bin      # BACK UP FIRST — see below
gmmk-cli mouse color 00e5ff         # solid color
gmmk-cli mouse effect wave --speed 2 --brightness 3
gmmk-cli mouse dpi 2 1600           # stage 2 → 1600 dpi
gmmk-cli mouse dpi-enable 6 off     # switch a stage off
gmmk-cli mouse dpi-active 3         # 1-based over ENABLED stages only
gmmk-cli mouse polling 1000
gmmk-cli mouse debounce 8
```

### Back up before you write

Every mouse setting except debounce lives in a single 520-byte configuration
blob, and there is no way to poke one field: a write is always the whole blob
read back, modified and sent again. That also means one bad write replaces
everything at once. So:

```sh
gmmk-cli mouse dump before-anything.bin        # refuses to overwrite an existing file
# …change things…
gmmk-cli mouse restore before-anything.bin --config-size 131 --yes
```

`restore` needs `--config-size` because byte `0x03` of the write is
`<config size> - 8`, and that byte is what decides whether the mouse accepts the
write at all. `mouse info` prints the size the device reported — use that.
Debounce is **not** in the blob (it is command `0x1a`), so a dump does not back
it up; note the value from `mouse info` if you have changed it.

The blob write is itself the commit. There is no save command, and the settings
survive a replug.

## Compatibility

Developed and hardware-verified against a **GMMK 1 TKL ANSI, firmware 1.08** and
a **wired Glorious Model O-**. Full-size and Compact GMMK 1 boards share the
same USB identity and protocol family and should work; per-effect color
rendering varies between LED batches. The Model O and Model O- are the same
device to software — one USB ID, one detector in every published tool, no
size-conditional logic anywhere. GMMK Pro / GMMK 2 / GMMK 3 and the **wireless**
Model O/O- are **not** supported — different protocols, different USB IDs.

## Safety

Both devices have a firmware-flashing door, and both are avoided by
construction rather than by care.

**Keyboard.** The GMMK 1's SN32 microcontroller exposes its flash bootloader via
feature reports on the boot-keyboard interface. This project **never** sends
feature reports there, never sends the keymap/macro command family, and never
sends the four undocumented no-argument commands — see
[`docs/protocol-tkl-notes.md`](docs/protocol-tkl-notes.md) §4 and §10. If your
lighting ever ends up in a weird state, unplug and replug the keyboard; factory
reset is `FN+ESC` then `F1+F3+F5`.

**Mouse.** This one is sharper: the SinoWealth ISP bootloader shares feature
report 5 with the configuration protocol, so `05 75 …` — one byte away from the
firmware-version read — drops the mouse into DFU. Every command goes through an
**allow-list** of the six documented safe verbs, report 6 is refused outright,
and the command space is never swept. See
[`docs/mouse-protocol.md`](docs/mouse-protocol.md) §9. A mouse that does end up
in the bootloader re-enumerates as `0603:1020` and is recovered by replugging;
it only becomes a brick if something then writes flash.

## Project layout

| Target | What it is |
|---|---|
| `GMMKProtocol` | Keyboard: pure packet builders + checksum, the ANSI TKL key map, switch-compensation math; golden-byte unit tests |
| `GMMKHID` | Keyboard: IOKit HID transport — vendor-interface matching, 64-byte frames, hello-read session opener, echo-paced sends |
| `GloriousMouseProtocol` | Mouse: the 520-byte config blob with typed accessors, the safe-verb command channel, and the ISP guard |
| `GloriousMouseHID` | Mouse: IOKit feature-report transport, vendor-collection matching, hot-plug |
| `GloriousSync` | The only place the two meet: a pure translation layer mapping a device-neutral desk look onto each device's own effects and scales |
| `gmmk-cli` | Both devices, plus the keyboard bring-up/debug toolkit (`probe0`–`probe3`, `read`, `raw`) |
| `GMMKLightsApp` | The menu-bar app for both |
| `docs/` | The protocol references — likely the most complete public documentation of either device's protocol |

The mouse targets deliberately share no code with the keyboard's. Nothing in the
keyboard's protocol transfers: no checksum, no bracketing, no interrupt channel,
and a completely different notion of profiles.

## Attribution

The keyboard's wire protocol was reverse-engineered with the help of three
earlier open-source projects — [`paulguy/gmmkctl`](https://github.com/paulguy/gmmkctl)
(GPL-3.0), [`dokutan/rgb_keyboard`](https://github.com/dokutan/rgb_keyboard)
(GPL-3.0-or-later, whose effect names this project's UI uses), and
[`hangrydave/GKeyboardController`](https://github.com/hangrydave/GKeyboardController)
(GPL-3.0) — and by static analysis of the official (freely distributed) GMMK
Editor for interoperability.

The mouse's protocol was documented from
[`libratbag`](https://github.com/libratbag/libratbag)'s `driver-sinowealth.c`
(MIT), [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB)'s Sinowealth
controller (GPL-2.0), and [`carlossless/sinowisp`](https://github.com/carlossless/sinowisp)
for the ISP hazards specifically.

**No code from any of them was copied**; every line here is original Swift, and
the macOS-specific findings are new. Details in
[`docs/attribution.md`](docs/attribution.md).

## License

MIT — see [`LICENSE`](LICENSE).
