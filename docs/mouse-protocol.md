# Glorious Model O / O- (wired) — SinoWealth configuration protocol

Byte-exact reference for the **wired** Glorious Model O and Model O-,
`258A:0036`. Companion to [`protocol.md`](protocol.md) and
[`protocol-tkl-notes.md`](protocol-tkl-notes.md), which cover the GMMK 1
keyboard — **a completely different device with a completely different
protocol**. Nothing in the keyboard documents transfers here: the mouse has no
`START`/`END` bracketing, no 64-byte command packets, no checksum, and no
interrupt OUT channel at all.

**Status: no hardware I/O was performed for this document.** Everything below is
either (a) a fact measured earlier on the target hardware, marked
**[measured]**, or (b) read directly out of published source, cited by file and
line. Nothing here is inference dressed as fact; where sources disagree or fall
silent, §11 says so.

---

## 1. Device identity and interfaces

| | |
|---|---|
| VID:PID | `0x258A:0x0036` |
| MCU | SinoWealth SH68F89 (8051), marked `BY8948` — sinowisp `README.md` device table |
| Sensor | PixArt **PMW3360**, sensor ID `0x06` — libratbag `data/devices/glorious-model-o.device` |
| Firmware version string | 4 ASCII chars, e.g. `V103` |

**Model O and Model O- are the same device to software.** Confirmed in both
sources independently:

* OpenRGB registers **one** detector for both:
  `Controllers/SinowealthController/SinowealthControllerDetect.cpp:419`
  — `REGISTER_HID_DETECTOR_P("Glorious Model O / O-", DetectSinowealthMouse, SINOWEALTH_VID, Glorious_Model_O_PID, 0xFF00)`.
* libratbag ships **one** device file for both,
  `data/devices/glorious-model-o.device`: `Name=Glorious Model O/O-`,
  `DeviceMatch=usb:258a:0036`, with a single firmware section `V103`.

Neither source contains a single byte of Model-O-vs-O- conditional logic. The
`-` is a shell/weight difference; the PCB, sensor, LED count and config blob are
identical. **Confidence: high.** (The *wireless* Model O/O- is a different
device entirely — PIDs `0x2022`/`0x2011` and a separate OpenRGB controller,
`SinowealthGMOWController`. Out of scope.)

### 1.1 HID collections — **[measured]**

The vendor configuration interface presents three top-level collections with
usage pairs `(0x01,0x06)`, `(0x0C,0x01)`, `(0xFF00,0x01)`. Reports on it:

| Report | Type | Size (payload, excl. ID) | Role |
|---|---|---|---|
| `0x04` | FEATURE | 519 (`MaxFeatureReportSize` 520) | configuration blob |
| `0x05` | FEATURE | 5 | command channel |
| `0x07` | INPUT | 7 | unidentified — see §11 |

The 520 includes the leading report-ID byte, matching both sources exactly
(`SINOWEALTH_CONFIG_REPORT_SIZE 520` in libratbag `driver-sinowealth.c:70` and
OpenRGB `SinowealthController.h:20`). The 6-byte command buffer likewise matches
`SINOWEALTH_CMD_SIZE 6` (`driver-sinowealth.c:67`).

OpenRGB's detector expects exactly **3** collections for this device
(`DetectSinowealthMouse` passes `device_count_expected = 3`,
`SinowealthControllerDetect.cpp:284`), which is an independent confirmation of
the measured usage-pair count. It then probes each collection by sending
`05 11 00 00 00 00` and trying `GetFeature(0x04, 520)`, keeping whichever
collection answers (`SinowealthControllerDetect.cpp:281-282`).

> On macOS the collection that answers must be found by probing, exactly as
> OpenRGB does — not by assuming the `0xFF00` one. OpenRGB opens the *same*
> handle for command and data when only one collection responds; the
> `dev_cmd`/`dev_data` split exists because on some units they differ
> (`SinowealthController.cpp:17-25`).

### 1.2 Transport — **[measured]**

**Feature reports only.** `SetFeature` and `GetFeature` on the collection above.
There is no interrupt OUT endpoint in the configuration path. Both sources agree:
libratbag uses `ratbag_hidraw_set_feature_report` /
`ratbag_hidraw_get_feature_report` throughout (`driver-sinowealth.c:937,946,975,1171`),
OpenRGB uses `hid_send_feature_report` / `hid_get_feature_report`
(`SinowealthController.cpp:77,81,175,187,199`).

**There is no checksum and no CRC anywhere in this protocol.** Grepped for both
across the whole of `driver-sinowealth.c` and every OpenRGB Sinowealth file: zero
hits. Do not compute one; the keyboard's byte-3..63 sum has no analogue here.

---

## 2. Report 5 — the command channel

Six bytes, always: `05 <cmd> <arg0> <arg1> <arg2> <arg3>`, byte 0 being the
report ID. Unused bytes are zero.

Two access patterns, both from `driver-sinowealth.c`:

* **Read query** (`sinowealth_query_read`, `driver-sinowealth.c:918-968`) —
  `SetFeature(5, 6 bytes)` with the command, then `GetFeature(5, 6 bytes)`.
  The reply's byte 1 **must** echo the command byte; libratbag treats a mismatch
  as `-EIO` (`driver-sinowealth.c:961-966`). Use that as your validity oracle.
* **Write query** (`sinowealth_query_write`, `driver-sinowealth.c:969-991`) —
  `SetFeature(5, 6 bytes)` and nothing else.

### 2.1 Verb table

`enum sinowealth_command_id`, `driver-sinowealth.c:37-62`. The "safe" column is
this document's judgement, not the source's.

| Cmd | Name | Direction | Safe | Semantics |
|---|---|---|---|---|
| `0x01` | `FIRMWARE_VERSION` | read | ✅ | reply bytes 2‥5 = 4 ASCII chars, e.g. `V103` (`driver-sinowealth.c:1040-1056`) |
| `0x02` | `PROFILE` | read/write | ✅ | read: reply byte 2 = active profile, **1-based** (`:1004`). write: byte 2 = index+1 (`:1023`) |
| `0x11` | `GET_CONFIG` | read-trigger | ✅ | arms report 4 to return **profile 1's** config blob |
| `0x12` | `GET_BUTTONS` | read-trigger | ⚠️ | arms report 4 to return profile 1's **88-byte button map** — out of scope |
| `0x1a` | `DEBOUNCE` | read/write | ✅ | byte 2 = milliseconds ÷ 2 (`:1059-1104`). *"Doesn't work on devices with shorter configuration data"* (`:43`) |
| `0x1b` | `LONG_ANGLESNAPPING_AND_LOD` | read/write | ❌ | **explicitly documented as not working on Glorious Model O** (`:1108-1110`). Use blob byte `0x81` instead — §7 |
| `0x21` | `GET_CONFIG2` | read-trigger | ✅ | as `0x11`, profile 2 |
| `0x22` | `GET_BUTTONS2` | read-trigger | ⚠️ | as `0x12`, profile 2 |
| `0x30` | `MACRO` | write | ❌ | 515-byte macro upload. Out of scope |
| `0x31` | `GET_CONFIG3` | read-trigger | ✅ | as `0x11`, profile 3 |
| `0x32` | `GET_BUTTONS3` | read-trigger | ⚠️ | as `0x12`, profile 3 |
| `0x55`,`0x52`,`0x57`,`0x45`,`0x5A` | — | — | ☠️ | **ISP bootloader verbs. See §9.** |
| `0x75` | `DFU` | write | ☠️ | **enters the ISP bootloader. See §9.** |

Note that OpenRGB only ever uses `0x01` and `0x11`
(`SinowealthController.cpp:74-84`, `:184-185`) and never reads the active
profile.

---

## 3. Reading the configuration blob

Two `SetFeature`/`GetFeature` pairs on two different report IDs. Byte-exact:

```
1)  SetFeature(report 5)   05 11 00 00 00 00
2)  GetFeature(report 4)   -> 520-byte buffer; buf[0] = 0x04, buf[1] echoes 0x11
```

Step 1 is `sinowealth_query_write` with `{ REPORT_ID_CMD, config_cmd }`
(`driver-sinowealth.c:1163-1168`); step 2 is a bare `GetFeature` of
`SINOWEALTH_CONFIG_REPORT_SIZE` (`:1174`). OpenRGB does exactly the same thing
in `GetProfile()`, `SinowealthController.cpp:184-199`, including pre-setting
`device_configuration[0] = 0x04`.

For profiles 2 and 3, substitute command `0x21` / `0x31`.

**Sanity-check the reply before trusting it.** libratbag requires the returned
length to land in `[123, 167]` and errors out otherwise (`:1180-1184`); OpenRGB
refuses to write if the read returned fewer than 131 bytes
(`SinowealthController.cpp:96`, `SINOWEALTH_CONFIG_SIZE_MIN 131`). At minimum,
check `buf[1] == 0x11`.

---

## 4. Writing the configuration blob

**The write is a read-modify-write of the whole blob.** There is no way to poke
a single field; you must read the blob, change bytes, and send it back. Both
sources do exactly this.

```
1)  read the blob per §3
2)  modify the fields you want (§5 onward)
3)  buf[0] = 0x04                     report ID
    buf[1] = 0x11 / 0x21 / 0x31       which profile you are writing
    buf[3] = <config size> - 8        write marker (0x00 means "read")
4)  SetFeature(report 4, 520 bytes)
```

Sources for each byte:

* `buf[3]` — `struct sinowealth_config_report.config_write`, documented as
  *"0x0 - read. CONFIG_SIZE-8 - write."* (`driver-sinowealth.c:246-249`) and set
  as `config->config_write = (uint8_t)drv_data->config_size - 8` in
  `sinowealth_write_configs` (`:1953`).
* OpenRGB hardcodes `usb_buf[0x03] = 0x7B` with the comment `//write to device`
  (`SinowealthController.cpp:101`). `0x7B` = 123 = **131 − 8**, and OpenRGB's
  `SINOWEALTH_CONFIG_SIZE_MIN` is 131. So OpenRGB believes the Model O's config
  blob is **131 bytes**, not 167. See §11 — this is the single most important
  open question in this document.
* OpenRGB additionally forces `usb_buf[0x06] = 0x00`
  (`SinowealthController.cpp:102`), a byte libratbag calls `unknown2[2]`. No
  source explains it. Preserving the read-back value is the conservative choice;
  OpenRGB clearing it is evidence it is at worst harmless.

There is **no separate commit, save or apply command.** `sinowealth_commit`
(`driver-sinowealth.c:2139-2178`) writes configs, then buttons, then macros,
then debounce — and stops. The blob write is itself the commit; settings are
stored in the mouse's flash and survive a replug. OpenRGB marks every mode
`MODE_FLAG_AUTOMATIC_SAVE` for the same reason
(`RGBController_Sinowealth.cpp:38,48,55,…`).

---

## 5. Configuration blob layout

Offsets are **into the report-4 buffer including the leading report-ID byte at
offset 0**, which is how both sources index it — OpenRGB's `usb_buf[0x35]` and
libratbag's `struct sinowealth_config_report` field 53 are the same byte.

Structure: `driver-sinowealth.c:239-300`. Offsets below were computed from that
packed struct and then **checked one by one against every literal offset OpenRGB
uses**; all sixteen OpenRGB offsets agree exactly. That cross-check is the
strongest evidence in this document.

| Offset | Size | Field | Encoding | Verified by |
|---|---|---|---|---|
| `0x00` | 1 | report id | always `0x04` | both |
| `0x01` | 1 | command id | `0x11`/`0x21`/`0x31` — profile selector | libratbag `:244` |
| `0x02` | 1 | unknown1 | preserve | libratbag `:245` |
| `0x03` | 1 | **config_write** | `0x00` = read, `size−8` = write | libratbag `:246-249`; OpenRGB `:101` (`0x7B`) |
| `0x04`–`0x08` | 5 | unknown2 | preserve | libratbag `:250` |
| `0x09` | 1 | **sensor type** | `0x06` PMW3360, `0x08` PMW3212, `0x0E` PMW3327, `0x0F` PMW3389. **Read-only — never write** | libratbag `:161-168,251` |
| `0x0A` | 1 | **polling rate** (low nibble) / config flags (high nibble) | rate: `1`=125, `2`=250, `3`=500, `4`=1000 Hz. flags bit 3 (`0b1000`) = XY-independent DPI | libratbag `:252-255,663-668`, `:141-145` |
| `0x0B` | 1 | **dpi_count** (low nibble) / **active_dpi** (high nibble) | active_dpi is **1-based, counting only enabled slots** | libratbag `:256-258` |
| `0x0C` | 1 | **disabled DPI slots** | bitmask, **bit set = slot disabled** | libratbag `:259-260`, `:2108` |
| `0x0D`–`0x1C` | 16 | **DPI stages** | 8 × 1 byte, or 8 × `{x,y}` pairs if the XY-independent flag is set. Encoding in §6 | libratbag `:212-235,261` |
| `0x1D`–`0x34` | 24 | DPI stage indicator colours | 8 × 3 bytes, same colour order as §5.2 | libratbag `:262` |
| `0x35` | 1 | **RGB effect** | §5.1 | libratbag `:263`; OpenRGB `:104` |
| `0x36` | 1 | "Glorious"/rainbow mode | speed low nibble, brightness high nibble (§5.3) | libratbag `:264`; OpenRGB `:109` |
| `0x37` | 1 | rainbow direction | `0x00` down, `0x01` up | libratbag `:265`; OpenRGB `:110`, `.h:52-55` |
| `0x38` | 1 | single-colour mode | speed/brightness nibbles | libratbag `:266`; OpenRGB `:113` |
| `0x39`–`0x3B` | 3 | **single colour** | **R, B, G** — see §5.2 | libratbag `:267`; OpenRGB `:114-116` |
| `0x3C` | 1 | breathing-7 mode | speed/brightness nibbles | libratbag `:268`; OpenRGB `:120` |
| `0x3D` | 1 | **breathing-7 colour count** | 1–7 | libratbag `:269` |
| `0x3E`–`0x52` | 21 | breathing-7 colours | 7 × RBG | libratbag `:270`; OpenRGB `:123-143` |
| `0x53` | 1 | tail mode | speed/brightness nibbles | libratbag `:271`; OpenRGB `:146` |
| `0x54` | 1 | full-RGB breathing mode | speed/brightness nibbles | libratbag `:272`; OpenRGB `:149` |
| `0x55` | 1 | constant-colour mode | speed/brightness nibbles | libratbag `:273` |
| `0x56`–`0x67` | 18 | constant-colour colours | 6 × RBG, one per LED | libratbag `:274` |
| `0x68`–`0x73` | 12 | unknown3 | preserve | libratbag `:275` |
| `0x74` | 1 | rave mode | speed/brightness nibbles | libratbag `:276`; OpenRGB `:152` |
| `0x75`–`0x7A` | 6 | rave colours | 2 × RBG | libratbag `:277`; OpenRGB `:153-158` |
| `0x7B` | 1 | random mode | speed/brightness nibbles | libratbag `:284` |
| `0x7C` | 1 | wave mode | speed/brightness nibbles | libratbag `:285`; OpenRGB `:161` |
| `0x7D` | 1 | breathing-1 mode | speed/brightness nibbles | libratbag `:286`; OpenRGB `:164` |
| `0x7E`–`0x80` | 3 | breathing-1 colour | RBG | libratbag `:287`; OpenRGB `:165-167` |
| `0x81` | 1 | **lift-off distance** | `0x01` = 2 mm, `0x02` = 3 mm, `0xFF` = "set via command `0x1b`" — **do not overwrite `0xFF`** | libratbag `:288-292` |
| `0x82` | 1 | unknown4 | preserve | libratbag `:293` |
| `0x83`–`0xA6` | 36 | unknown5 — "long mice only" | preserve | libratbag `:295-297` |
| `0xA7`… | | padding to 520 | zero | libratbag `:299` |

`0xA7` = 167 = `SINOWEALTH_CONFIG_SIZE_MAX`. libratbag's boundary comments (`:279-282`, `:295`) place
the short-mouse cut at `0x7B` (123 bytes, ending after the rave colours) and the
long-mouse extension at `0x83` (131). See §11.

### 5.1 RGB effect IDs — blob byte `0x35`

`enum sinowealth_rgb_effect`, `driver-sinowealth.c:170-194`, cross-checked
against OpenRGB's `GLORIOUS_MODE_*`, `SinowealthController.h:23-35`.

| ID | libratbag name | OpenRGB name | Parameter bytes | In Glorious's own software |
|---|---|---|---|---|
| `0x00` | `RGB_OFF` | `OFF` | none | yes |
| `0x01` | `RGB_GLORIOUS` | `RAINBOW` | mode `0x36`, direction `0x37` | yes ("unicorn") |
| `0x02` | `RGB_SINGLE` | `STATIC` | mode `0x38`, colour `0x39`–`0x3B` | yes |
| `0x03` | `RGB_BREATHING7` | `SPECTRUM_BREATHING` | mode `0x3C`, count `0x3D`, 7 colours `0x3E`–`0x52` | yes |
| `0x04` | `RGB_TAIL` | `TAIL` | mode `0x53` | yes |
| `0x05` | `RGB_BREATHING` | `SPECTRUM_CYCLE` | mode `0x54` | yes |
| `0x06` | `RGB_CONSTANT` | — | mode `0x55`, 6 colours `0x56`–`0x67` | **no** — per-LED static |
| `0x07` | `RGB_RAVE` | `RAVE` | mode `0x74`, 2 colours `0x75`–`0x7A` | yes |
| `0x08` | `RGB_RANDOM` | `EPILEPSY` | mode `0x7B` | **no** |
| `0x09` | `RGB_WAVE` | `WAVE` | mode `0x7C` | yes |
| `0x0A` | `RGB_BREATHING1` | `BREATHING` | mode `0x7D`, colour `0x7E`–`0x80` | yes |
| `0xFF` | `RGB_NOT_SUPPORTED` | — | — | **the value on mice with no LEDs. Non-constant. Never write it.** (`:188-192`) |

Effect `0x06` (`RGB_CONSTANT`) is the interesting one for a lighting app: it is
the only mode that addresses the **six** LEDs individually, and Glorious's
software does not expose it. OpenRGB does not implement it either — it maps its
"Custom" per-LED mode onto effect `0x02` instead
(`RGBController_Sinowealth.cpp:37-43`), which only has one colour. The
`0x56`–`0x67` array is 6 × 3 bytes, so the LED count is 6.

### 5.2 Colour byte order is **R, B, G** — not RGB

libratbag's device file for this mouse says `LedType=RBG`
(`data/devices/glorious-model-o.device`), and the driver decodes accordingly:
`red = data[0]; green = data[2]; blue = data[1]`
(`driver-sinowealth.c:746-772`, with RBG as the explicit fall-back for unknown
devices, `:753-758`). OpenRGB writes the same order without comment —
`usb_buf[0x39] = R; usb_buf[0x3A] = B; usb_buf[0x3B] = G`
(`SinowealthController.cpp:114-116`).

Two independent sources, no disagreement. **Confidence: high.** Get this wrong
and red/blue look right while green and blue swap.

### 5.3 Speed / brightness nibbles

Every `*_mode` byte in §5 is one packed byte: **speed in the low nibble,
brightness in the high nibble** (`struct sinowealth_rgb_mode`,
`driver-sinowealth.c:197-209`; bitfields declared speed-first, so on a
little-endian target speed takes the low bits). OpenRGB composes it explicitly as
`((brightness & 0xF) << 4) | (speed & 0xF)` (`SinowealthController.cpp:109`) —
exact agreement.

| Nibble | Values | Meaning |
|---|---|---|
| speed (low) | `0` | static — no animation (`driver-sinowealth.c:819`) |
| | `1` | slow — ~1500 ms period |
| | `2` | normal — ~1000 ms |
| | `3` | fast — ~500 ms |
| brightness (high) | `0` | off |
| | `1`–`4` | low → high; OpenRGB exposes `1`/`2`/`4` as low/normal/high (`SinowealthController.h:44-49`) |

libratbag maps brightness to its 0–255 API as `min(raw * 64, 255)` and back as
`(b + 1) / 64` (`driver-sinowealth.c:799-812`), which is where the "0–4" range
comes from.

---

## 6. DPI stages — blob `0x0B`–`0x1C`

**The encoding is sensor-dependent and this is the easiest thing in the whole
protocol to get wrong by 100 DPI.**

From `sinowealth_raw_to_dpi` / `sinowealth_dpi_to_raw`
(`driver-sinowealth.c:709-744`) and the struct comment at `:218-225`:

```
PMW3360 (0x06 — this mouse) and PMW3327:   raw = DPI/100 - 1     DPI = (raw+1)*100
PMW3389:                                   raw = DPI/100         DPI = raw*100
```

So on the Model O, **`raw = 0x0B` means 1200 DPI**, not 1100. Maximum for the
PMW3360 is 12000 (`:693-702`); step is 100; libratbag's floor is 100 even though
Glorious's software stops at 400 (`:73-77`).

* **8 slots exist** in the blob, though Glorious's software shows 6 and G-Wolves'
  shows 7 (`:96-101`).
* If the XY-independent flag (bit 3 of the high nibble of `0x0A`) is set, the 16
  bytes are 8 × `{x, y}` pairs instead of 8 × single values
  (`:227-235`, `:1266-1273`). Read the flag before interpreting the array.
* `0x0C` disables slots, **bit set = disabled** (`:256-257`). libratbag writes it
  as `~enabled_mask` (`:2108`).
* `0x0B`'s high nibble, `active_dpi`, is **1-based and counts only enabled
  slots** — libratbag computes `resolution->is_active = (enabled_dpi_count == active_dpi - 1)`
  while walking slots in order and skipping disabled ones (`:1276-1288`). If you
  disable slot 2 of 6, the fifth enabled slot has `active_dpi == 5`, not 6.

---

## 7. Polling rate, debounce, lift-off distance

### Polling rate — blob `0x0A` low nibble
`1`=125 Hz, `2`=250, `3`=500, `4`=1000 (`sinowealth_report_rate_map`,
`driver-sinowealth.c:663-668`). Written as part of the ordinary blob write; there
is no dedicated command. **Confidence: high** — but note `0` is the error
sentinel in libratbag's converters, not a valid rate.

### Debounce — command `0x1a`, *not* in the blob
```
read    SetFeature(5)  05 1a 00 00 00 00 ;  GetFeature(5) -> ms = reply[2] * 2
write   SetFeature(5)  05 1a <ms/2> 00 00 00
```
(`driver-sinowealth.c:1057-1103`.) Valid values are the even milliseconds
4, 6, 8, 10, 12, 14, 16 (`SINOWEALTH_DEBOUNCE_TIMES`, `:130-132`); libratbag
rejects anything outside 4–16 (`:83-86`, `:1080-1085`) while noting the hardware
accepts 2 ms and Glorious's v1.0.9 software simply refuses to offer it.

⚠️ The enum comment warns command `0x1a` *"Doesn't work on devices with shorter
configuration data (123 instead of 137)"* (`:43`). Whether the Model O counts
as short is unresolved — see §11. Treat a debounce read that returns a
non-echoing `reply[1]` as "unsupported", not as a value.

### Lift-off distance — blob byte `0x81`
`0x01` = 2 mm, `0x02` = 3 mm (`driver-sinowealth.c:286-291`).

⚠️ **`0xFF` at `0x81` means "this device sets LOD through command `0x1b`
instead"; the comment says explicitly `do **not** overwrite it`.** And command
`0x1b` is documented as *"Only works on devices that use CONFIG_LONG report ID"*
(`:45`) with the function comment *"This does not work on Glorious Model O"*
(`:1108-1110`). The Model O uses report 4, not report 6 — **[measured]**, no
report `0x06` exists on the config interface — so the blob byte is the correct
path here, and command `0x1b` should not be sent.

libratbag never writes byte `0x81` at all (no assignment to
`lift_off_distance` exists in the file); it is read-only there. Writing it is
therefore **unverified by any source**. See §10 for a specific way OpenRGB gets
this wrong.

---

## 8. Profiles

Up to **3** profiles (`SINOWEALTH_NUM_PROFILES_MAX 3`, `driver-sinowealth.c:122`).
Glorious's software calls them "modes" and hides all but the first unless
`Cfg.ini`'s `MDNUM` is edited (`:102-120`).

* Each profile is a **complete separate blob**, selected by the command byte:
  `0x11`/`0x21`/`0x31` for read *and* for the `buf[1]` of the write.
* **Active profile is a device-level setting, not a blob field**: command `0x02`,
  **1-based** in `reply[2]` / `buf[2]`
  (`sinowealth_get_active_profile` `:991-1007`, `sinowealth_set_active_profile`
  `:1013-1032`).
* libratbag's commit writes **all** profiles every time (`:1944-1963`).

This is a genuinely different design from the GMMK keyboard's profile-relative
address arithmetic in `protocol-tkl-notes.md` §8.1. Do not carry that model over.

---

## 9. ☠️ ISP / bootloader hazard — read before sending anything on report 5

**This is more dangerous than the keyboard's equivalent, because the ISP
bootloader shares the very report ID the configuration protocol uses.** On the
GMMK keyboard the ISP door is a *different* interface you can simply never
touch. Here it is `05 <cmd>` on the same 6-byte feature report as
`FIRMWARE_VERSION` — one wrong command byte away.

Reference: [`carlossless/sinowisp`](https://github.com/carlossless/sinowisp)
(the successor to `sinowealth-kb-tool`), read directly. Its own README says:
*"I offer no guarantees that using this tool won't brick your device. Use this
tool at your risk."*

`sinowisp` lists this exact device: `DEVICE_GLORIOUS_MODEL_O`,
`vendor_id: 0x258a, product_id: 0x0036`, platform `SH68F90`,
`isp_iface_num: 1`, **`isp_report_id: 5`** (`src/device_spec.rs:109-113`,
defaults at `:5-7`). Its device table marks Model O flash-read as tested-working
with MCU SH68F89 / `BY8948`.

### Never send

| Bytes on FEATURE report 5 | Source | Why |
|---|---|---|
| `05 75 00 00 00 00` | `src/device_selector.rs:19-20,421-425`; libratbag `driver-sinowealth.c:56-59` | **Enter ISP mode.** Two fully independent sources name `0x75`. The device drops off the bus and re-enumerates as the bootloader. libratbag's own comment: *"Puts the device into DFU mode. To reset re-plug the mouse or do a clean reboot."* It is compiled in and **never called** |
| `05 45 …` | `src/isp_device.rs:17,247-249` | `CMD_ERASE` — erases flash |
| `05 57 …` | `src/isp_device.rs:16,140-155` | `CMD_INIT_WRITE` — arms a flash write at an address |
| `05 52 …` | `src/isp_device.rs:15,123-138` | `CMD_INIT_READ` — arms a flash read |
| `05 55 …` | `src/isp_device.rs:14,116-121` | `CMD_ENABLE_FIRMWARE` — writes an `LJMP` opcode into flash at `firmware_size-5` |
| `05 5A …` | `src/isp_device.rs:18,261-263` | `CMD_REBOOT` |
| anything on FEATURE report **`0x06`** | `src/isp_device.rs:12,20-21,157-198` | `REPORT_ID_XFER` — the bootloader's 2048-byte page read/write channel (`0x72` read page, `0x77` write page). Report 6 does not exist on this device in normal operation **[measured]**; if you ever see it, you are talking to the bootloader |

### Do not fuzz report 5

The safe verbs are the eleven in §2.1 and nothing else. The command byte is a
single byte with no length or checksum protection, the destructive verbs sit at
`0x45`/`0x52`/`0x55`/`0x57`/`0x5A`/`0x75` amid them, and a sweep of the command
space **will** hit `0x75` at minimum. There is no reason to sweep: §2.1 is
complete as far as two independent tools are concerned.

Also do not send commands `0x12`/`0x22`/`0x32` (button maps) or `0x30`
(macros) — out of scope for a lighting app, and a bad blob write there costs the
user their button configuration.

### If it does end up in the bootloader

The ISP bootloader enumerates as **`0603:1020`** ("Gaming KB"),
`src/device_selector.rs:24-25` and the udev rule in `sinowisp`'s README. That is
a recoverable state, not a brick: unplug and replug. It becomes a brick only if
something then erases or writes flash. Flash layout, if it ever matters:
SH68F90-class part, 64 KiB total, 4 KiB bootloader at the top, 61440 bytes of
firmware, 2048-byte pages (`src/platform_spec.rs:3-4,19-22`).

Note also `sinowisp`'s warning that on macOS several of these devices are *"not
recognized as an HID device"* when composite — one more reason not to be
experimenting with this channel from this project.

---

## 10. ⚠️ Two bugs in OpenRGB's implementation — do not copy them

Both are in `SinowealthController::SetMode`, and both are visible by reading
`SinowealthController.cpp:163-173` against the layout in §5.

**1. Effect "off" writes zero into the lift-off-distance byte.**
```c
case GLORIOUS_MODE_OFF:
    usb_buf[0x81] = 0x00; //mode 0 either 0x00 or 0x03
    break;
```
Blob `0x81` is `lift_off_distance` (§7), not a mode parameter. `0x00` is not one
of its two documented values, and if the device had `0xFF` there — the "managed
by command `0x1b`" sentinel libratbag says must never be overwritten — this
destroys it. To turn the LEDs off, write effect `0x00` to byte `0x35` and leave
`0x81` alone.

**2. `GLORIOUS_MODE_BREATHING` falls through into `GLORIOUS_MODE_OFF`.**
The `case GLORIOUS_MODE_BREATHING:` arm ends at
`usb_buf[0x80] = …G` (`SinowealthController.cpp:167`) with **no `break`**, so
selecting breathing also executes bug 1. The `break` only appears after the OFF
arm.

A third, milder item: OpenRGB's comment on `usb_buf[0x3D] = 0x07` reads
`//maybe some kind of bank change?+` (`:121`). It is not a bank change — byte
`0x3D` is `breathing7_colorcount` (`driver-sinowealth.c:269`), and `0x07` is
simply "all seven colours are in use". Setting it to `0x06` — the commented-out
alternative on the next line — would silently drop the last colour.

---

## 11. Uncertainties

Ranked by how much they would cost to get wrong.

1. **Is the Model O's config blob 131 bytes or 167?** This determines
   `buf[3]`, the write marker, and therefore whether a write is accepted at all.
   The sources disagree in effect: libratbag computes `size − 8` from whatever
   `GetFeature` actually returned (`driver-sinowealth.c:1953`), while OpenRGB
   hardcodes `0x7B` = 123 = 131 − 8 for this device
   (`SinowealthController.cpp:101`). libratbag's own boundary comments
   (`:279-282`, `:295`) place a cut after the rave colours at 123 and another
   at 131. OpenRGB's `SINOWEALTH_CONFIG_SIZE_MIN 131` and its refusal to write
   below that (`:96`) are indirect evidence the Model O returns exactly 131 —
   which would mean the LOD byte at `0x81` is the **last** field and the 36-byte
   `unknown5` block does not exist here. **Resolve by reading the blob and
   observing the returned length before writing anything.**
2. **On macOS, can the returned length even be observed?** `IOHIDDeviceGetReport`
   fills a caller-sized buffer; hidraw's "actual bytes transferred" may not
   survive the IOKit path, in which case you cannot derive the size the way
   libratbag does and must either trust OpenRGB's `0x7B` or infer the size from
   where the trailing zeros start. Untested.
3. **Writing byte `0x81` (LOD) is unverified by any source.** libratbag reads it
   and never writes it; OpenRGB only writes it by accident (§10). If a
   lift-off-distance feature is ever wanted, treat the first write as an
   experiment and read the value back.
4. **Does command `0x1a` (debounce) work on this mouse?** Gated on the
   short/long config question in (1) by libratbag's own comment. Cheap to test:
   the read form is non-destructive and self-validating via the `reply[1]` echo.
5. **Effect `0x06` (`RGB_CONSTANT`) is undocumented in practice.** The layout
   implies six independently addressable LEDs at `0x56`–`0x67`, but *no*
   published tool exercises it — libratbag only decodes it as a generic "cycle"
   (`:1319-1326`) and OpenRGB does not implement it. Whether all six LEDs are
   physically present on both the O and the O-, and what their spatial order is,
   is unknown. This is the highest-value experiment available and the one most
   worth doing carefully.
6. **`unknown2` (`0x04`–`0x08`), `unknown3` (`0x68`–`0x73`), `unknown4`
   (`0x82`)** have no documented meaning in either source. Preserve them
   verbatim on write. OpenRGB's zeroing of `0x06` (`:102`) is unexplained.
7. **INPUT report `0x07`, 7 bytes** — **[measured]**, and neither source mentions
   it. Neither libratbag nor OpenRGB ever reads an input report from this device;
   the whole protocol is `GetFeature`-driven. Most likely an ordinary
   consumer/vendor input pipe, possibly the DPI-button notification. Unidentified;
   do not build anything on it.
8. **The `0x0A` high nibble.** libratbag names the whole nibble `config_flags`
   but only knows one bit: `SINOWEALTH_XY_INDEPENDENT = 0b1000`
   (`driver-sinowealth.c:139-146`), with the honest comment *"This naming may be
   incorrect as it's not actually known what the other bits do."* Preserve them.
9. **Angle snapping** is not reachable on this device. libratbag exposes it only
   through command `0x1b` (`:1108-1150`), which does not work here (§7). Whether
   the Model O has an angle-snapping setting at all, and where, is unknown.
10. **The `V103` firmware string is the only version libratbag knows.** Its
    device file has exactly one section (`[Driver/sinowealth/devices/V103]`,
    named *"updated firmware"*), and a device whose firmware string does not
    match any section is **rejected** rather than handled generically
    (`sinowealth_find_device_data` → `-EINVAL`, `:1681-1702`, `:1734-1741`). Older-firmware
    Model Os exist and this document may not describe them. Read command `0x01`
    first and record what the unit actually reports.

---

## 12. Safe bring-up order

Nothing here writes anything. Ordered so each step validates the next.

1. **Enumerate and identify the collection.** Match `258A:0036`, then probe each
   of the three collections the way OpenRGB does: `SetFeature(5, 05 11 00 00 00 00)`
   followed by `GetFeature(4, 520)`. Keep the one that answers.
2. **Read the firmware version.** `05 01 00 00 00 00`, then `GetFeature(5, 6)`.
   Check `reply[1] == 0x01`; bytes 2‥5 are ASCII. This is the cheapest possible
   proof that the command channel works, and it settles uncertainty 10.
3. **Read the active profile.** `05 02 00 00 00 00`. `reply[2] − 1` is the
   0-based index. Confirms the echo-check convention on a second command.
4. **Read the blob and record its length and its tail.** Command `0x11`, then
   `GetFeature(4, 520)`. Dump it. Where do the trailing zeros begin — 131 or 167?
   That answers uncertainties 1 and 2 and gates every write.
5. **Decode without writing.** Check `0x09 == 0x06` (PMW3360), decode the polling
   rate from `0x0A`, the DPI stages from `0x0D` with the `−1` scaling, and the
   effect from `0x35`. Compare against what the mouse is visibly doing. If the
   decoded effect and colour match the LEDs, the whole layout is confirmed on
   real hardware.
6. **Only then: the smallest possible write.** Read the blob, change **one**
   byte — brightness in the high nibble of the mode byte belonging to the
   currently active effect — set `buf[1] = 0x11` and `buf[3] = <observed size> − 8`,
   and `SetFeature(4, 520)`. Read back and compare. Preserve every `unknown*`
   byte exactly.
7. Never send anything from §9. Never sweep report 5.

---

## 13. Verified on hardware (2026-08-06, fw V103): the per-LED constant mode works

§11 item 5 is resolved. Writing effect `0x06` with six distinct colours at
`0x56`–`0x67` (RBG order, same as every other colour field) produces six
individually-coloured LEDs — the first known working use of this mode in any
software, Glorious's included.

Physical mapping, established by writing R,G,B,Y,M,C in index order and
observing: **each side strip carries all six LEDs in index order,
front (cable end) to back; both strips are driven identically (mirrored); the
scroll wheel follows LED index 1.** Perceived intermediate hues between
adjacent LEDs are diffuser blending, not extra channels.

---

## 14. Static analysis of Glorious's own Model O software v1.0.9 — is there a RAM / live-preview path?

**Verdict: no. There is no non-persistent lighting path on this device, and
Glorious's own editor does not have one.** Every lighting change the official
software can make goes through exactly one code path: the same report-4,
520-byte, `buf[3] = 0x7B` blob write this document already describes in §4.

This section is **static analysis only — no hardware I/O was performed.**
Everything is read out of the shipped binaries at the addresses cited.

### 14.1 Provenance

Glorious's legacy-software index (<https://www.gloriousgaming.com/pages/legacy-software>)
links **one** package for the wired Model O / O-, and its version number matches
the "v1.0.9 software" libratbag refers to at `driver-sinowealth.c:83-86`:

| | |
|---|---|
| URL | `https://downloads.gloriousgamingservices.com/download/ModelO_1-0-9.zip` |
| SHA-256 | `06bededddf80d98ac55ce8843723ef796a0dda05a3193ca765b7801067c96296` |

Unlike the GMMK keyboard editors (InstallShield, `protocol-tkl-notes.md` §1.1),
this one is **Inno Setup 5.3.3**; `innoextract` unpacks it directly.

| Member | SHA-256 |
|---|---|
| `02 SOFTWARE/Glorious_Software_Setup_V1.0.9.exe` | `53f7653c5a770ca56b437bc152ac8f3be570ea3654913b69787b69550a3cf25a` |
| `01 FIRMWARE UPDATE/Glorious Model O and O minus FM 1-0-9 UPDATE.exe` | `fd8c4ef8c50c9662abb4bc39fd09965e0fc9dd42426716bd1943358ba33d3518` |
| `01 FIRMWARE UPDATE/UpdateCodeTool.mtp` | `76f4635a3153728785c47062b0e75c898b14e4a0503318ff7c6a82560a9259b7` |

The installer yields `OemDrv.exe` (2 450 944 bytes, PE32 x86 MSVC/MFC, PE
timestamp 2019-08-14) — the application — plus `Lowerdev.dll` (57 856 bytes,
2016-03-25) and `Cfg.ini`. All addresses below are `OemDrv.exe` VAs
(image base `0x400000`), recovered with Capstone; `Lowerdev.dll` VAs use its own
base `0x10000000`.

The bundled **firmware updater is a separate executable** and is the only thing
in the package that touches the ISP bootloader (§14.7).

### 14.2 `Cfg.ini` — the vendor's own device description

The app is a reskinned generic **"BY-COMBO2"** framework (`appdir=BY-COMBO2`)
driven by an ini file, and that file independently confirms five things this
document previously had only from community sources:

| `Cfg.ini` line | Confirms |
|---|---|
| `[MS] VID=0x258A  PID=0x0036` | §1 device identity |
| `Sensor = 0x3360` | §1 PMW3360 |
| **`RGBIndex=0,2,1`** | **§5.2 colour order is R,B,G** — a third independent source, and the vendor's own |
| **`PSD=0x56,0x31,0x30,0x33`** | `"V103"`. The firmware-version gate; §11 item 10 |
| `MDNUM=3` | §8, three profiles |
| `DM=6` | §6, six DPI stages exposed (of eight in the blob) |
| **`DPI=400,…,12000` against `DPIHW=3,…,119`** | **§6 DPI encoding.** 400 DPI ↔ raw 3, i.e. `DPI = (raw+1) × 100`. The vendor's own table, exactly libratbag's PMW3360 formula |
| `DEFLEVEL=2` | default brightness 2 (§5.3) |

`LedOpt1`…`LedOpt9` list the effects the UI offers, first field = effect ID:
**1, 5, 3, 2, 10, 4, 7, 9, 0**. Against §5.1 that is rainbow, full-RGB
breathing, breathing-7, single, breathing-1, tail, rave, wave, off — and
**effect `0x06` (`RGB_CONSTANT`) and effect `0x08` (random) are absent.** This
is direct confirmation of the "In Glorious's own software" column in §5.1, and
of §13: the per-LED mode really is unused by the vendor.

`ApplyNow=1` is the key behavioural flag; see §14.6.

### 14.3 Transport — feature reports only, and one HID object

`Lowerdev.dll` is a thin HID wrapper exporting `FindHidDevice`,
`OpenHidDevice`, `SetFeature`, `GetFeature`, `GetInputReport`,
`SetOutputReport`, `GetProductString`, `GetProductID`. It imports
`HidD_SetFeature`, `HidD_GetFeature`, `HidD_GetInputReport`,
`HidD_SetOutputReport` from `HID.DLL`.

`OemDrv.exe` binds only some of them, by `GetProcAddress` at **`0x40FC36`–`0x40FC7C`**,
into one object:

| Object slot | Function |
|---|---|
| `+0x08` | `OpenHidDevice` |
| `+0x0C` | **`SetFeature`** |
| `+0x10` | **`GetFeature`** |
| `+0x14` | `GetInputReport` |
| `+0x18` | `GetProductString` |

**`SetOutputReport` and `FindHidDevice` are never resolved at all.** The string
`"SetOutputReport"` does not occur in `OemDrv.exe`. So the official software has
no output-report path whatsoever — confirming §1.2 from the vendor side.
(Contrast the GMMK keyboard, where the official tool uses *only* interrupt OUT;
`protocol-tkl-notes.md` §2.2. The two devices are opposites.)

### 14.4 The four protocol primitives — the entire Model O surface

Four functions, and nothing else, talk to this mouse:

| Address | Role | Byte-exact behaviour |
|---|---|---|
| **`0x413A40`** | command write | `buf[0]=0x05`, `buf[1..4]` = caller's 4 bytes, `buf[5]` = caller's 5th; `SetFeature(handle, buf, 6)` |
| **`0x413B10`** | command read | `buf[0]=0x05`; `GetFeature(handle, buf, 6)`; returns 5 payload bytes |
| **`0x413BF0`** | config write | `memset(buf+1, 0, 0x207)`; `buf[0]=0x04`; copies **518 bytes** (`rep movsd` ×0x81 + `movsw`) from the caller's struct into `buf+1`; `SetFeature(handle, buf, 0x208)` |
| **`0x413CB0`** | config read | `memset`; `buf[0]=0x04`; `GetFeature(handle, buf, 0x208)`; copies 500 bytes out on success |

All four retry **up to 3 attempts with `Sleep(200 ms)` between failures**, and
**none of them computes a checksum** — confirming §1.2's "no checksum anywhere".

There is no fifth primitive. The addresses `0x4106C0`–`0x410C40` in the same
binary implement report-5/9-byte, report-6/1032-byte and report-9 protocols, but
those belong to other BY-COMBO products (the 1032-byte report 6 is the
Sinowealth *keyboard* protocol); no Model O code path reaches them.

> **`GetInputReport` is resolved and then never called.** Zero call sites in the
> entire binary. See §14.8 for what this means for INPUT report `0x07`.

### 14.5 Complete report-5 verb inventory — no new verbs, no ISP verbs

Every call site of the command-write primitive `0x413A40`, with the command byte
each one stores:

| Call site | Verb | Purpose |
|---|---|---|
| `0x413231` | `0x01` | firmware version. Reply bytes are compared **byte-for-byte against the `PSD` value** (globals `0x61E1A0`–`0x61E1A3` = `"V103"`); a mismatch aborts |
| `0x4132FF` | `0x11` | arm config read, profile 1 |
| `0x4133B4` | `0x02` | read active profile; reply validated to be 1, 2 or 3, else forced to `0xFF` |
| `0x413410` | `0x1A` | read debounce |
| `0x4136D9` | `0x21` | arm config read, profile 2 |
| `0x413806` | `0x31` | arm config read, profile 3 |
| `0x413DB2` | `0x02` | write active profile |
| `0x413E2C` | `0x02` | write active profile (`index + 1`) |
| `0x413E9F` | `0x11`/`0x21`/`0x31` | arm config read, profile selected by a 3-way switch |
| `0x417903` | `0x1A` | write debounce |

**That is the whole list: `0x01`, `0x02`, `0x11`, `0x1A`, `0x21`, `0x31`.** Plus
`0x12`/`0x22`/`0x32` and `0x30` used as report-4 *write* selectors (§14.6).

Consequences:

* **No undocumented verb exists.** §2.1 is complete; the official software emits
  a strict subset of it. Nothing was found to add to the safe list, and nothing
  new to fear.
* **No ISP verb is ever sent by the editor.** `0x75`, `0x45`, `0x52`, `0x55`,
  `0x57`, `0x5A` do not appear as command bytes anywhere in `OemDrv.exe`. §9's
  hazard list stands unchanged, and the door is not one the editor ever opens.
* **§11 item 4 is resolved: command `0x1A` (debounce) *does* apply to this
  mouse.** Glorious's own software both reads and writes it, and the README
  shipped in the same zip documents the Debounce Time control as a supported
  feature with a 10 ms default. libratbag's "doesn't work on devices with
  shorter configuration data" caveat does not bite here.

### 14.6 The write path — one form, one marker, no preview

The config-write primitive `0x413BF0` has **exactly four callers**, and only one
of them writes lighting:

| Caller | `buf[1]` | `buf[3]` | Payload |
|---|---|---|---|
| **`0x413F10` — write config** | `0x11`/`0x21`/`0x31` by profile | **`0x7B`** | `0x8C` = 140 bytes at `buf[8]` |
| `0x413FC0` — write button map | `0x12`/`0x22`/`0x32` | `0x50` | 0x50 bytes |
| `0x414060` — write macro | `0x30` (`buf[2]=0x02`) | — | — |
| `0x417FA0` — inline keymap write | `0x32` | `0x25` | — |

`0x413F10` is the only lighting write, and it is reached from **exactly one call
site**, `0x418041`.

**`buf[3] = 0x7B` is stored unconditionally at `0x413F70`** — there is no branch,
no alternative marker, and no second form of the report-4 write. Specifically,
there is **no "preview, don't save" variant**: not a different command byte at
offset 1, not a different marker at offset 3, not a different report ID.

This resolves **§11 item 1, the document's biggest open question, in OpenRGB's
favour.** OpenRGB's hardcoded `usb_buf[0x03] = 0x7B`
(`SinowealthController.cpp:101`) is exactly what the vendor writes. `0x7B` = 123
= 131 − 8, so the Model O's config blob is **131 bytes**, not 167.
**Confidence: high** — this is the vendor's own software agreeing with OpenRGB
against a value libratbag would have computed dynamically.

#### The vendor does not preserve the "unknown" bytes

`0x413F10` builds the blob **from scratch**, not read-modify-write:

```
memset(struct + 1, 0, 0x205)     ; zero everything
struct[0] = 0x11 / 0x21 / 0x31   ; -> blob[1], profile selector
struct[2] = 0x7B                 ; -> blob[3], write marker
memcpy(struct + 7, payload, 0x8C); -> blob[0x08] .. blob[0x93]
```

So Glorious's own software writes **zero** into `blob[2]` (`unknown1`) and
`blob[4]`–`blob[7]` (most of `unknown2`), and **zero from `blob[0x94]` to the end
of the report.** It never reads the blob back first for the purpose of
preserving those fields.

Two consequences for §4 and §11 item 6:

* OpenRGB's unexplained `usb_buf[0x06] = 0x00` (§4) is not a quirk — it is
  precisely what the vendor does.
* Our "preserve every `unknown*` byte verbatim" advice is **more conservative
  than the vendor's own software**, which is fine to keep, but the bytes are
  demonstrably don't-care. Note `blob[0x94]` onward being zeroed is further
  evidence the blob really ends around 131–148 bytes, not 167.

#### Write cadence: the official UI commits on *every* control change

`Cfg.ini`'s `ApplyNow=1` lands in global **`0x637450`**, read back at
`0x477A6D`. Roughly thirty UI handlers throughout the binary end with the same
three instructions:

```
cmp dword ptr [0x637450], 0      ; if (ApplyNow)
je  skip
mov dword ptr [0x63CF7C], <bits> ;   g_flags = which subsystem changed
call ReleaseSemaphore(g_sem,1,0) ;   wake the apply thread
```

Three identical worker contexts are created at `0x401060`, `0x401120` and
`0x4011D0` (`CreateSemaphore(initial 0, max 100)`), each running the thread
procedure at **`0x401250`**: `WaitForMultipleObjects` → read the flags word →
mark busy → dispatch. Its logging strings are `"ApplyThread Start"`,
`"Start Apply: hDevice=0x%x, nFlag=0x%x"` and `"Apply Over"`. The dispatch
reaches the commit routine at **`0x417730`**, which loops over profiles writing
button map, macros and then config for each.

There is **no debounce timer, no mouse-up gating, and no dirty-diff.** Moving a
colour picker in Glorious's software enqueues a full commit of all three
profiles. The only thing limiting the rate is that the apply thread is
single-threaded.

The UI has no "preview" concept: the only relevant string in the whole binary is
`tc_apply` → `"Apply"`. (`AFX_WM_POSTSETPREVIEWFRAME` and `PreviewPages` are
stock MFC print-preview and are unrelated.)

### 14.7 ☠️ The firmware updater independently confirms §9's hazard list

The separate `Glorious Model O and O minus FM 1-0-9 UPDATE.exe` imports
`HidD_SetFeature`/`HidD_GetFeature` and contains, as byte immediates stored into
command buffers, exactly:

`0x45`, `0x52`, `0x57`, `0x72`, `0x75`, `0x77`

That is `CMD_ERASE`, `CMD_INIT_READ`, `CMD_INIT_WRITE`, `XFER_READ_PAGE`,
`ISP mode`, `XFER_WRITE_PAGE` — matching `sinowisp`'s `isp_device.rs` verb-for-verb.
**§9 is now confirmed by a third, fully independent source: Glorious's own
firmware updater.** These verbs live in the updater and *only* in the updater;
the editor never emits them.

> This also means the hazard is real and reachable. **Do not send anything on
> report 5 outside the six verbs in §14.5.**

### 14.8 INPUT report `0x07` — §11 item 7 partially resolved

The official editor **never reads it** (`GetInputReport` resolved, zero call
sites). But `enkore/gloriousctl` documents it, in `gloriousctl.c:220-227`:

```c
struct change_report {
    uint8_t report_id;      /* = 7 */
    uint8_t unk1;           /* always 1 */
    uint8_t active_dpi:4;
    uint8_t unk2:4;         /* 6 */
    uint8_t dpi_x;
    uint8_t dpi_y;
    uint8_t unk3[3];        /* always 0 */
};
```

It is a **device→host notification emitted when the user presses the DPI
button**, read at `gloriousctl.c:635`; `dpi_x`/`dpi_y` use the same
`(raw+1)×100` encoding as the blob. So the earlier guess in §11 was right. It
carries no lighting information and nothing should be built on it, but it is no
longer unidentified.

### 14.9 What the community sources say about a RAM path

Re-scanned against this specific question:

* **OpenRGB's wired Model O controller has no direct mode.**
  `RGBController_Sinowealth.cpp:14-22` declares `@direct :x:`, and all ten modes
  carry `MODE_FLAG_AUTOMATIC_SAVE`. The merge request that added brightness
  support says so in as many words: *"Updated modes to reflect nature of the
  device which does not support direct access"*
  (<https://gitlab.com/CalcProgrammer1/OpenRGB/-/merge_requests/3090>).
* **The wireless Model O controller has no direct mode either**
  (`RGBController_SinowealthGMOW.cpp:14-20`, `@direct :x:`).
* **A sibling Sinowealth device does.** The PID-`010C` keyboard
  (`SinowealthKeyboard10cController.cpp:63-84`) has a genuine volatile direct
  mode — `SetFeature` on **report ID 6**, 520 bytes, header
  `06 08 00 00 01 00 7A 01` then RGB triples from offset 8 — with a keepalive
  thread because *"The Sinowealth 010C Keyboard requires a steady stream of
  packets in order to not revert out of direct mode"*. That proves the vendor's
  8051 stack *can* implement a RAM LED buffer, in some products.
  **It does not transfer here, and chasing it on this device is dangerous:**
  report `0x06` does not exist on the Model O's config interface **[measured]**,
  and report 6 *is* the ISP bootloader's page-transfer channel (§9). Probing
  report 6 on this mouse is the single most likely way to brick it.
* Another Sinowealth contributor reached the same conclusion for a keyboard
  after examining the vendor software: *"All settings always saved into flash and
  it takes some time, so dynamically software effects not possible. I couldn't
  find any way to direct mode driving LEDs, there is not in OEM software which I
  explored."* (<https://gitlab.com/CalcProgrammer1/OpenRGB/-/merge_requests/665>)
* `sinowisp`'s ISP protocol addresses **code flash only** — `firmware_size`,
  `bootloader_size 4096`, `page_size 2048` (`src/platform_spec.rs`). There is no
  XRAM space, no data-flash region and no config region in it, so it neither
  confirms nor refutes a RAM shadow behind report 4. It simply has nothing to say.
* `gloriousctl`'s README carries the only wear-adjacent warning found anywhere:
  *"this appears to modify the EEPROM/flash of the controller in your mouse"*.
* **No flash-endurance figure for the SH68F89/SH68F90/BY8948 could be found in
  any public source.** No datasheet, no app note, no writeup. Any wear budget we
  assume is an engineering guess, not a sourced number.
* **No tool that streams colour to a wired Model O in real time appears to
  exist.** Not OpenRGB, not SignalRGB, not libratbag, not gloriousctl, not any
  script found. Nobody has reported flash wear because nobody appears to be
  doing this.

### 14.10 Verdict and recommended probe plan

**There is no RAM / live-preview path for the wired Model O.**

* That none is *documented or discoverable* — **confidence: high.** Four
  independent implementations (Glorious's own editor, OpenRGB, libratbag,
  gloriousctl) converge on one write path, and the vendor binary contains no
  second form of it and no unknown verb.
* That none *exists in the silicon* — **confidence: moderate.** The only
  countervailing evidence is the 010C keyboard's direct mode, which shows the
  family's firmware stack has the concept. But the Model O's firmware is older,
  its report-6 channel is the bootloader, and nothing in the vendor software
  hints at a hidden lighting verb.

**One thing remains genuinely unmeasured, and it is the one that matters:**
nobody — not gloriousctl, not OpenRGB, not this document — has actually
established that a report-4 write costs a flash erase/program cycle *every
time*. It is universally assumed. The firmware may well diff the incoming blob
against what is stored and skip the flash write when nothing changed, which is a
common pattern on these parts.

#### Recommended next probe — timing discrimination, hardware-safe

Uses **only** verbs and reports already in §14.5 and §4. No new report IDs, no
new verbs, no report 6, no sweep. It writes the config blob, which we already do
routinely.

1. Read the blob (§3) and keep it as a baseline.
2. **Time `SetFeature(report 4, 520)` writing the blob back completely
   unchanged**, 20 times, recording each duration.
3. **Time the same write with one lighting byte changed** (a brightness nibble),
   alternating between two values, 20 times.
4. Compare the two distributions.

Interpretation:

* If unchanged writes are consistently **much faster** than changed writes, the
  firmware diffs and skips the flash program. That would mean a visualizer only
  pays a flash cycle when the colour actually changes — still costly, but it
  makes "write only on change" a genuine mitigation rather than a hope.
* If both are the **same and slow** (order 10–50 ms, consistent with a page
  erase + program), assume every write is a flash cycle and treat the write
  budget as hard.
* If both are the **same and fast** (order 1–3 ms), the write is being buffered
  and the flash commit is deferred or conditional — the most hopeful outcome,
  and worth following up with a replug-persistence test after a *single* write.

This costs at most 40 blob writes, which is negligible against any plausible
endurance figure, and it is the cheapest way to convert the project's central
assumption into a measurement.

#### Design recommendation for the visualizer, pending that measurement

Until the timing probe says otherwise, **assume every colour update burns a
flash cycle** and design accordingly:

* Diff before writing; never re-send an identical blob.
* Rate-limit hard (single-digit Hz at most, and only while audio is actually
  playing), and stop writing entirely on silence.
* Prefer the **hardware** effects (§5.1) where they suffice — they animate
  autonomously in firmware at zero ongoing flash cost after one write. A
  beat-synced visualizer cannot use them, but ambient modes can.
* Say plainly in the README that the audio-reactive mode writes the mouse's
  flash, so users can make their own call.

Note for context, not as reassurance: Glorious's own software commits on every
control change with no debouncing at all (§14.6), so the vendor evidently does
not treat these writes as precious. That is weak evidence the part tolerates
more than we fear — but it is not a measurement, and a UI slider is dragged a
few dozen times a session, not a few times a second for hours.
