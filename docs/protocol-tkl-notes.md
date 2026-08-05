# GMMK 1 **TKL** — protocol dialect investigation

Companion to [`protocol.md`](protocol.md). That document is derived from
community tools (`gmmkctl`, `rgb_keyboard`, `GKeyboardController`), all of which
were developed against **full-size** boards. This document answers: *does the
GMMK 1 TKL (`0C45:652F`, bcdDevice `0x0108`) speak a different dialect?*

**Headline answer: no.** The official Glorious "GMMK Keyboard Editor" builds for
TKL and Full Size contain a **100 % byte-identical protocol implementation**.
There is no TKL dialect to discover. The reason the board ignores config writes
must be found elsewhere; §5 lists the surviving candidates in priority order.

---

## 1. Method — official software static analysis

### 1.1 Provenance of the binaries

Glorious's legacy-software page ships a *separate installer per size and per
layout*. All three ANSI installers were downloaded and analysed.

| Product | URL | Installer SHA-256 |
|---|---|---|
| GMMK 1 TKL ANSI | `https://downloads.gloriousgamingservices.com/download/GMMK1%20TKL%20ANSI%20software.zip` | `fe95e06c504b0d4ae4b4a482a3856849ef9ba3f0db2daeb83f6e9a09fe607b04` |
| GMMK 1 FS ANSI | `https://downloads.gloriousgamingservices.com/download/GMMK1%20FS%20ANSI%20software.zip` | `d929ed21f383d519949bb8137eec1f6bd31927219e4c57543cc3c44285564ffc` |
| GMMK 1 Compact ANSI | `https://downloads.gloriousgamingservices.com/download/GMMK1%20Compact%20ANSI%20software.zip` | `8af20d16adae0b7498ecd1cfc93d04a2c834804fa991e9e2264c635bde0d6221` |

Index page: <https://www.gloriousgaming.com/pages/legacy-software>.
ISO variants exist at the same URL pattern (`… TKL ISO software.zip`) and were
not analysed — the ANSI/ISO split is a keymap/artwork difference.

Each `.zip` holds one `GMMK Keyboard Editor.exe`, which is **not** the
application: it is an InstallShield 15 self-extractor (PE image ≈ 400 KB plus a
≈ 4.9 MB overlay). The overlay is a flat sequence of
`name\0path\0version\0size\0<data>` records holding `data1.hdr`, `data1.cab`,
`data2.cab`, `setup.exe`, etc. Carving those out and running `unshield` yields
the real application:

| | TKL | Full Size | Compact |
|---|---|---|---|
| application | `GMMK Keyboard Editor.exe` | `GMMK_Keyboard.exe` | `GMMK Keyboard Editor.exe` |
| size | 3 338 752 | 3 315 200 | 4 042 240 |
| PE timestamp | 2022-01-14 06:19:08 Z | 2022-01-21 05:50:33 Z | 2022-01-21 05:55:45 Z |
| `hidapi.dll` shipped | **no** | yes | yes |
| `HidServ.dll` shipped | yes | yes | yes |

All three are PE32 x86 native MSVC/MFC — **not** .NET, so there is no IL to
recover; everything below is from x86 disassembly (Capstone) of `.text`.

Reproduction scripts live in the scratchpad
(`pe.py`, `disx.py`, `table.py`, `decode.py`); they are not part of the repo.

### 1.2 The `hidapi.dll` difference is a red herring

**Confidence: high.** The TKL package omits `hidapi.dll`, which looks like a
transport difference but is not. hidapi is *statically linked into all three
executables* — each imports exactly hidapi's Windows backend surface
(`SetupDiGetClassDevsW`, `SetupDiEnumDeviceInterfaces`, `HidD_GetPreparsedData`,
`HidP_GetCaps`, `CreateFileW`, `WriteFile`, `ReadFile`, `GetOverlappedResult`).
The shipped DLL is vestigial in the FS/Compact packages; the TKL build simply
dropped an unused file. `HidServ.dll` is byte-identical
(`efbafe30a73b…`) across all three and is not referenced by name from any
executable.

---

## 2. What the official software actually does — byte-exact

Everything in this section is read directly out of the **TKL** binary and was
then verified identical in the Full Size binary.

### 2.1 Device selection — identical across all three builds

The matcher (TKL `0x4386E0`, FS `0x435DA0`) is instruction-for-instruction
identical and accepts **two** device IDs:

```
0x0C45 : 0x652F        (GMMK 1 — this board)
0x320F : 0x5064        (later Glorious VID)
```

It then selects usage page `0xFF1C` — i.e. exactly the vendor collection
`protocol.md` §6 already tells you to use. **Confidence: high.** Nothing in the
TKL build looks at `bcdDevice`, product string, or size.

### 2.2 Transport — interrupt OUT output report, *not* a feature report

**Confidence: high.** No build imports `HidD_SetFeature` or
`HidD_SetOutputReport`. Writes go through hidapi's `hid_write` (`0x4020B0`,
identical address in both builds), which is an overlapped `WriteFile` — a HID
**output report on the interrupt OUT endpoint**.

This confirms the transport you are already using is the correct one, and that
`SET_REPORT(Feature)` is *not* how the official tool talks to this board. See §4
for why feature reports on the boot interface are actively dangerous.

### 2.3 The send/receive wrapper (TKL `0x442210`, FS `0x440C20`)

Identical in both builds, called from **19 sites** each, at identical relative
offsets. Pseudocode:

```
EnterCriticalSection(lock)
for attempt in 0..3:
    hid_write(dev, packet, 64, timeout = 1000 ms)     # 0x40 bytes
    LeaveCriticalSection / EnterCriticalSection
    n = hid_read(dev, reply, 64, timeout = 300 ms)    # 0x12C ms
    if n != 0: break                                  # success
LeaveCriticalSection(lock)
```

Three things here are **not** in `protocol.md`:

1. The reply is **not optional**. The official tool reads a 64-byte reply after
   *every* packet and, if the read times out, **re-sends the same packet** up to
   4 times total.
2. Write length is exactly `0x40` = 64 bytes, report ID `0x04` in byte 0.
3. Read timeout is 300 ms; write timeout 1000 ms.

### 2.4 Packet framing and checksum — confirms `protocol.md` exactly

From the START builder (`0x4423E0`), decompiled literally:

```
memset(pkt + 1, 0, 0x3F);      // zero bytes 1..63
pkt[0] = 0x04;                 // report ID
pkt[7] = 0x00;
*(uint32*)(pkt + 3) = 0x00000001;   // cmd=01, count=00, addr=0000

sum = 0;
for (ecx = 3; ecx < 0x40; ecx++) sum += pkt[ecx];   // bytes 3..63
pkt[1] = sum & 0xFF;
pkt[2] = (sum >> 8) & 0xFF;
```

This is **exactly** the algorithm in `protocol.md` §1 — sum of bytes 3‥63,
stored little-endian at bytes 1–2. **Uncertainty #5 in `protocol.md` ("is the
checksum actually validated?") is now settled in the sense that the official
software always computes it correctly at runtime.** Keep computing it.

### 2.5 Reply status byte — new, not in any community tool

**Confidence: high.** Every one of the 19 command wrappers ends with the same
epilogue, checking **byte 7 of the reply**:

| `reply[7]` | Official software's return value |
|---|---|
| `0xFF` | `-102` (error) |
| `0xFE` | `-103` (error) |
| anything else | success |

No community tool inspects this. It gives you a **direct, non-visual success/
failure signal** for every command — by far the most useful bring-up tool this
investigation produced. See §6.

### 2.6 Command table as used by the official software

Extracted from the 19 wrappers. `count` is packet byte 4, `addr` is bytes 5–6.

| Wrapper | cmd | count | addr | Payload | Meaning |
|---|---|---|---|---|---|
| `0x4423E0` | `0x01` | 0 | 0 | — | START |
| `0x442490` | `0x02` | 0 | 0 | — | END — **preceded by `Sleep(10 ms)`** |
| `0x442550` | `0x03` | `0x2C` | 0 | reads 44 B | **Read whole 44-byte config block** |
| `0x442620` | `0x04` | `0x2C` | 0 | writes 44 B at pkt[8..51] | **Write whole 44-byte config block** |
| `0x4426E0` | `0x05` | `0x02` | 0 | reads 2 B | Read 2 config bytes at addr 0 |
| `0x4427B0` | `0x06` | `0x02` | 0 | word at pkt[8..9] | **Write 2 config bytes at addr 0** |
| `0x442870` | `0x07` | var | var | var | (keymap family — do not send) |
| `0x4429E0` | `0x08` | var | var | var | (keymap/macro — do not send) |
| `0x442B50` | `0x09` | var | var | var | (macro — do not send) |
| `0x442CA0` | `0x0A` | var | var | var | (macro — do not send) |
| `0x442DE0`–`0x443000` | `0x0B`–`0x0E` | 0 | 0 | — | four no-argument commands, purpose unknown |
| `0x4430B0` | `0x0F` | var | var | var | unknown |
| `0x4431F0` | `0x10` | var | var | var | read per-key colour RAM |
| `0x4432E0` | `0x11` | var | var | var | **write per-key colour RAM** |
| `0x4433C0` | `0x06` | var | var | var | generic config write (count/addr from caller) |
| `0x443490` | `0x05` | var | var | var | generic config read |

Two findings worth flagging:

* **Command `0x04` — whole-block config write — is used by the official software
  and by no community tool.** `protocol.md` does not mention it at all. It
  writes 44 (`0x2C`) bytes at packet offsets 8‥51. The community tools only ever
  poke individual bytes with `0x06`.
* The block size is **`0x2C` = 44 bytes**, not the `0x2A` = 42 that
  `rgb_keyboard` uses for its profile stride (`protocol.md` §2). At minimum the
  official read/write unit is 44 bytes.
* The fixed-purpose `0x06` wrapper writes **2 bytes at address 0** (mode +
  brightness together), not one byte at a time.

### 2.7 Byte-exact packets

```
START            04 01 00 01 00 00 00 00  <56 × 00>
END              04 02 00 02 00 00 00 00  <56 × 00>     (send Sleep(10ms) first)
READ  cfg block  04 2f 00 03 2c 00 00 00  <56 × 00>
WRITE cfg block  04 CK CK 04 2c 00 00 00  <44 payload bytes> <12 × 00>
READ  2 bytes    04 07 00 05 02 00 00 00  <56 × 00>
WRITE 2 bytes    04 CK CK 06 02 00 00 00  BB BB <54 × 00>
```

`CK CK` = little-endian sum of bytes 3‥63. START/END match `protocol.md` exactly.

---

## 3. What was *not* found (negative results, all useful)

**Confidence: high** for each — these were checked directly, not assumed.

* **No TKL-specific command byte, report length, address base, or checksum
  variant exists.** A normalised diff of the entire command layer (1 649
  instructions, all 19 wrappers, addresses and CRT-helper targets normalised)
  between the TKL and Full Size executables produced **zero differences**.
* **No firmware-version gate.** Nothing reads `bcdDevice`; `0x0108` is never
  compared against anything.
* **No init / handshake / unlock sequence.** Confirms `protocol.md` §5. The
  official software opens the device and sends START.
* **No separate TKL key-index table in the shipped data.** The
  `UserDengColor_*.userd` per-key colour templates are **byte-identical between
  the TKL and Full Size packages** and both enumerate the same **133 key slots**
  (indices 0‥132, `R,G,B,enabled`). This is positive evidence for
  `protocol.md` uncertainty #1 option (a): the TKL uses the **same LED address
  space as the full-size board, with the numpad indices simply absent** — not a
  re-packed layout. **Confidence: medium-high** (identical templates are strong
  but indirect; the mapping from UI slot to wire address was not traced).
* `Main.ini` / `Composite.ini` are UTF-16 UI layout files keyed by **AT
  scancode** (`KEY_01C` = Enter, etc.), not LED addresses. The TKL `Main.ini`
  confirms the expected 87-key ANSI TKL layout and nothing more.

---

## 4. ⚠️ ISP / bootloader hazard — read before probing

**Confidence: high.** Source:
[`SonixQMK/sonix-flasher`](https://github.com/SonixQMK/sonix-flasher)
`src/main/python/main.py`, read directly.

SN32F2xx parts expose the ISP bootloader in userspace; SonixQMK's own docs warn
that this is how boards get soft-bricked. sonix-flasher lists
`(0x0c45, 0x652f)` as **"Glorious GMMK / Tecware Phantom"** in its *stock*
device table, and reboots such a board into the bootloader like this:

```python
def hid_set_feature(dev, report):        # 64-byte FEATURE report, report ID 0x00
    report += b"\x00" * (64 - len(report))
    dev.send_feature_report(b"\x00" + report)

# eVision (this is the GMMK path)
hid_set_feature(dev, struct.pack("<II", 0x5AA555AA, 0xCC3300FF))
# HFD variant
hid_set_feature(dev, struct.pack("<II", 0x5A8942AA, 0xCC6271FF))
```

It selects the device with `dev["interface_number"] <= 0` — i.e. **interface 0,
the boot-keyboard interface**.

**This is precisely the channel you found "succeeds at USB level but has no
effect": a 64-byte, no-report-ID FEATURE report on the boot interface.** It has
no effect because your payload was not a recognised magic. It is not an inert
channel — it is the ISP door.

### Never send

| Channel / bytes | Why |
|---|---|
| **Any feature report on interface 0 (boot keyboard)** | ISP command channel. Do not fuzz it. Do not send feature reports there at all. |
| `AA 55 A5 5A FF 00 33 CC` (`0x5AA555AA`,`0xCC3300FF` LE) | eVision jump-to-bootloader — **the GMMK one** |
| `AA 42 89 5A FF 71 62 CC` (`0x5A8942AA`,`0xCC6271FF` LE) | HFD jump-to-bootloader |
| Any dword `0x55AA00 + n` as a feature report | Bootloader command base: `0x55AA01` INIT, `0x55AA05` PREPARE, `0x55AA07` REBOOT — these erase/program flash |
| Lighting commands `0x07`–`0x0A` | Keymap / macro tables. Out of scope, and corrupting them is a bad day. |

If the board ever re-enumerates as `0C45:7010`, `0C45:7040` or `0C45:7900`, it
is **in the bootloader**, not broken — those are SN32F268F / SN32F248B /
SN32F248 bootloader PIDs. Unplug/replug before doing anything else.

Recovery, if lighting ends up in a strange state: Glorious's own documented
factory reset for GMMK full-size and TKL is **`FN + ESC`, then `F1 + F3 + F5`**;
a snake-like RGB sweep confirms it worked
(<https://glorious.ladesk.com/250552-Some-of-my-GMMK-keys-do-not-work-What-can-I-do>).
**Confidence: medium** — vendor support text, untested here.

---

## 5. So why does the board ignore writes?

The dialect hypothesis is dead. Ranked surviving explanations:

1. **The reply channel is the real symptom, not a side issue.** You observe that
   command `0x05` never replies. The official software *requires* replies — it
   retries any packet whose reply read times out. A board that accepts output
   reports but never produces input reports is behaving consistently with
   "the host never opened / never drains the vendor IN endpoint", which on
   macOS is a plausible IOHIDManager issue rather than a firmware one.
   If `reply[7]` were reachable you would immediately know whether the firmware
   is rejecting commands (`0xFF`/`0xFE`) or accepting them.
2. **Wrong HID collection.** macOS splits a multi-collection device into several
   `IOHIDDevice`s. Matching *usage page* `0xFF1C` / usage `0x92` is necessary but
   the vendor top-level collection can appear on more than one service; writing
   to the wrong one is accepted by IOKit and dropped. Enumerate *all* matches and
   compare `kIOHIDLocationIDKey` / report descriptors rather than taking the
   first.
3. **Never using command `0x04`.** The official software applies settings by
   writing the **whole 44-byte config block**. It is entirely possible this
   firmware revision implements `0x04` and treats short `0x06` writes as no-ops.
   This is the cheapest untested hypothesis and the highest-value probe.
4. **Missing `Sleep(10 ms)` before END**, and missing per-packet reply drain —
   both of which the official software does and the Linux tools accidentally
   emulate via blocking reads. This is consistent with your observation that
   bursts freeze the animation but spaced singles do not.

---

## 6. Safe bring-up probe plan

Ordered by (likelihood × cheapness). **Nothing here touches interface 0, feature
reports, or commands `0x07`–`0x0A`.** All probes are output reports with report
ID `0x04` on the vendor collection (usage page `0xFF1C`, usage `0x92`).

**Probe 0 — get the reply channel working. Do this first; everything else
depends on it.**
Register `IOHIDDeviceRegisterInputReportCallback` with a 64-byte buffer *before*
sending anything, then send `START`. Expect a 64-byte input report, report ID 4.
If nothing arrives, iterate over *every* IOHIDDevice matching `0C45:652F`
(not just the first with the right usage) and repeat. Until a reply arrives you
are debugging blind.

**Probe 1 — read the config block (pure read, zero risk).**
```
04 2f 00 03 2c 00 00 00  <56 × 00>
```
A 44-byte reply payload starting at reply byte 8 tells you the live mode,
brightness, speed, direction, colour — and proves both directions work. Compare
against `protocol.md` §2's field map. Also read with `0x05`:
```
04 07 00 05 02 00 00 00  <56 × 00>
```

**Probe 2 — check `reply[7]` on a known-good no-op.**
Send `START`, inspect `reply[7]`. `0xFF`/`0xFE` mean the firmware is actively
rejecting; anything else means it accepted. Use this as the pass/fail oracle for
every probe below, instead of watching the LEDs.

**Probe 3 — brightness via the official 2-byte write.**
Brightness is the safest visible field (`protocol.md` §2: addr `0x01`, range
0–4). Using the official fixed 2-byte form, writing mode+brightness at addr 0:
```
04 01 00 01 00 00 00 00  <56 × 00>          START
04 CK CK 06 02 00 00 00 MM BB <54 × 00>     mode MM, brightness BB
<Sleep 10 ms>
04 02 00 02 00 00 00 00  <56 × 00>          END
```
with `MM = 0x06` (static) and `BB` swept 0→4. `CK CK` = sum of bytes 3‥63.
Read the reply after each packet.

**Probe 4 — the whole-block write (`0x04`). The key experiment.**
Read the 44-byte block with Probe 1, change **only** byte 1 (brightness) in the
returned payload, write it back:
```
04 CK CK 04 2c 00 00 00 <the 44 bytes, one byte modified> <12 × 00>
```
inside START/END with the 10 ms pause before END. If this works where `0x06`
did not, that is the answer, and the app should be built on `0x03`/`0x04`
read-modify-write rather than byte pokes.

**Probe 5 — per-key colours, last.**
Only after 1–4 succeed. Set mode `0x14`, then `0x11` writes. Because the
`.userd` templates are identical between TKL and Full Size, **start from the
assumption that the full-size key→address map in `protocol.md` §4 is correct and
that TKL simply lacks the numpad indices.** Verify by lighting one index at a
time from a blanked state, per `protocol.md` uncertainty #1.

Throughout: one packet per write, drain the reply after each, ~5 ms spacing, and
keep a single device-open for a whole START…END transaction.

---

## 7. Angles not yet exhausted

Stated plainly so nobody re-runs them believing they were completed.

* **Issue-tracker archaeology was only skimmed.** Targeted searches surfaced no
  report of a TKL ignoring commands, but the issue lists of `paulguy/gmmkctl`,
  `dokutan/rgb_keyboard` and `hangrydave/GKeyboardController` were **not** read
  exhaustively, and no GitHub code search for `0x652F` outside those projects was
  run. One unexamined lead: [`Kolossi/GmmkUtil`](https://github.com/Kolossi/GmmkUtil),
  a fourth GMMK lighting tool not cited in `protocol.md`.
* **No published USB capture of GMMK Editor ↔ TKL was found**, but the search
  was not thorough. Given §2, a capture would now only confirm the static
  analysis.
* **The ISO TKL installer was not analysed** — expected to differ only in keymap
  and artwork.
* **Which SN32 part the TKL carries was not pinned down.** Only relevant for
  flashing, which is out of scope; the three bootloader PIDs in §4 cover the
  family either way.
* The purposes of commands `0x0B`–`0x0F` are unknown; none were sent.

---

# Part 2 — the apply flow, profiles, and commands `0x0B`–`0x0E`

Second pass over the same TKL binary (`app_tkl.exe`, PE timestamp
2022-01-14 06:19:08 Z), prompted by live hardware results: with correct 64-byte
framing the board now ACKs every packet with status `0x00`, config reads return
what we wrote, and **brightness applies visibly — but mode changes do not**, and
nothing survives a replug.

**Headline: the effect-mode write is not missing an "apply" command. It is being
written to the wrong profile.** The board runs whichever profile is named by
**byte 10 of the 44-byte config block**, and the official software changes that
byte with a `0x03`/`0x04` read-modify-write. Everything else below is
supporting detail.

## 8. Answer to Q1 — the complete effect-change sequence

The UI effect selector is a 20-entry jump table (`0x42C9D4`, table at
`0x42D374`, one arm per mode `0x01`–`0x14`). Every arm is the same shape
(`0x42C9DB` is the mode-1 arm):

```c
mode    = <selected effect, 1..0x14>;
rainbow = (g_rainbowFlag /*0x6EEAAC*/ != 0);

START();                                   // cmd 0x01
write06(&mode,    1, g_uiProfile*0x2A + 0);  // cmd 0x06, config offset 0
write06(&rainbow, 1, g_uiProfile*0x2A + 4);  // cmd 0x06, config offset 4
END();                                     // cmd 0x02, after Sleep(10 ms)

repaintSwatches(0);                        // 0x41B3A0 — pure UI, NO HID
```

`0x41B3A0` was checked in full: it walks a dialog control-ID array
(`0x657DC0`‥`0x657F60`) calling a widget setter. **It sends nothing to the
device.** There is no apply, refresh, commit, or latch command after END.

**So an effect change is exactly four packets: START, mode, rainbow, END.**
That is what we are already sending. **Confidence: high.**

The generic config-write wrapper (`0x4433C0`, 38 call sites — the only `0x06`
form actually used) is:

```c
int write06(const void *payload, int count, int addr);
// pkt[0]=0x04  pkt[3]=0x06  pkt[4]=count  pkt[5]=addr&0xFF  pkt[6]=addr>>8
// pkt[7]=0     pkt[8..]=payload[0..count-1]
```

### 8.1 Every config address is profile-relative

**This is the finding that matters.** Every one of the 38 `0x06` call sites
computes its address as

```asm
mov  ecx, [0x6EEAC4]      ; active/edited profile index (0, 1, 2)
imul ecx, ecx, 0x2A       ; × 42
add  ecx, <field offset>  ; omitted when the field offset is 0
push ecx                  ; -> addr
```

**Profile stride is `0x2A` = 42 bytes**, confirmed at every site. (The `0x2C` =
44 in commands `0x03`/`0x04` is the *block transfer size*, a different thing —
42 bytes of profile 0 plus 2 trailing bytes. Part 1 conflated these; this
supersedes it.)

Field offsets observed in the wild, confirming `protocol.md` §2:
`+0` mode, `+3` direction, `+4` rainbow, `+5` RGB (count 3), `+9` RGB2
(count 3), `+0xF` polling rate.

### 8.2 Byte-exact — same effect change, per profile

```
START                       04 01 00 01 00 00 00 00  <56 × 00>
mode = 0x06 (static)        04 0d 00 06 01 00 00 00 06  <55 × 00>   profile 0
                            04 37 00 06 01 2a 00 00 06  <55 × 00>   profile 1
                            04 61 00 06 01 54 00 00 06  <55 × 00>   profile 2
rainbow = 0                 04 0b 00 06 01 04 00 00 00  <55 × 00>   profile 0
                            04 35 00 06 01 2e 00 00 00  <55 × 00>   profile 1
                            04 5f 00 06 01 58 00 00 00  <55 × 00>   profile 2
END  (Sleep 10 ms first)    04 02 00 02 00 00 00 00  <56 × 00>
```

The profile-0 mode packet `04 0d 00 06 01 00 00 00 06` is byte-identical to the
golden capture already in `protocol.md` §2.1 — independent cross-validation that
this decoding is right.

## 9. Answer to Q3 — the active-profile selector (the actual bug)

Two *different* profile notions exist in the app, and conflating them is what
makes this confusing:

| Global | Meaning | Touches the device? |
|---|---|---|
| `0x6EEAC4` | which profile the **UI is editing** | **no** |
| `0x6F3468` | cached copy of the **device's active profile** | yes, via `0x03`/`0x04` |

**The UI profile radio buttons send no HID traffic at all.** The three handlers
(`0x4196B8`, `0x419706`, `0x419755`) only tick three checkboxes and store
0/1/2 into `0x6EEAC4`. They just retarget where subsequent `0x06` writes land.

The device's active profile lives in **byte 10 of the 44-byte config block**:

**`GetActiveProfile()` — `0x43F6A0`**
```c
uint8_t blk[44];
read44(blk);                 // cmd 0x03, count 0x2C, addr 0x0000
g_deviceProfile = blk[10];   // [ebp-0x30]+10 == [ebp-0x26]
```

**`SetActiveProfile(int n)` — `0x43F700`** (3 call sites: `0x441285`,
`0x44137D`, `0x4417A3`)
```c
uint8_t blk[44];
if (n < 0) return -1;
if (read44(blk) != 1) return -1;   // cmd 0x03  — read-modify-write
blk[10] = (uint8_t)n;
if (write44(blk) != 1) return -1;  // cmd 0x04
g_deviceProfile = blk[10];
```

On connect (`0x431E45`) the app does exactly this read and seeds *both* globals
from `blk[10]`, i.e. the UI opens on whatever profile the board is actually
running.

The `0x03` wrapper copies `reply[8..51]` into the caller's buffer (`lea esi,
[ebp-0x7c]` = reply+8, `rep movsd` ×11), so **block byte 10 == reply byte 18**.
That independently confirms `rgb_keyboard`'s "active profile … reply byte 18,
0-based" noted in `protocol.md` uncertainty #7 — and pins it to a concrete
config address, `0x0A`.

> **`protocol.md` §2 lists config `0x09`–`0x0B` as "second RGB, purpose unknown,
> do not send". That is wrong for `0x0A`, at least as read through the `0x03`
> block: `0x0A` is the active-profile selector.** Note the app writes RGB2 with
> `0x06` at `profile*0x2A + 9` (count 3), which for profile 0 would overlap
> `0x0A`–`0x0B`. Treat the overlap as unresolved and prefer the `0x03`/`0x04`
> block path for the profile byte.

### 9.1 Why our mode change appears to do nothing

Our block read shows profile 2's fields at `0x2A` holding `01 04` (wave,
brightness 4) and the board is displaying a wave. That is consistent with
`blk[10] == 1`, i.e. **the board is running profile index 1 while we write
profile index 0**. Mode is read by the effect engine from the *active* profile,
so our `0x06` write to address `0x00` lands in a profile nobody is running.

Brightness appearing to work while mode does not is the one part this does not
explain — it suggests brightness is applied globally/immediately by the
firmware while mode is latched per-profile. Worth confirming rather than
assuming. **Confidence: high** on the profile mechanism (read straight out of
`SetActiveProfile`), **medium** on it being the sole cause of the symptom.

### 9.2 Byte-exact — switch the board to profile 0

Not bracketed by START/END — verified by a byte-level scan of all three call
sites' neighbourhoods, which contain no calls to the START or END wrappers.

```
1) read     04 2f 00 03 2c 00 00 00  <56 × 00>
            -> reply[8..51] = blk[0..43];  blk[10] is the active profile
2) blk[10] = 0x00
3) write    04 CK CK 04 2c 00 00 00  <blk[0..43]>  <12 × 00>
            CK = sum of bytes 3..63, little-endian at 1..2
```

## 10. Answer to Q2 — `0x0B`, `0x0C`, `0x0D`, `0x0E` (and `0x0F`)

**All four have exactly zero call sites.** They are compiled-in but dead —
the official editor never sends them. Structurally they are all
"cmd, count 0, addr 0, no payload, no arguments". The only distinguishing
feature: **`0x0C` calls `Sleep(10 ms)` before transmitting, exactly like END
(`0x02`)**; `0x0B`, `0x0D`, `0x0E` do not.

So there is **no evidence from the official software about what they do**, and
in particular **no evidence that any of them is the missing "apply" or "save to
flash"** — the app applies effects and switches profiles without them.

> ⚠️ **Hazard: treat `0x0B`–`0x0E` as unknown-dangerous and do not send them.**
> Dead no-argument commands in a keyboard's vendor protocol are exactly where
> "restore factory defaults", "erase config", "erase key/macro tables" and
> "enter test mode" live. We cannot rule any of those out, and a command taking
> no arguments is one that cannot be sent "harmlessly small". There is nothing
> to gain: the full apply path is already accounted for without them.

Also dead (zero callers), for completeness: the fixed-form `0x05` read-2
(`0x4426E0`), the fixed-form `0x06` write-2 (`0x4427B0`), and `0x10` read-key-RGB
(`0x4431F0`). Part 1 described the fixed `0x06` as "the official form" — that
was wrong; the *generic* `0x4433C0` form is the one actually used.

**`0x0F` is live** (one call site, `0x43F930`). It reads into a `0x204`-byte
buffer and the caller then copies `0x80` dwords = **512 bytes** = `0x200`, the
per-profile LED-RAM stride. So `0x0F` is a **bulk read of per-key colour RAM**,
used on profile load. Read-only; not part of applying an effect.

## 11. Answer to Q4 — what surrounds the `0x04` block write

`0x04` has **exactly one call site in the entire binary**: inside
`SetActiveProfile` (§9). It is used only as the write half of a
read-modify-write of the 44-byte block, it is **not** bracketed by START/END,
and **nothing is sent after it**. The official editor never uses `0x04` to push
ordinary lighting settings — those always go through `0x06`.

### 11.1 There is no flash-commit command

Searched exhaustively across all 19 wrappers and their ~140 call sites: the
official editor's entire device-write vocabulary is
`0x01` START, `0x02` END, `0x03` read block, `0x04` write block,
`0x06` write config, `0x07`–`0x0A` keymap/macros, `0x0F` read key RAM,
`0x11` write key RAM. **No save/commit/persist command exists.** Persistence, if
the firmware provides it, must be implicit — most plausibly on END, or on the
`0x04` block write.

That makes "our writes don't survive a replug" a genuinely open question rather
than a missing-packet problem. The most likely explanation consistent with §9 is
that we are writing to a non-active profile which the firmware never flushes.
**Confidence: low-medium** — this is a hypothesis, not a decoded fact.

## 12. Revised probe plan

1. **Read the block and print byte 10.** `04 2f 00 03 2c 00 00 00`. This single
   read tells you which profile the board is running and should immediately
   confirm or kill the §9.1 diagnosis. Do this before changing anything.
2. **Retarget writes to the active profile.** If `blk[10] == 1`, write mode to
   `0x2A` and rainbow to `0x2E` (packets in §8.2) rather than `0x00`/`0x04`.
   If the wave changes to static, that is the whole bug.
3. **Or move the board to profile 0** with the §9.2 read-modify-write, then keep
   using the profile-0 addresses you already have.
4. **Re-test persistence** only after 2 or 3 succeeds — writing to the running
   profile may be what makes it stick.
5. Do **not** send `0x0B`–`0x0E` (§10), and nothing from Part 1 §4.

**Still unverified:** why brightness applies while mode does not; whether the
firmware honours profiles 1/2 for every field; whether config `0x0A` really is
the profile byte in the `0x06` address space as well as through the `0x03`
block (the RGB2-at-`+9` overlap in §9 is unresolved).

---

# Part 3 — Verified on hardware (2026-08-05, fw 1.08)

Parts 1 and 2 are static analysis and inference. **This part is empirical**:
everything below was observed on a GMMK 1 TKL, `0C45:652F`, firmware 1.08, and
it takes precedence wherever it contradicts the earlier parts. It is also the
behaviour the library in `Sources/` implements.

## 13.1 Transport — 64 bytes, output report, vendor interface

The only channel that works is an **Output report, report ID 4, on the vendor
interface** (usage pair `0xFF1C`/`0x92`), where the `SetReport` payload is the
**full 64-byte wire packet including the leading `0x04`**.

macOS does *not* prepend the report ID on this pipe. Passing the bare 63 bytes —
the ordinary IOKit convention, and what `protocol.md` §6 originally documented —
delivers a packet one byte short, and the firmware answers with an **unprefixed
error echo that macOS misparses as phantom keypresses**. That symptom is the
signature of this specific mistake; it does not mean the board is rejecting the
command's contents. Fixed in `GMMKKeyboard.send(payload:)`, `.vendorOutput` case.

## 13.2 Replies are informative, not required

The firmware echoes every command on **input report ID 4** with a **status byte
at wire offset 7**: `0x00` = OK, `0xFF`/`0xFE` = error. This confirms Part 1 §2.5
from the device side.

Replies are **not required for a write to reach config RAM**: sequences that
opened the device multiple times and never drained the input queue still took
effect.

> ⚠️ Refined by §13.7. A write being *stored* and a write being *applied* to the
> running effect engine are different things, and pacing on these replies turns
> out to be what makes the second happen. The send path **is** built around them.

## 13.3 Config writes are profile-relative — write all three bases

Confirms Part 2 §8.1 empirically. A config field's address is
`profileBase + fieldOffset`, with three bases **`0x0000`, `0x002A`, `0x0054`**
(stride `0x2A` = 42). Field offsets are `protocol.md` §2: `+0` mode,
`+1` brightness, `+2` delay, `+3` direction, `+4` rainbow, `+5` RGB (3 bytes,
**R-G-B order verified**).

The board applies the fields of the profile it is *running*, and §13.4 removes
the only way to ask which that is. So **every logical operation writes its fields
at all three bases inside one `START`/`END` transaction.** With that, mode,
colour and rainbow all apply instantly; brightness applies globally and live
regardless (its repetition is redundant but keeps the three profiles
consistent). This resolves the Part 2 §9.1 symptom — mode changes that appeared
to do nothing were landing in a profile the board was not running.

Verified wire examples (checksum = sum of bytes 3‥63, little-endian at 1‥2):

```
mode 0x06 @ profile 1     04 37 00 06 01 2a 00 00 06
rainbow off @ profile 1   04 35 00 06 01 2e 00 00 00
RGB ff8800  @ profile 1   04 bf 01 06 03 2f 00 00 ff 88 00
```

## 13.4 Command `0x03` returns a device-info block on this firmware

**This supersedes Part 2 §9.** On fw 1.08, `0x03` with count `0x2C` does **not**
return the 44-byte config block. It returns a **device-info block**: `55 aa`
magic, `ff`, one unidentified byte, VID and PID little-endian, firmware version
little-endian, then the list of supported mode IDs.

Consequences:

* There is no active-profile byte to read, hence §13.3.
* **Do not implement `SetActiveProfile` as a `0x03`/`0x04` read-modify-write.**
  The Part 2 §9.2 sequence was decoded correctly from the official binary, but
  its semantics do not hold on this firmware, and a `0x04` block write built
  from a misread `0x03` reply would write 44 bytes of device-info garbage into
  config RAM.
* `0x05` (read config RAM by address) works as documented. Use it for reads.

## 13.5 Per-key colour RAM (`0x11`) — ACKed, display path unresolved

`0x11` writes are accepted with status `0x00`, including a full sweep of indices
1‥126 at `address = keyIndex * 3`, but **nothing on the display changed** — not
even with mode `0x14` (custom) set at all three profile bases first. So either
the LED address space differs from the full-size boards the community key maps
describe, or some further step latches LED RAM.

The per-key builders stay in the library because they are byte-correct against
those tools, and they are marked unresolved in their doc comments. **No UI
exposes them.** Resolving this needs a from-blank, one-index-at-a-time sweep.

## 13.6 Safety invariants — enforced, keep them enforced

Unchanged from Part 1 §4 and Part 2 §10, restated because they are the
invariants the code is built around:

1. **Never send feature reports to the boot interface (interface 0).** That is
   the SN32 ISP bootloader door and the path to a soft-brick. The transport
   matches on the vendor usage pair only, and the `boot-feature` probe that
   briefly existed during bring-up was deliberately deleted rather than left
   behind a flag.
2. **Never send commands `0x07`–`0x0A`** (keymap / macro tables) — out of scope,
   and corrupting them is a bad day.
3. **Never send commands `0x0B`–`0x0E`** — no-argument commands that the
   official editor never sends. A no-argument command cannot be sent
   "harmlessly small", and this is exactly where factory-reset and erase
   functions live. There is nothing to gain: the full apply path is accounted
   for without them.

`GMMKPacket.Command` deliberately does not name any of these.

## 13.7 Packets must be paced, or writes are stored but never applied

**This is a requirement, not a politeness.** A blind burst of config writes with
2 ms gaps is accepted (every packet ACKs `0x00`) and lands in config RAM — a
subsequent `0x05` read returns what was written — but the running effect engine
**does not pick it up**. The lighting only changes at some later latch.

Two pacings were observed to make the identical packets apply *instantly*:

1. **~350 ms wall-clock gaps** between packets. Works, but a
   solid-colour transaction is 14 packets, so this is ~5 s of latency.
2. **Reply pacing** — after every `SetReport`, wait for the firmware's echo on
   input report ID 4 before sending the next packet. **Verified end-to-end**
   (`gmmk-cli probe2`) and this is what the official editor does: write, then
   `hid_read` with a 300 ms timeout, retrying the same packet up to 4 times.
   Echoes come back within a few milliseconds, so a whole transaction is still
   imperceptible.

(2) is the library's default, in `GMMKKeyboard.send(packets:)` via `ReplyPacer`.
It supersedes the "replies are advisory" reading of §13.2: replies are not
required for a write to be *stored*, which is what §13.2 observed, but they are
what paces the sequence so it is *applied*.

Implementation notes worth keeping:

* A missed echo is **not** an error. The packet is re-sent up to 4 times and
  then skipped, because a missed reply does not mean a missed write. Only an
  explicit `0xFF`/`0xFE` status fails the transaction.
* Once one packet has exhausted its attempts, the rest of the transaction falls
  back to pacing (1) rather than waiting out a 300 ms timeout per packet —
  otherwise one unresponsive device blocks the caller for ~17 s.
* The device is scheduled on the run loop in a **private run-loop mode**, and
  only that mode is pumped while waiting. Pumping the default mode from the
  app's main thread would re-enter UI event delivery mid-transaction, letting a
  second menu action start while the first is still going out.
* `interPacketDelay` survives as an additional floor (default 0, CLI override
  `GMMK_PACKET_DELAY_MS`), as does the 10 ms sleep before `END`.
