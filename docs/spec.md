# Glorious Lights — Design Spec (2026-08-05)

> Historical: this is the original design spec, written when the project was
> keyboard-only and called GMMK Lights. Mouse support came later — see
> [`mouse-protocol.md`](mouse-protocol.md).

## Goal
Native macOS menu-bar app to control RGB lighting on the original GMMK 1 TKL
(Glorious Modular Mechanical Keyboard, SONiX controller). Official Glorious Core
does not support this board; lighting protocol is community-reverse-engineered.
Scope: lighting only (effect mode, brightness, speed, direction, color, per-key
colors if straightforward). No key remapping, no macros, no firmware writes.

## Verified hardware facts (measured on this machine — do not re-derive)
- USB IDs: VID `0x0C45` (SONiX), PID `0x652F`. Product string "USB DEVICE".
- Two HID interfaces:
  - **Interface A (boot keyboard)**: usage page 1, usage 6. MaxOutputReportSize 1,
    MaxFeatureReportSize 64 (a 64-byte feature report with no report ID lives here,
    consumer-page tail in descriptor).
  - **Interface B (NKRO + vendor)**: usage pairs (1,6), (1,12), (12,1), and
    **vendor (0xFF1C, 0x92)**. Report IDs: 1 = NKRO keyboard, 2/3 = consumer,
    **4 = vendor: 63-byte Output report + 63-byte Input report**.
    MaxOutputReportSize 64.
- The vendor channel for lighting commands is **report ID 4 on Interface B**
  (64 bytes total counting the leading `0x04` ID byte). This matches the Linux
  `gmmkctl` project, whose interrupt-OUT packets all begin `0x04`.
- macOS API caveat: `IOHIDDeviceSetReport` takes the report ID as a parameter and
  the payload WITHOUT the leading ID byte (hidapi convention: `data[0]` is the ID,
  and `data+1, len-1` goes to SetReport). Get this right or nothing works.
- Open the device non-seizing (`kIOHIDOptionsTypeNone`); match specifically the
  interface whose usage pairs include (0xFF1C, 0x92) so we never touch the boot
  keyboard interface. macOS may require Input Monitoring permission (TCC) for
  the process (Terminal during dev).

## Protocol reference
Primary: `gmmkctl` by paulguy (https://github.com/paulguy/gmmkctl), Linux,
reverse-engineered GMMK v1 protocol: command set for lighting mode, brightness,
speed, direction, rate, solid color, per-key colors; includes packet checksum
scheme and mode IDs (~20 onboard effects). Secondary cross-checks: OpenRGB
issues/forks for GMMK v1, SonixQMK community docs. Research output goes to
`docs/protocol.md` with byte-exact packet layouts.

## Architecture (Swift Package, no Xcode project)
```
Sources/
  GMMKProtocol/   pure packet builders (mode/brightness/speed/color/per-key),
                  checksum, mode ID enum. No IOKit. Unit-tested.
  GMMKHID/        IOKit HIDManager transport: find interface B by VID/PID +
                  usage pair (0xFF1C, 0x92), open, SetReport(output, id=4).
                  Hot-plug notifications (device added/removed).
  gmmk-cli/       executable: `gmmk-cli mode wave`, `brightness 80`,
                  `color ff8800`, `speed 3`, etc. Bring-up + debugging harness.
  GMMKLightsApp/  executable menu-bar app: AppKit NSApplication with activation
                  policy .accessory + NSStatusItem menu (SwiftUI views hosted
                  inside where convenient). Effect picker, brightness slider,
                  speed slider, color well. Calls GMMKProtocol + GMMKHID.
Tests/
  GMMKProtocolTests/  golden-byte tests for every packet builder.
```
Settings persist on the keyboard itself; the app stores nothing except last-used
UI state (UserDefaults).

## Verification
1. `swift build` + `swift test` pass.
2. CLI smoke test on real hardware: set a distinctive state (e.g. solid orange,
   full brightness) — the user visually confirms the keyboard changed.
3. Menu-bar app drives the same changes interactively.
Failure containment: lighting commands only; wrong packets are ignored by the
firmware or at worst need an unplug/replug. Never send commands from the
firmware-update/bootloader family.

## Risks
- Board revision differences (ANSI TKL vs full-size key indexing) — per-key
  layout table may need adjustment; ship effect/brightness/color first.
- gmmkctl documents full-size (104-key) indexing; TKL indices may differ or
  simply be a subset.
