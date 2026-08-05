# GMMK v1 (SONiX 0x0C45:0x652F) — Lighting Protocol Reference

Byte-exact reverse-engineered reference for the original GMMK 1 (full-size / TKL /
Compact), SONiX SN32F24x controller, USB `0C45:652F`.

**Sources used (all read directly, not from memory):**

| Source | What it gave us |
|---|---|
| [`paulguy/gmmkctl`](https://github.com/paulguy/gmmkctl) — `gmmk.c`, `gmmk.h`, `gmmk_led.txt`, `keymap-US-ANSI-fullsize.txt`, `test.txt` | **Primary.** Framing, runtime checksum algorithm, START/END bracketing, subcommand addresses, per-key `0x11` command, full-size key-index map |
| [`dokutan/rgb_keyboard`](https://github.com/dokutan/rgb_keyboard) — `include/data.cpp`, `writers.cpp`, `readers.cpp`, `rgb_keyboard.h` | **Mode ID → name table** (`0x01`–`0x14`), config-RAM read command `0x05`, config byte layout, profile blocks, LED addresses per key (independently identical to gmmkctl's indices) |
| [`hangrydave/GKeyboardController`](https://github.com/hangrydave/GKeyboardController) — `constants.py` | Golden packets captured from the **official Windows software**; confirms checksum, brightness levels 0–4, command `0x10` (read custom colors), full 104-key LED address list |

OpenRGB has **no** upstream GMMK v1 (0x652F) controller — `Controllers/` was
enumerated via the GitLab API and contains nothing matching GMMK/Glorious/SONiX.
Glorious Core's own source (`GmmkSeries`, `Gmmk3Series`) contains no `652f`, i.e.
Core genuinely does not speak to this board. Do not expect either as a cross-check.

---

## 1. Packet framing

Every lighting command is a **64-byte** USB HID report.

```
offset  size  field
------  ----  --------------------------------------------------------------
  0      1    Report ID — always 0x04
  1      2    Checksum, uint16 LITTLE-ENDIAN
  3      1    Command
  4      1    Length / count (bytes of payload at offset 8)
  5      2    Address, uint16 LITTLE-ENDIAN
  7      1    Always 0x00 (unknown / address high pad)
  8     56    Payload, zero-padded to the end of the packet
```

Total = 64 bytes. Interface 1 of the device; on Linux the endpoints are
interrupt OUT `0x03` and interrupt IN `0x82`.

### Checksum

From `gmmkctl/gmmk.c` (`sum()` + `TRANSFER_OR_FAIL`):

```c
buffer[0] = 4;
sum((unsigned short *)&buffer[1], &buffer[3], 64 - 3);   /* 61 bytes */
```

* **Algorithm:** plain 16-bit sum of *unsigned bytes*, no carry folding, no
  complement, natural wraparound mod 2^16.
* **Covers:** bytes **3 through 63 inclusive** (61 bytes) — i.e. everything
  *after* the checksum field, including the trailing zero padding.
* **Excludes:** byte 0 (report ID) and bytes 1–2 (the checksum itself).
* **Stored:** at bytes 1–2, **little-endian** (`lo` at 1, `hi` at 2).

Reference implementation:

```
sum = 0
for i in 3..63: sum = (sum + packet[i]) & 0xFFFF
packet[1] = sum & 0xFF
packet[2] = (sum >> 8) & 0xFF
```

Verified against the official-software captures in `GKeyboardController`:
`04 0d 00 06 01 00 00 00 06` → 0x06+0x01+0x06 = 0x0D ✔;
`04 0c 00 06 01 01 00 00 04` → 0x06+0x01+0x01+0x04 = 0x0C ✔;
and against `gmmk_led.txt`'s wire capture `04 0c 00 06 01 04 00 00 01` ✔.

### Command byte (offset 3)

| Value | Meaning |
|---|---|
| `0x01` | START — begin transaction |
| `0x02` | END — end/commit transaction |
| `0x03` | Read profile block (`count` at 4, address at 5–6) |
| `0x05` | Read config RAM (`count` at 4, address at 5–6) |
| `0x06` | **Write config RAM** (all the lighting parameters) |
| `0x10` | Read custom (per-key) colour RAM |
| `0x11` | **Write custom (per-key) colour RAM** |
| `0x08`, `0x0A` | Key remapping / macros — **out of scope, do not send** |

The three projects independently show that `0x06` and `0x11` are *the same
primitive*: "write `count` bytes at 16-bit `address`", into two different
address spaces (config RAM vs LED colour RAM). `gmmkctl` calls `0x06`
"subcommand", but bytes 4–7 are really `count, addr_lo, addr_hi, 0`.

### Transaction bracketing (required)

Every logical operation is:

```
  04 01 00 01 00 ... 00      START
  <one or more command packets>
  04 02 00 02 00 ... 00      END
```

Byte-exact, these two never vary (`_data_start` / `_data_end` in
`rgb_keyboard/include/data.cpp`, and `DO_START`/`DO_END` in `gmmk.c`):

```
START: 04 01 00 01 00 00 00 00 00 00 00 00 ... (52 more 00) 
END:   04 02 00 02 00 00 00 00 00 00 00 00 ... (52 more 00)
```

`gmmkctl` brackets **each** setting individually (START, one write, END).
`rgb_keyboard` brackets a group of writes. Both work; per-key colour writes
must be inside a single START/END pair spanning all the data packets.

### Response packets

After every OUT packet the firmware makes a 64-byte reply available on the IN
endpoint. `gmmkctl` and `rgb_keyboard` both read (and discard) it after each
write. It is *not* required for writes to take effect, but reading it keeps the
device's queue drained. On macOS this is an Input report with report ID 4.

---

## 2. Config-RAM map (command `0x06`)

Config RAM holds the current lighting parameters. Address = offset within the
profile block.

| Addr | Len | Field | Values |
|---|---|---|---|
| `0x00` | 1 | Effect mode | `0x01`–`0x14`, see §3 |
| `0x01` | 1 | Brightness | `0x00`–`0x04` (0 = off, 4 = max) |
| `0x02` | 1 | Delay / speed | `0x00`–`0x03` meaningful (0 = fastest) |
| `0x03` | 1 | Direction | `0xFF` = left, `0x00` = right |
| `0x04` | 1 | "Colorful" / rainbow | `0x00` = single colour, `0x01` = rainbow |
| `0x05` | 3 | Animation RGB | R, G, B (`0x00`–`0xFF` each) |
| `0x08` | 1 | Reactive-colour variant | 0 = red, 1 = yellow, 2 = green, 3 = blue |
| `0x09` | 3 | Second RGB (purpose unconfirmed) | R, G, B |
| `0x0F` | 1 | USB polling rate | 0 = 125 Hz, 1 = 250, 2 = 500, 3 = 1000 |

Profile blocks are `0x2A` (42) bytes apart: profile 1 at `0x00`, profile 2 at
`0x2A`, profile 3 at `0x54` (`rgb_keyboard/include/writers.cpp`).
**`gmmkctl` only ever touches profile 1.**

> ⚠️ Writing profile 1 only is **not** sufficient on the GMMK 1 TKL. The board
> displays whichever profile it is running, and fw 1.08 will not tell you which
> that is. Write every field at all three bases — see
> [`protocol-tkl-notes.md`](protocol-tkl-notes.md) §13.

The same map is confirmed from the other direction by `readers.cpp`, which
issues `04 3d 00 05 38 00 00 00` (read 0x38 bytes at addr 0x0000) and then
decodes the reply as `buf[8]`=mode, `buf[9]`=brightness, `buf[10]`=speed,
`buf[11]`=direction, `buf[12]`=rainbow, `buf[13..15]`=RGB, `buf[16]`=variant —
i.e. reply payload also starts at offset 8.

### 2.1 Byte-exact command layouts

All shown as the full 64-byte wire packet; `··` = `00` padding to 64 bytes.

**Set effect mode** (`mode` = `0x01`–`0x14`)
```
04 CK CK 06 01 00 00 00 MM ··
```
e.g. mode 6 (fixed/"normally on"): `04 0d 00 06 01 00 00 00 06 ··`
mode 0x14 (custom/per-key):        `04 1b 00 06 01 00 00 00 14 ··`

**Set brightness** (`0x00`–`0x04`)
```
04 CK CK 06 01 01 00 00 BB ··
```
levels 0–4: `04 08 00 …00`, `04 09 00 …01`, `04 0a 00 …02`, `04 0b 00 …03`, `04 0c 00 …04`

**Set speed / delay** (`0x00`–`0x03`; larger values accepted, see §6)
```
04 CK CK 06 01 02 00 00 DD ··
```
e.g. delay 3: `04 0c 00 06 01 02 00 00 03 ··`

**Set direction**
```
left : 04 09 01 06 01 03 00 00 ff ··
right: 04 0a 00 06 01 03 00 00 00 ··
```

**Set "colorful" (rainbow) flag**
```
on : 04 0c 00 06 01 04 00 00 01 ··
off: 04 0b 00 06 01 04 00 00 00 ··
```
Rainbow ON makes the effect cycle hues and ignores the solid colour.
Rainbow OFF makes the effect use the solid colour at `0x05`.

**Set solid / animation colour (RGB)**
```
04 CK CK 06 03 05 00 00 RR GG BB ··
```
e.g. `ff8800`: sum = 0x06+0x03+0x05+0xFF+0x88+0x00 = 0x0195 →
`04 95 01 06 03 05 00 00 ff 88 00 ··`

**Set second colour** (seen in captures, meaning unconfirmed)
```
04 CK CK 06 03 09 00 00 RR GG BB ··
```

**Set polling rate** (0=125, 1=250, 2=500, 3=1000 Hz)
```
04 CK CK 06 01 0f 00 00 NN ··
```
e.g. 1000 Hz: `04 19 00 06 01 0f 00 00 03 ··`

**Set reactive-colour variant** (only meaningful in mode `0x11`)
```
04 CK CK 06 01 08 00 00 VV ··      VV: 0=red 1=yellow 2=green 3=blue
```

### 2.2 Full example transaction — solid orange at full brightness

```
04 01 00 01 00 …                       START
04 1b 00 06 01 00 00 00 14 …           (optional) mode
04 0c 00 06 01 01 00 00 04 …           brightness 4
04 0b 00 06 01 04 00 00 00 …           colorful off
04 95 01 06 03 05 00 00 ff 88 00 …     colour ff8800
04 02 00 02 00 …                       END
```
(`gmmkctl` would send four separate START/…/END triples instead; both are
observed to work.)

---

## 3. Effect mode IDs

Written to config address `0x00`. `0x01`–`0x14` = 20 onboard effects.
Two independent name sets are given because the projects disagree on wording:
`rgb_keyboard` uses descriptive names, `GKeyboardController` transcribes the
labels from the official Windows utility.

| ID | dec | `rgb_keyboard` name | Official-software label | Notes |
|---|---|---|---|---|
| `0x01` | 1 | horizontal wave | `wave1` | direction-aware |
| `0x02` | 2 | pulse | `wave2` | direction-aware |
| `0x03` | 3 | hurricane | `spiralingwave` | |
| `0x04` | 4 | breathing (colour cycle) | `acid` | |
| `0x05` | 5 | breathing | `breathing` | uses solid colour |
| `0x06` | 6 | fixed / static | `normallyon` | **the "solid colour" mode** |
| `0x07` | 7 | reactive single | — | lights the pressed key |
| `0x08` | 8 | reactive ripple | `ripplegraff` | |
| `0x09` | 9 | reactive horizontal | — | |
| `0x0A` | 10 | waterfall | — | |
| `0x0B` | 11 | swirl | — | |
| `0x0C` | 12 | vertical wave | — | |
| `0x0D` | 13 | sine | — | |
| `0x0E` | 14 | vortex | — | |
| `0x0F` | 15 | rain | — | |
| `0x10` | 16 | diagonal wave | — | |
| `0x11` | 17 | reactive colour | — | uses variant byte at cfg `0x08` |
| `0x12` | 18 | ripple | — | |
| `0x13` | 19 | **off** | — | all LEDs off |
| `0x14` | 20 | **custom** | `custom` | per-key colours from LED RAM |

`0x00` is not used by any project; treat as invalid.
`gmmkctl`'s README independently states "20 is the mode for freely programming
the keys, and the highest meaningful value", which matches `0x14` = custom.

---

## 4. Per-key colours (command `0x11`)

### Address scheme

LED colour RAM is a **flat array of RGB triplets**, R first. The wire address
is a **byte** address:

```
address = key_index * 3
```

stored little-endian at packet bytes 5–6, with byte 7 = `0x00`.

* Key indices are **1-based**; index 0 is unused on the full-size board.
* Highest index `gmmkctl` will address is `GMMK_MAX_KEY = 126` ("highest key
  value addressed by Windows utility"). Highest index actually populated by its
  own `test.txt` / `clear.txt` is **117** (they start with the line `1 117`).
* Independently confirmed: `rgb_keyboard`'s ANSI LED table has
  `Esc → 0x0003`, `F1 → 0x0006`, `PrtSc → 0x013E` (318 = 3×106), and
  `Backspace → 0x0126` (294 = 3×98) — exactly matching
  `gmmkctl/keymap-US-ANSI-fullsize.txt` indices 1, 2, 106, 98.
* `GKeyboardController` lists 104 full-size LED addresses split into
  "section 0" (77 entries, addresses 3–252) and "section 1" (27 entries,
  addresses 2–95 with address-high byte `0x01`, i.e. true addresses 258–351).
  Adding 0x100 makes every section-1 address divisible by 3 — same flat space.

### Full-size US-ANSI key index map

From `gmmkctl/keymap-US-ANSI-fullsize.txt` (index under each key):

```
ESC   F1  F2  F3  F4    F5  F6  F7  F8    F9  F10 F11 F12  PrtSc ScrLk Pause
1     2   3   4   5     6   7   8   9     10  11  12  13   106   107   108

`   1   2   3   4   5   6   7   8   9   0   -   =   BKSP   Ins Home PgUp  NumLk /   *   -
18  19  20  21  22  23  24  25  26  27  28  29  30  98     110 111  112   31    32  33  116

TAB  Q   W   E   R   T   Y   U   I   O   P   [   ]   \     Del End  PgDn  7   8   9
35   36  37  38  39  40  41  42  43  44  45  46  47  64    113 114  115   48  49  50

CAPS  A   S   D   F   G   H   J   K   L   ;   '    ENTER               4   5   6   +
52    53  54  55  56  57  58  59  60  61  62  63   81                  65  66  67  117

LSHIFT   Z   X   C   V   B   N   M   ,   .   /    RSHIFT      UP       1   2   3
69       70  71  72  73  74  75  76  77  78  79   80          96       82  83  84

LCTRL LGUI LALT        SPACE         RALT RGUI MENU RCTRL  ←   ↓   →    0       .   Enter
86    87   88          89            90   91   92   93     94  95  97   99      100 101
```

An ISO/DE variant ships as `gmmkctl/keymap-DE-ISO-fullsize.txt`.
Gaps (14–17, 34, 51, 68, 102–105, 109) are unpopulated addresses.

### Packet layout

```
offset  value
  0     04
  1-2   checksum
  3     11
  4     count = number of *bytes* (3 × keys in this packet), max 54 (0x36)
  5-6   byte address = first_key_index * 3, little-endian
  7     00
  8+    R,G,B, R,G,B, … (count bytes)
```

`(64 - 8) / 3 * 3 = 54` → **max 18 keys per packet**.
`gmmkctl` sends `count` = `min(54, remaining*3)` and advances the address by 54
each packet.

### Multi-packet bracketing

```
04 01 00 01 …                       START          (once)
04 CK CK 11 36 03 00 00 <54 bytes>  keys 1..18
04 CK CK 11 36 39 00 00 <54 bytes>  keys 19..36   (addr 0x39 = 57 = 19*3)
04 CK CK 11 36 6f 00 00 <54 bytes>  keys 37..54
…
04 CK CK 11 1b …                    final short packet (count 0x1B = 9 keys)
04 02 00 02 …                       END            (once)
```

For the canonical `1 117` (117 keys starting at index 1): 7 data packets, the
last with `count = (117 - 108) * 3 = 27 = 0x1B`.

`rgb_keyboard` instead sends **one key per packet** (`count = 3`, address =
that key's byte address, RGB in bytes 8–10) inside a single START/END pair.
Both forms are accepted by the firmware.

### Making custom colours visible

Set mode `0x14` (custom) — otherwise the onboard animation overwrites the LED
RAM. Ordering used by working tools: set mode `0x14`, then write the colours.

---

## 5. Init / handshake / commit

**There is no init or handshake.** No project sends any magic opening sequence,
feature report, or unlock command. Open the device and start sending.

**The "commit" is the `0x02` END packet.** Settings are written into the
keyboard's own storage and survive unplug — the app should hold no persistent
device state.

Do **not** send commands `0x08` / `0x0A` (key remap / macro tables) or anything
in the SONiX bootloader/ISP family. Lighting only.

---

## 6. macOS transport notes

The Linux tools use raw libusb interrupt transfers on interface 1, endpoint
`0x03`. On macOS you cannot claim a HID interface, so use IOHIDManager:

* Match VID `0x0C45`, PID `0x652F`, and select **the interface whose usage
  pairs include `(0xFF1C, 0x92)`** — that is interface B (NKRO + vendor).
  Never talk to the boot-keyboard interface.
* Open with `kIOHIDOptionsTypeNone` (non-seizing).
* Send the **full 64-byte wire packet, leading `0x04` included**:

```c
IOHIDDeviceSetReport(device,
                     kIOHIDReportTypeOutput,   // report type Output
                     4,                        // reportID = 4
                     packet,                   // INCLUDING the leading 0x04
                     64);                      // 64 bytes
```

* ⚠️ **Do not strip the leading `0x04`** — verified on hardware, fw 1.08.
  The usual IOKit rule is that the report ID is passed as a separate argument
  and omitted from the buffer, and an earlier revision of this document said to
  pass `packet + 1` with length 63. That is **wrong for this pipe**: macOS does
  not prepend the ID on the vendor interrupt OUT endpoint, so a 63-byte buffer
  arrives at the firmware one byte short and every field is shifted.
  Pass all 64 bytes with `0x04` first and the ID argument *also* set to 4.
* The failure mode is distinctive and worth recognising: a short packet makes
  the firmware answer with an error echo (status `0xFF`) that carries no report
  ID prefix, which macOS then parses against the keyboard's *input* descriptor —
  the symptom is a burst of **phantom keypresses**, not a silent no-op.
* Offsets in the buffer are therefore just the wire offsets, unshifted:

  | wire / buffer offset | field |
  |---|---|
  | 0 | report ID `0x04` |
  | 1–2 | checksum LE |
  | 3 | command |
  | 4 | count |
  | 5–6 | address LE |
  | 7 | pad `0x00` |
  | 8+ | payload |

* **Compute the checksum over bytes 3–63** of that same 64-byte buffer.
  Getting this wrong is the most likely silent failure.
* Replies arrive as Input reports with report ID 4. Register an
  `IOHIDDeviceRegisterInputReportCallback` if you want them; they are **not**
  required for writes to apply — verified on hardware, config writes take effect
  immediately whether or not anything drains the input queue. The status byte is
  at wire offset 7: `0x00` = OK, `0xFF` / `0xFE` = error.

> An implementation may still keep its *builders* at 63 bytes and have the
> transport re-attach the `0x04` — that is what this repo does — but what
> reaches `IOHIDDeviceSetReport` must be 64 bytes.
* macOS may require **Input Monitoring** (TCC) permission for the host process
  to open a HID keyboard device.
* Pace the packets. The Linux tools do a blocking IN read after every OUT,
  which naturally throttles them. Without that, insert a small delay
  (~1–5 ms) between packets, especially in the per-key burst.

---

## 7. Uncertainties

Things the sources leave ambiguous, contradict each other on, or that may
differ on this TKL board.

1. **TKL key indexing is unknown.** `gmmkctl` ships *only* full-size keymaps
   (US-ANSI and DE-ISO). `GKeyboardController` hardcodes `TOTAL_KEY_COUNT = 104`
   (full-size). Nobody publishes a TKL (87-key) table. Two plausible models:
   (a) the TKL uses the *same* address space and is simply a subset with the
   numpad indices absent, or (b) indices are re-packed and everything after the
   main block shifts. **Determine empirically**: set mode `0x14`, blank all
   LEDs, then light one index at a time and observe. Ship effects/brightness/
   colour first; per-key last.

2. **`gmmk_led.txt` contradicts `gmmk.c` on direction polarity.** The notes file
   says `00 = left, ff = right`; the actual code (`gmmk_setDirLeft` → `0xFF`)
   and `rgb_keyboard`'s decoder (`0xFF → d_left`) both say the opposite. This
   doc follows the code (**`0xFF` = left, `0x00` = right**), but the meaning of
   "left"/"right" is per-effect anyway (some effects read it as up/down or
   inward/outward — `rgb_keyboard` aliases `d_left = d_up = d_inwards`).

3. **Brightness range.** `gmmkctl` README and the official-software captures in
   `GKeyboardController` both say 0–4 (five levels). `rgb_keyboard` allows 0–9
   for non-Ajazz devices. Treat **0–4** as the safe range; values above 4 are
   untested on this board.

4. **Speed/delay range and direction.** `gmmkctl` exposes `delay 0–255` and
   claims "very large values seem to be meaningful"; its own notes file says
   "0–4?"; `rgb_keyboard` treats it as `speed = 3 - value` over 0–3. So the
   field is a *delay* (higher = slower), the UI-facing 0–3 is a *speed*, and
   the usable ceiling is unconfirmed. Clamp to 0–3 for a UI slider.

5. **Is the checksum actually validated?** `rgb_keyboard`'s per-key packets ship
   *hardcoded* checksums that are only correct for one particular colour
   (they bake in a constant `0x240` colour-sum term), yet the tool reportedly
   works — which hints the firmware may ignore the checksum. `gmmkctl` computes
   it correctly at runtime. **Always compute it**; never rely on it being
   ignored.

6. **Config address `0x09`–`0x0B` (second RGB).** Present in the wire capture
   in `gmmk_led.txt` ("set some color?") and never used by any tool. Purpose
   unknown. Do not send.

7. **Profiles.** `rgb_keyboard` shows three 42-byte (`0x2A`) profile blocks at
   `0x00` / `0x2A` / `0x54`, with per-key LED RAM offset by `+0x0200` /
   `+0x0400` per profile, and an "active profile" read via command `0x03` at
   address `0x2C` (reply byte 18, 0-based). `gmmkctl` ignores all of this and
   writes profile 1. Whether the GMMK v1 firmware actually honours profiles 2/3
   is unverified — **stay on profile 1**.

8. **Polling rate at config `0x0F` sits inside profile 1's 42-byte block**, so
   it may be per-profile rather than global. `gmmkctl` says "not really tested".
   This is not a lighting setting; consider leaving it out of the app entirely.

9. **`GMMK_MAX_KEY = 126` vs. highest observed index 117.** `gmmkctl` clamps at
   126 because that is "the highest key value addressed by the Windows
   utility", but its own data files stop at 117. Indices 118–126 are of unknown
   effect. Do not write above 117 without testing.

10. **Whether mode must be set before per-key writes.** Every tool sets mode
    `0x14` first, but no source states it is required rather than merely
    necessary for the colours to be *visible*. LED RAM writes probably persist
    regardless of mode.

11. **Command `0x10`** (read custom colour data) is named in
    `GKeyboardController` but never exercised there; its reply layout is
    unverified.
