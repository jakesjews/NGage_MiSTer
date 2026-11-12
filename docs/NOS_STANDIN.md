# NOS stand-in: the modem side at the ISI level

The N-Gage's cellular software (NOS) is encrypted in flash and its key is
in the UPP_WD2 silicon, so the core cannot run it. Symbian still expects a
modem: start-up servers and the telephony stack send ISI messages over
PhoNet and wait for answers. The stand-in answers them as a phone with
**an inactive SIM card inserted (ready, no PIN or security code, no SIM
lock), no network, modem state normal**.

Why not "no SIM card": Startup.app only finishes start-up when the SIM
status (System Agent `0x100052E9`) is 7 and the security-code state
(`0x100052F0`) is 0 (`0x50BBBCD6`, `0x50BBBDDC`). With no card (SIM state 5,
SA value 4) it removes the splash, shows a blank view behind the "Insert
SIM card" note and never goes further (tried: `model/.out/lcd-*` of
2026-10-20). This matches the S60 1.x behaviour of needing a SIM card, even
an expired one, to reach the idle screen.

The stand-in is ARMv4T code in the patched flash image, so the model and
the FPGA core run the same binary:

- `firmware-patches/nos-stub/nos_stub.S`: the NOS entry that nosstarter.ext calls
  (variant services, flags, power model, rtc event with the base date; see
  [Clock](#clock)).
- `firmware-patches/nos-stub/nos_dll.S`, `nos_dll.ld`: entry points of the hidden NOS
  DLL at its fixed ROM addresses (ordinal 4 `0x514A1CA0`, ordinal 6
  `0x514A261C`); state lives in NOS BSS at `0x8000D000`.
- `firmware-patches/nos-stub/nos_isi.c`: the channel object nosdriver.ldd talks to,
  queues and delivery.
- `firmware-patches/nos-stub/nos_isi_replies.h`: the replies listed below.
- `firmware-patches/nos-stub/nos_audio.h`: PCM playback through the HLE audio device
  (see [Audio](#audio)).
- `firmware-patches/rom-patches.txt` places both binaries (`cs0file`
  lines, the committed builds in `firmware-patches/bin`); the core's patch
  ROM (`tools/gen_patchrom.py`) and `tools/mkimage.py` are made from the
  same list.

Every reply is a guess about NOS, written from how the Symbian client
parses it. The evidence column names the client function that reads the
reply. Clients log their traffic: `NOS< ` is a request, `NOS> ` a reply,
in `model/.out/kern.log`.

## Interface

nosdriver.ldd (channel vtable `0x511695D8`) forwards each channel call to
an object built by NOS DLL ordinal 6. Vtable at object+4: `+0x0C`
cancel(mask), `+0x10` DoRequest(fn, a1, a2), `+0x14` DoControl(fn, a1, a2).
phonet.dll (RPhoNet) uses:

- control 4: send one message (`0x50366F04`; byte 2 = 0, byte 7 = the
  client's object id);
- request 0: receive one message (`0x50366F54`; a1 = the message TDes8,
  a2 = a `TBuf8<2>` that gets the length). The stand-in completes it with
  ekern `DLogicalChannel::Complete` (ordinal 64).

PhoNet frame (`phonet.dll 0x5036700E` sets the length):

| Byte | Field |
|---|---|
| 0 | media |
| 1 | receiver device |
| 2 | sender device |
| 3 | resource |
| 4-5 | length of what follows, little-endian |
| 6 | receiver object |
| 7 | sender object |
| 8 | transaction id |
| 9 | message id |
| 10.. | payload |

A reply swaps devices and objects and keeps the resource and transaction
id. Indications go from object 0 of the resource to the client.

## System Agent variables

DOS turns ISI state into DOS events (DosSrv ordinals), sae.exe turns
events into System Agent variables. The event → variable map comes from
DSClient.dll's switch (`0x50FF6B2C`, event n → observer slot) and sae.exe's
observer (vtable `0x50BF36AC`):

| DOS event | DosSrv ord | SA variable `0x1000xxxx` |
|---|---|---|
| 3 | - | `52C5` |
| 4 | 22 | `52D5` |
| 5 | 7 | `52D7`, `52C9` |
| 6 | 4 | `52D8`, `52CA` |
| 7 | 2 | `52D3` |
| 8 | 30 | `52E8` |
| 9 | 28 | `52EA` |
| 16 | 29 | `52F4` |
| 17 | 31 | `52E9` (SIM status; 7 = ready) |
| 18 | 6 | `52E0` |
| 19 | 33 | `52E3` |
| 20 | 20 | `52EC` |
| 21 | 12 | `52ED` |
| 22 | 23 | `52D4`, `52C7`, `52C8` (network bars from res `0x0A`) |
| 23 | 27 | `52F0` (security-code state; 0 = none) |
| 24 | - | `52D8`, `52CA`, `52D9` |
| 25 | - | `52F6` |

Event 1 is the self-test result, read by Startup.app directly.

## Clients

| Object | Client | Notes |
|---|---|---|
| `0x36` | phonetsy.tsy (ETel TSY in PhoneServer) | router `0x50951F08` |
| `0x4D` | Nokia.dsy (DosServer), self test | handler `0x50FFBAB4` |
| `0x4E` | Nokia.dsy, main | handler `0x50FFAC30`; by resource: 8 `0x50FFB720`, 9 `0x50FFB19C`, 0x0A `0x50FFB65C`, 0x17 `0x50FFAE20`, 0x1C `0x50FFACE4` |
| `0x4F` | Nokia.dsy | sends 0x3A/0x05 |

## Replies

| Resource | Request | Our reply | Effect | Evidence |
|---|---|---|---|---|
| `0x1C` | `0x10` (no payload), from DOS and the TSY | `0x11` [`00`] | DosSrv ord22(0) | Nokia.dsy `0x50FFAD98` reads [10]: 0 → 0; 1 → 2; 0x10/0x11/0x20/0x21 → 1 |
| `0x09` SIM | after the `0x1C` reply, unsolicited | `0xEF` SIM_IND [`0D 0B 08 00`]: SIM_ST_INFO, SIM_SERV_INIT_OK, state 8 | state 8 → DosSrv ord31(7) → DOS event 17 → SA `0x100052E9` = 7 (SIM ready); INFO/INIT_OK → DOS reads the SIM flags (`0x2D`, `0x2B`); state 8 → DOS compares the IMSI (`0x3B`) | Nokia.dsy `0x50FFB21C` reads [10] service, [11] status, [12] state 1..8; `0x50FFB2A0` (13/11 → `0x50FFB610`), `0x50FFB27A`. State 5 gives SA 4 and Startup.app stops (see above) |
| `0x08` security | after the `0x1C` reply, unsolicited | `0x10` [`05 00 00 00`] | DosSrv ord27(0) → DOS event 23 → SA `0x100052F0` = 0 (no code query) | Nokia.dsy `0x50FFB734` reads [10]: 5 → ord27(0), [13] 0x12/0x13 → ord9; 1/4 with [11] 1/6 → code required. phonetsy.tsy `0x5093D9FC` reads [10..] as one sub-block; id 5 is ignored (`0x5092C568`). 5 = SEC_STARTUP_OK in oFono |
| `0x09` SIM | `0x3B` [`FA`] (DOS) | `0x3C` [`FA 2A`] | DosSrv ord28(0) → event 9; no more `0x3B` | Nokia.dsy `0x50FFB388` reads [11]: 0x2A SIM_SERV_IMSI_EQUAL → 0, 0x2B → 1 |
| `0x09` SIM | `0x2D` [`3A`] (DOS) | `0x2E` [`3A 01 00 00`] | DosSrv ord6(0) → event 18 | Nokia.dsy `0x50FFB400`: [10] = 0x3A, [11] = 1 (SIM_SERV_OK), [12]: 0x0A/0x5A → 2, 0xA0/0xA5 → 3, 0xAA → 4, else 0 |
| `0x09` SIM | `0x2B` [`3A`] (DOS) | `0x2C` [`3A 01 01 00 00 00`] | DosSrv ord33(0), ord20(0), ord12(0) → events 19, 20, 21 = 0 | Nokia.dsy `0x50FFB4BC`: [10] = 0x3A, [11] = 1, [12] bit 0 = valid, [13..14] 16-bit flags. Writes with service 0x39 get the same reply shape, which DOS ignores |
| `0x35` | `0x02` [`01 00`], DOS self test | `0x03` [`00`] | DOS sends `0x35/0x00` | Nokia.dsy `0x50FFBB04` reads [10]: 0/10/11 → next step (`0x50FFBDC4`); 12 → DOS event 1 = 2, "Device start-up failed" (tried); others → ask again |
| `0x35` | `0x00` [`02 00`] | `0x01` [`00`] | DOS sends `0x59/0x01` | Nokia.dsy `0x50FFBBBC` reads [10]: 0 → next step (`0x50FFBD6C`); 1/2 → ask again; 12 → failure and MTC_STATE_REQ(SELFTEST_FAIL) |
| `0x59` | `0x01` [`08 00`] | `0x02` [`00`] | DOS event 1 = 3: self test passed; Startup.app state 1 → 2 → 4 | Nokia.dsy `0x50FFBC74` reads [10]: 0 → event 1 = 3 (`0x50FFBCBC`); others → ask again; Startup.app `0x50BBAF60` |
| `0x09` SIM | `0x60` [`FA 00`] (TSY) | `0x61` [`FA 31`] | completes RCtmGsmPhone::GetCipheringInfo (indicator not required); Phone.app calls it synchronously when the idle view activates, and the view server panics it (`ViewSrv 11`, then Starter and the kernel, `PLAT`) if it hangs | phonetsy.tsy `0x5093F4C0`, `0x50930EDC` read [11]: 0x30 SIM_SERV_CIPHERING_INDICATOR_DISPLAY_REQUIRED → 1, 0x31 → 0, others → KErrUnknown |
| `0x09` SIM | `0x21` [`2C`] (TSY) | `0x22` [`2C 24`] | SIM_SERV_PROV_NAME_REQ: no service provider name; GetServiceProviderDisplayInfo (Phone.app, synchronous) completes with KErrGeneral | phonetsy.tsy `0x5093ED20` reads [11]: 1 → parse, others → error from `0x5094E290` (0x24 → -2) |
| `0x09` SIM | `0x33` [`3E`] (TSY) | `0x34` [`3E 24`] | SIM read of the operator name for GetNetworkProviderName (Phone.app, synchronous); completes with an error | phonetsy.tsy `0x5093EDD0` reads [11]: 1 → parse by service [10]; service 0x13 with 0x24 → parse; others → `0x50930458` error |
| `0x09` SIM | `0x13` [`11`] (TSY) | `0x14` [`11 24`] | SIM service table for RAdvGsmPhone::GetSimServiceTable (Menu.app's MenuEng, synchronous) → -21, read as "no SIM toolkit" | phonetsy.tsy `0x5093FD60` reads [11]: 1 → parse, 0x24 → -21, others → no completion; MenuEng `0x50A13064` |
| `0x09` SIM | `0x31` [`3B 00 00`] (TSY) | `0x32` [`3B 24`] | ReadSimAlsLine (SysAp, Phone.app through sssettings, synchronous) → line 3, KErrNone; the CSP read (Menu.app) → -21 | phonetsy.tsy `0x5093F114` reads [11]: type 0x89 (ALS) 1 → parse, else `0x5092F3B0` (0x24 → line 3); type 0x4E (CSP) 1 → parse, else -21 |
| `0x17` battery | `0x08` [`01 00`] (DOS) | `0x09` [`01 01` + `13 04 01 00`] | charger state 1 → DosSrv ord7(0) → SA `0x100052C9` = ESAChargerDisconnected | Nokia.dsy `0x50FFAF00`: [10] = 1, [11] count, sub-block 0x13 at [12], state at its byte 2 (isimsg ord1524), 1..5 → ord7(state - 1); sae `0x50BF251C` |
| `0x17` battery | `0x0A` [`02 00`] (DOS) | `0x0B` [`01 02` + `15 04 01 00` + `16 04 00 07`] | battery fine (DosSrv ord4(0)), 7 bars (DosSrv ord2(7) → SA `0x100052D3`); the idle screen shows a full battery | Nokia.dsy `0x50FFB00C`: [10] = 1, sub-blocks 0x15 (state at byte 2: 1 → 0, 3 → 1, 4 → 2) and 0x16 (bars at byte 3); gnokii nk6510 reads the 0x0B level at the same byte, 0..7 |
| `0x1B` info | `0x02` INFO_PP_READ_REQ [`00 01` + `47 08 00 02 01 00 00 00`] (TSY) | `0x03` [`00 01` + `47 08 00 02 01 00 00 00`] | product profile feature value 0: completes RCtmGsmPhone::CheckAlsPpSupport (SysAp, synchronous) | phonetsy.tsy `0x5093EB38`: [10] status 0 = INFO_OK (oFono info.h), [11] sub-block count, INFO_SB_PP at [12], value at its byte 5 (isimsg ord1028) → `0x5092F248` |
| `0x1F` audio resource | `0x04` [`00 00 00`] (SoundDevice, object `0x4A`) | `0x06` [`0D 00`] | SoundDevice's teardown sends this release when `+0x1D8` is set and stays in state 14 until resource `0x1F` message 3, or 6 with [10] = 13, arrives; then state 0. Without it every later stream start is refused (PlayInit `0x505AC264`). It happens from the second boot on: a sound at start-up reserves (`0x1F/0x01`) and releases | receiver `0x505AF722` (ord524 reads [10] for message 6), state table `0x505AF7C4` |
| `0x0B` | `0x11` [`06 01`] (TSY) | `0x12` [`06 01 06 08 00 00 00 00 00 00`] | completes RCtmGsmPhone::GetHandsfreeMode (hands-free off), which PhoneServer waits on at start-up | phonetsy.tsy `0x5093E1D8`: [10] setting, [11] sub-block count = 1, sub-block at [12], 16-bit big-endian value at its bytes 4-5 (isimsg ord1568); `0x5092E16C` setting 6: 13 → on, else off. Sub-block id and length are guesses |

## Audio

Games use CMdaAudioOutputStream (MEDIACLIENTAUDIOSTREAM.DLL) → MediaServer
→ AUDIOSTREAM.MDA → SoundDevice.mda ("Galaxy" DevSound). SoundDevice copies
PCM into a shared chunk that audio.ldd maps at SDRAM physical `0x0A061000`
(60 KB: variant vtable `+0xF0` address, `+0xF4` size `0xF000`, ecust
`0x50343108`; audio.ldd control 0 returns it) and drives NOS over ISI from
two PhoNet objects. On the phone NOS has the DSP play the chunk; here the
stand-in (`nos_audio.h`) plays it with the HLE audio device, an emulator
invention (`docs/UPP_WD2.md`, "HLE audio device").

**Resource `0xE8`, object `0x48`** (receiver `0x505AF8F8`, switch on [9] at
`0x505AF914`; builders in isimsg.dll):

| Message | Direction | Bytes from [10] | Meaning, evidence |
|---|---|---|---|
| `0x20` | → NOS | `82`, path, half length (16-bit BE, samples), half A, half B (32-bit BE physical), `00`, rate code | Start (ord951 `0x5034F56C`, sent at `0x505AC65A`). Seen: `82 02 15E0 0A061000 0A063BC0 00 46`: two halves of 5600 samples (11200 bytes) at the start of the chunk. Path 3 instead of 2 when a call is active (SA event flag at `+0x28`, `0x505AFDB8`). Rate code 50 only for sources up to 8 kHz during a call, else 70 (`0x505AC5B8`-`0x505AC62C`); outside a call SoundDevice upsamples 8 kHz sources x2 with an 8-tap filter (`0x505AEFEC`) and sends 70. Read as 50 = 8 kHz, 70 = 16 kHz, mono 16-bit (the filter works on one channel) |
| `0x21` | → client | not read | Start accepted: in a playing state SoundDevice asks for data for half 0 (`0x505AFAE0` → `0x505ABBDC`) |
| `0x23` | → NOS | half, `1` last buffer / `2` more, samples (16-bit BE) | A half was filled (ord962 `0x5034F6B0`, sent at `0x505AE17A` after the copy at `0x505ADFD2`; the flag is the CMMFBuffer last-buffer bit, `0x505B001A`). Sent only in the playing states |
| `0x26` | → client | `00`, half | That half is free: SoundDevice fills it next ([11] → `+0x1F9`, `0x505AFB8E` → `0x505ABBDC`) and adds the last buffer's length to the position (`0x505ABBA8`). When two halves are free it sends `0x2A` (underflow, `0x505ABC44`) unless a grace count runs |
| `0x2A` | → NOS | none | Stop (ord952), on the client's stop (`0x505ADC94`) or underflow |
| `0x2B` | → client | bytes played (16-bit BE) | Stop done: added to the position, then teardown (`0x505AFBC2` → `0x505ADCB8`: `0x1F/0x04`, audio.ldd control 2, `0x0B/0x19`) |
| `0x22`, `0x25` | → client | | Treated as an error stop (-13, `0x505AFB08`); not sent |
| `0x24` | → client | | Leaves the playing states (`0x505AFB56`); not sent |
| `0x19`, `0x1C`, `0x1E`, `0x27` | → NOS | | Other builders (ord925, 924, 926, 960); replies `0x1A`, `0x1B`, `0x1D`, `0x1F` are handled; not seen in the three games |

**Resource `0x0B`, object `0x4A`** (receiver `0x505AF6B8`, which only takes
`0x0B` messages 1 and 2 and `0x1F` messages 3 and 6): `0x14` [`00` 4/5 `FF FF
FF` count, sub-blocks `03 08` param `00` value(16-bit BE) `FF FF`] sets a
parameter (ord691 with ord649 sub-blocks). Parameter 2 carries SoundDevice's
volume (`+0x164`, from the stream settings: Sonic 9, Rayman 6, Sega Rally 1),
sent before every buffer (`0x505AE286`); the constructor puts 9 next to it
(`+0x38`, `0x505AB6B0`), read as the maximum. `0x19` [`00 04 02`] and similar
route audio (ord850, at teardown). `0x00` [`01`] at start-up. `0x1F/0x01` (ord688) and
`0x00/0x02` (object `0x55` to `0x44`) come before every start. None of them
needs a reply for playback to run.

What the stand-in does:

| Event | Stand-in |
|---|---|
| `0xE8/0x20` | binds IrqTimer5 once, programs the device (rate 8000 for code 50, else 16000; mono; the two half addresses), runs it, replies `0x21 [00 00]` |
| `0xE8/0x23` | writes the half's sample count to the device (marks it full); on the first one after a start also sends `0x26` for the other half, so both are full while the first plays |
| device DONE (IRQ) | ISR acknowledges and queues a DFC; the DFC sends `0x26 [00 half]` to SoundDevice's channel (written through the channel's DThread, `+0x54` raw write, then DLogicalChannel::Complete) |
| `0xE8/0x2A` | stops the device, replies `0x2B` with the bytes played of the current half |
| `0x0B/0x14` parameter 2 | device volume = value × 256 / 9, 9 and up = unity (a guess) |

Formats seen (stream settings read at `0x505AC5B8`; buffers from the copy
at `0x505ADF38`), all mono 16-bit, played by the DSP path at 16 kHz:

| Game | Source rate | Buffer | Volume | Notes |
|---|---|---|---|---|
| SonicN | 8000 Hz | 400 samples (50 ms), upsampled to 800 | 9 | one continuous stream; streams silence while paused |
| Rayman 3 | 16000 Hz | 1000 samples (62.5 ms) | 6 | one continuous stream; stops when the screen saver takes over |
| Sega Rally | 8000 Hz | 360 samples (45 ms), upsampled to 720 | 1 | a stream per music piece or screen; each ends by underflow (two halves free → `0x2A`) |

Sega Rally's music files (`bgm*_8.snd`, raw 16-bit) match the 16 kHz
recording decimated by two with correlation 0.986, so rate and pitch are
right. The recordings in `model/.out/au-*/audio.wav` have no device
underruns after the first buffer of each stream (`audio.log`).

## Clock

rtc.dll (variant service 1) waits for NOS's event 1 (method `+0x20`,
`0x50349394` → `0x50349088`) with three 64-bit values. The first two must
agree and be nonzero; they are a base date, which NOS kept in its own flash:
rtc.dll sets the time to that date with the UEMK time of day, plus the UEMK
day counter (`0x5034A678`, `0x5034A2C4`; `model/hw/ngage_cbus.c`). The
third is the alarm, 0 for none (`0x503491CC`). Otherwise the clock counts
as unset, DOS `GetRTCStatus` (304) reports 0 and Startup.app asks for the
time and date at every start (`0x50BBB08E`; the earlier stand-in sent
zeros). The stand-in now reads the HLE RTC date register (an emulator
invention at `0x0C1F0100`, fed from the host or MiSTer clock) in
`nos_rtc_base` (`0x514A1CA4`), converts it to a TTime in EUser's calendar
(Julian leap years up to 1600, so 12 days ahead of a proleptic Gregorian
count: `0x503B8340`, `0x503BA508`), and sends it twice with no alarm.
After a C: format Startup.app still asks once, because
`C:\system\bootdata\FirstBoot.dat` is missing (`0x50BBB614`); later
starts go straight to the idle screen with the host's date and time.

HelperDrv's "auxstart" query (variant service 3 read, id 12, 2 bytes with a
DFC; `0x5037F1C8`) is made by EStart at every boot, up to seven times (the
model with timestamps, 2026-10-22; the earlier belief that it came only
when C: failed to mount was wrong). 105 makes EStart erase and format C:
(the CS1 area `0x400000`-`0x7FFFFF`) and the boot goes on; 0 leaves C: as
it is. With a blank C: (a fresh image) 0 leaves C: a RAM drive, Starter
then takes its (0, 210) start-up list, finds no backup server and the
kernel faults in Starter's cleanup (`RArrayBase::Count` on NULL, progress
log 2026-10-21). With a formatted C:, 105 at every boot erased all 71
sectors every time: 50 s of idle on the core (the chip's 0.7 s an erase,
20 ms in the model, which is why the model never showed it), and the Time
and Date dialogs at every start, the format having removed the first-boot
marker. So the stand-in answers 105 only while C: is blank, which it reads
from the HLE register `0x0C1F0104` (bit 0: no non-erased C: data has been
loaded or programmed since the current CS1 image began loading; both the
core and model keep this sticky until another image load; `docs/UPP_WD2.md`), and 0 otherwise. What NOS
answers on a phone is unknown; a phone's C: is formatted at the factory.

## Not answered yet

Requests seen but left without a reply (the client keeps waiting):

| Resource | Request | From | Notes |
|---|---|---|---|
| `0x3A` | `0x05` [`03 01 00 00 00 00`], [`03 02 ...`] | DOS object `0x4F` | |
| `0x31` GPDS | `0x19` | TSY | |
| `0x0A` network | `0x00` | TSY | |
| `0x09` SIM | `0x19` [`2F`] | object `0x4C` | READ_HPLMN (oFono) |
| `0x09` SIM | `0x3D` [`FA 00`] | TSY | reply `0x3E`, phonetsy.tsy `0x5093FA20` (request type 0x4C, reads a string at [11] = 1) |
| `0x1F` | `0x01` [long] | object `0x4A` (SoundDevice.mda) | reserve, before audio starts after the first boot; playback needs no reply (`0x04`, the release, is answered above) |
| `0x00` | `0x02` [`00 00`], to object `0x44` | object `0x55` | before every audio start; playback needs no reply |
| `0x0B` | `0x19` [`00 04 02`], [`00 04 00`], [`00 05 05`] | object `0x4A` | audio routing at teardown (ord850) |
| `0x23` | `0x04` [`00 32 00 01 ...`] | DOS object `0x4F` | |
| `0x02` | `0x14` [`01 00`] | object `0x4C` | gnokii: 0x02 SMS |
| `0x15` MTC | `0x01` [`01 00`] | DOS object `0x4F` | MTC_STATE_REQ(normal), oFono mtc.h; object `0x4F`'s handler (`0x50FFBE6C`) takes MTC 0x66, 0x67, 0x69 and MTC_STATE_INFO_IND 0xC0, not 0x64 |
| `0x0B` | `0x00` [`01`] | object `0x4A` | |
| - | channel request 2 on unit 2 | TSY | stays pending |
