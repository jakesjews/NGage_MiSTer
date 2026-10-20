# NOS stand-in: the modem side at the ISI level

The N-Gage's cellular software (NOS) is encrypted in flash and its key is
in the UPP_WD2 silicon, so the core cannot run it. Symbian still expects a
modem: start-up servers and the telephony stack send ISI messages over
PhoNet and wait for answers. The stand-in answers them as a phone with
**no SIM card, no network, no PIN or security code, modem state normal**.
A real N-Gage in that state reaches the idle screen and runs games.

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
| `0x09` SIM | after the `0x1C` reply, unsolicited | `0xEF` SIM_IND [`00 06 05 00`] | SIM state 5 → DosSrv ord31(4) → DOS event 17 → SA `0x100052E9` = 4 (`ESASimNotPresent`) | Nokia.dsy `0x50FFB21C` reads [12] as state 1..8; Startup.app gate at `0x50BBBCBC` (state 8 gave SA 7, "SIM usable") |
| `0x35` | `0x02` [`01 00`], DOS self test | `0x03` [`00`] | DOS sends `0x35/0x00` | Nokia.dsy `0x50FFBB04` reads [10]: 0/10/11 → next step (`0x50FFBDC4`); 12 → DOS event 1 = 2, "Device start-up failed" (tried); others → ask again |
| `0x35` | `0x00` [`02 00`] | `0x01` [`00`] | DOS sends `0x59/0x01` | Nokia.dsy `0x50FFBBBC` reads [10]: 0 → next step (`0x50FFBD6C`); 1/2 → ask again; 12 → failure and MTC_STATE_REQ(SELFTEST_FAIL) |
| `0x59` | `0x01` [`08 00`] | `0x02` [`00`] | DOS event 1 = 3: self test passed; Startup.app state 1 → 2 → 4 | Nokia.dsy `0x50FFBC74` reads [10]: 0 → event 1 = 3 (`0x50FFBCBC`); others → ask again; Startup.app `0x50BBAF60` |

## Not answered yet

Requests seen but left without a reply (the client keeps waiting):

| Resource | Request | From | Notes |
|---|---|---|---|
| `0x17` | `0x08` [`01 00`], `0x0A` [`02 00`] | DOS | battery (gnokii nk6510: 0x17 battery). Replies `0x09`, `0x0B` parsed at Nokia.dsy `0x50FFAF00`, `0x50FFB00C` |
| `0x3A` | `0x05` [`03 01 00 00 00 00`], [`03 02 ...`] | DOS object `0x4F` | |
| `0x31` GPDS | `0x19` | TSY | |
| `0x0A` network | `0x00` | TSY | |
| `0x09` SIM | `0x19` [`2F`] | object `0x4C` | |
| `0x0B` | `0x11` [`06 01`] | TSY | gnokii: 0x0B sound |
| `0x0B` | `0x00` [`01`] | object `0x4A` | |
| - | channel request 2 on unit 2 | TSY | stays pending |
