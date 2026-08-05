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
