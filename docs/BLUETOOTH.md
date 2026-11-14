# Bluetooth: the module on CBUS

The N-Gage QD has a Bluetooth module on the board. The core has a model of
it in its place: **a Bluetooth 1.1 controller that works and has nobody in
range**. The phone's own software resets it, starts its stack on it, lets
the user switch Bluetooth on and search for devices; a search runs its
time and finds nothing. There is no radio, so nothing connects.

Nothing about the module is documented where we looked. Everything below
is read out of the phone's software, RH-29 firmware 4.60 (the addresses
here; 4.10, which the core runs, has the same code: `btldd.ldd` 0x340
lower, `hci.dll` 0xEA0 lower, `cbus.dll`, `BTTestServer.exe` and
`SelfTestServer.exe` in the same place). Confidence as in `UPP_WD2.md`:
**A** the code leaves no other reading; **B** one plausible reading,
consistent with all uses; **C** a guess the model needs.

The model is `model/hw/ngage_bt_chip.h` (plain C, shared by the reference
model and the bench) with `model/hw/ngage_bt.c` around it; the core's copy
is `rtl/board/bt_module.sv`, the same state register for register.
`make -C sim bt` compares the two access by access.

## Where it sits

The driver is `btldd.ldd` (logical device "bt_driver", one channel). It
reaches the module through CBUS, not a UART: `hci.dll` calls its transport
"CHCTLCBus". The registers go through cbus.dll's service (variant service
0; read `+0x10`, write `+0x14`, called at btldd `0x503F1F8C` / `0x503F1F2C`
with cbus.dll's table indexes 37-42 of `0x5037E544`): **CBUS device 5**,
16 bits each.

| Register | Driver's index | What it is | Conf. |
|---|---|---|---|
| `0x00` | 37 | data: two bytes of a packet a word, the first in bits 15:8 (read `0x503F16D4`, write `0x503F1D08`) | A |
| `0x01` | 38 | length in bytes of the packet the module holds for the phone (`0x503F168C`) | A |
| `0x06` | 39 | read: status (below). Write: 0 then 1 at open (`0x503F0B14`), a reset; 0 then 2 to wake the module (`0x503F19E0`) | A (use), B (bits) |
| `0x08` | 40 | "LPRF_MCU_Reg0" (the driver's name in a message): the write handshake (below) | A |
| `0x09` | 41 | reset reason, read after a reset; bit 3 must be set (`0x503F0EB0`), else "BTLDD: Reset reason" and error -36 | A (bit 3), C (meaning) |
| `0x0A` | 42 | written `0x8000` after the reset (`0x503F18CC`); the module answers through `0x08` | A (use), C (meaning) |
| `0x0B`, `0x10` | 43, 44 | in cbus.dll's table, not used by the driver | - |

Status bits, from the driver's handler (`0x503F0B94`). It reads the
register once per interrupt and keeps bits it read elsewhere for the next
pass (`0x503F117C`), so bits 4-8 are taken to clear when read (B).

| Bit | Meaning | Driver |
|---|---|---|
| 1 | with bit 5 during a write: part of the sleep handshake | `0x503F0D70` |
| 2, 3 | the module is awake; both clear = asleep | `0x503F11A4`, `0x503F1258` |
| 4 | a packet for the phone is ready | `0x503F12DC` |
| 5 | the module wants to sleep ("FallAsleepBit") | `0x503F0D54` |
| 6 | register `0x08` has an answer | `0x503F1348` |
| 7 | the module has reset | `0x503F0E98` |
| 8 | the module woke up | `0x503F0C84` |

The interrupt comes through the CTSI block, second group (`UPP_WD2.md`):
cbus.dll binds a handler on IrqCTSI_IRQ (`0x5037DDE0`; it also makes
GENIO6 an input and writes `0x0C15021A`, `0x0C150216`), which tests bit 4
of `0x0C150102` (`0x5037D5D4`) and calls the handler btldd registered
(service `+0x18`, id 24, at `0x503F0AF0`). That handler writes `0x10` to
`0x0C150102` and queues the status handler (`0x503F0B58`). The driver
enables the bit with `0x10` to `0x0C150016` when it opens and around each
write, and disables it with `0x10` to `0x0C150014` (`0x503F084C`, close).
The module's line is taken as a pulse per event that sets the bit (B: the
handler clears the bit before the status is read, so a level would fire
again at once).

## The driver's protocol

**Open** (`0x503F0A50`): register the handler, write `0x06` = 0 and 1,
enable the interrupt. The first write request then waits up to 1.5 s for
status bit 7 (`0x503F1024`; this is the time-out that showed as "BTLDD:
CompleteWithError: 1 -33" with nothing on the bus). On bit 7 with reason
bit 3 the driver writes `0x0A` = `0x8000` and waits up to 1 s for an
answer in `0x08` (`0x503F1924`).

**Write a packet** of n bytes, at most 520 (`0x503F1644`), states of
`0x503F0F88`:

1. `0x08` = `0x8000 | n` (`0x503F1BE4`): room for n bytes?
2. wait for bit 6 with `0x08` reading n, bits 15:14 = 00 (`0x503F13B4`);
   skipped while the answer to `0x0A` was 520 or more (`0x503F139C`);
3. the bytes to `0x00`, two a word;
4. `0x08` = `0xC000 | n` (`0x503F1E08`): written;
5. wait for bit 6 with `0x08` reading `0x4000 | n` (`0x503F1414`); then
   the client's write completes.

Each wait is 1 s, then error -33.

**Read**: on bit 4 the driver reads the length from `0x01` and that many
bytes from `0x00` into a 4096-byte ring (`0x503F0F40`); the client's reads
take bytes from the ring.

**Sleep** (bits 5 and 8, `0x06` = 2, GENIO6 at `0x0C15020C`): the module
here never asks to sleep, so none of it runs.

**Above the driver**, `hci.dll` frames HCI with two bytes in front: `01
00` and the command going out; coming in, a type byte and one more that is
not looked at, then for type 4 the event's code, length and parameters
(receiver `0x5046F09C`, type table `0x5046F070`; type 2 is ACL data; event
`0x10`, hardware error, makes it leave with -20).

## Who uses it at start-up

Seen in the reference model (`bt.log`), firmware 4.10, a start to the idle
screen on a formatted C:.

| Time | Who | What |
|---|---|---|
| 9.6 s | BTTestServer.exe, for SelfTestServer.exe | reset; Read_Buffer_Size, Write_Connection_Accept_Timeout, Write_Page_Timeout |
| 11.7 s | SelfTestServer.exe stops | the channel is closed |
| 12.5 s | the phone's Bluetooth stack (`hci.dll` again) | reset; Read_Buffer_Size, Read_BD_ADDR, the two time-outs, Write_Scan_Enable 3, Read_Local_Supported_Features, Change_Local_Name "N-Gage QD" |
| 15.5 s | the same, for the EPOC Monitor Server | reset; the same again, then Read_Local_Version_Information, Read_BD_ADDR, Read_Local_Name, Write_Current_IAC_LAP, Write_Scan_Enable 0 |

The driver has one channel, and SelfTestServer.exe ("Calypso EPOC SelfTest
Server") holds it through BTTestServer.exe from its own start
(`0x5036CA6E`) until it exits. It exits when it gets test number 8 on
PhoNet resource `0x59` (`0x5036C79C`), which is the last message of the
DOS self test at every start: `0x59/0x01 [08 00]` from Nokia.dsy. The NOS
stand-in used to answer that message itself, so the server never left, and
the EPOC Monitor Server, which needs the channel through ESock, got
KErrAlreadyExists and panicked ("App. closed EmonServer") as soon as a
module answered. The stand-in now passes the message on
(`NOS_STANDIN.md`, "Routing"). Before there was a module, the same panic
was avoided by a patch of `hci.dll`'s retry count (ten resets of 1.5 s
held the channel just as long); that patch is gone.

## What the model answers

Transport: the reset takes 10 ms (C; the driver waits 1.5 s); the answer
to `0x0A` is 520, the driver's own largest packet (C); every "room for n"
is granted with n and every packet acknowledged, at once (B).

HCI, as a Bluetooth 1.1 controller (the phone's is 1.1). One command at a
time, as HCI's flow control has it. Values marked * are this project's:

| Command | Answer |
|---|---|
| Read_Local_Version_Information | HCI 1.1, LMP 1.1, manufacturer 1 (Nokia Mobile Phones)*, revisions 0* |
| Read_Local_Supported_Features | `FF FF 0F 00 00 00 00 00`: all of 1.1's* |
| Read_Buffer_Size | ACL 339 bytes x 8, SCO 64 bytes x 8* |
| Read_BD_ADDR | `00:60:57:00:00:00`*: Nokia's prefix, no device part, as the IMEI is zeros |
| Read_Country_Code | 0 |
| Change_Local_Name, Read_Local_Name | kept, 248 bytes |
| Read_ / Write_ of PIN type, connection accept time-out, page time-out, scan enable, page and inquiry scan activity, authentication enable, encryption mode, class of device, voice setting, broadcast retransmissions, hold mode activity, SCO flow control, current IAC LAP (one), page scan period mode, page scan mode | kept; before a write, the specification's default. A write with too few parameters: Invalid HCI Command Parameters |
| Read_Number_Of_Supported_IAC | 1 |
| Set_Event_Mask, Set_Event_Filter, Create_New_Unit_Key, Set_Host_Controller_To_Host_Flow_Control, Host_Buffer_Size | complete, nothing kept |
| Read_, Write_, Delete_Stored_Link_Key | room for no keys, none read, written or deleted |
| Reset | the kept values back to their defaults, an inquiry dropped |
| Inquiry | Command Status, then Inquiry Complete with no responses after the length asked for (units of 1.28 s) |
| Inquiry_Cancel | stops it; Command Disallowed if none runs |
| Host_Number_Of_Completed_Packets | no event |
| any other command of the link control and link policy groups | Command Status: Command Disallowed (there is no link and nobody to page) |
| anything else | Command Status: Unknown HCI Command |

ACL and SCO data from the phone is dropped: there is never a link.

Tried in the model and on the board: Tools > Bluetooth, the name dialog,
Bluetooth On, Paired devices > New paired device: "Searching for devices"
for 12.8 s, then the empty list.

## What it does not do

- No radio: no other device is ever found, no connection made or taken.
- The self-test server's Bluetooth tests (numbers 3, 4, 10-12 of
  `0x5036D1D8`, through BTClient.dll) are asked for by the cellular side,
  which the stand-in does not do; what they send is not known.
- Nokia's own HCI commands, if the stack has any for this module, were
  not seen in the traffic above and get "Unknown HCI Command".
- Sleep and wake-up.
