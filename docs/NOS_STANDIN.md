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

- `model/nos-stub/nos_stub.S`: the NOS entry that nosstarter.ext calls
  (variant services, flags, power model, rtc event).
- `model/nos-stub/nos_dll.S`, `nos_dll.ld`: entry points of the hidden NOS
  DLL at its fixed ROM addresses (ordinal 4 `0x514A1CA0`, ordinal 6
  `0x514A261C`); state lives in NOS BSS at `0x8000D000`.
- `model/nos-stub/nos_isi.c`: the channel object nosdriver.ldd talks to,
  queues and delivery.
- `model/nos-stub/nos_isi_replies.h`: the replies listed below.
- `model/rom-patches.txt` places both binaries (`cs0file` lines);
  `tools/mkimage.py` applies the same file for the core.

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
| `0x0B` | `0x11` [`06 01`] (TSY) | `0x12` [`06 01 06 08 00 00 00 00 00 00`] | completes RCtmGsmPhone::GetHandsfreeMode (hands-free off), which PhoneServer waits on at start-up | phonetsy.tsy `0x5093E1D8`: [10] setting, [11] sub-block count = 1, sub-block at [12], 16-bit big-endian value at its bytes 4-5 (isimsg ord1568); `0x5092E16C` setting 6: 13 → on, else off. Sub-block id and length are guesses |

## Not answered yet

Requests seen but left without a reply (the client keeps waiting):

| Resource | Request | From | Notes |
|---|---|---|---|
| `0x3A` | `0x05` [`03 01 00 00 00 00`], [`03 02 ...`] | DOS object `0x4F` | |
| `0x31` GPDS | `0x19` | TSY | |
| `0x0A` network | `0x00` | TSY | |
| `0x09` SIM | `0x19` [`2F`] | object `0x4C` | READ_HPLMN (oFono) |
| `0x09` SIM | `0x3D` [`FA 00`] | TSY | reply `0x3E`, phonetsy.tsy `0x5093FA20` (request type 0x4C, reads a string at [11] = 1) |
| `0x1F` | `0x01` [long], `0x04` [`00 00 00`] | object `0x4A` | |
| `0x23` | `0x04` [`00 32 00 01 ...`] | DOS object `0x4F` | |
| `0x02` | `0x14` [`01 00`] | object `0x4C` | gnokii: 0x02 SMS |
| `0x15` MTC | `0x01` [`01 00`] | DOS object `0x4F` | MTC_STATE_REQ(normal), oFono mtc.h; object `0x4F`'s handler (`0x50FFBE6C`) takes MTC 0x66, 0x67, 0x69 and MTC_STATE_INFO_IND 0xC0, not 0x64 |
| `0x0B` | `0x00` [`01`] | object `0x4A` | |
| - | channel request 2 on unit 2 | TSY | stays pending |
