#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reference for wfi_irq.S using QEMU's CPU IRQ GPIO and real WFI execution.

The none machine has no timer device. Its RAM covers BENCH so the test's
STRs execute normally; this driver observes the two BENCH stores and applies
their IRQ/timer effects through qtest. Timer ticks count stepped instructions,
not RTL clocks. The test compares architectural results, never an IRQ's exact
arrival PC or elapsed time. WFI itself runs with continue (single-stepping WFI
can suppress its halt); a pending timer expires while the CPU is halted.

Usage: irq.py TEST.bin OUT_PREFIX [--qemu PATH] [--cpu arm926]
ARM926 supplies c7,c0,4 WFI; QEMU's ti925t treats that encoding as a NOP.
Only the ARM STR r0,[r10,#BENCH_INT/IRQ_IN] protocol of wfi_irq is supported.
"""
import argparse
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time


class Qemu:
    def __init__(self, executable, cpu, directory):
        self.directory = Path(directory)
        self.log = (self.directory / 'qemu.log').open('w')
        self.process = subprocess.Popen([
            executable, '-M', 'none', '-cpu', cpu, '-m', '4096M',
            '-nographic', '-monitor', 'none', '-serial', 'none', '-S',
            '-gdb', f'unix:{directory}/gdb,server=on,wait=off',
            '-qtest', f'unix:{directory}/qtest,server=on,wait=off',
        ], stdout=self.log, stderr=self.log)
        try:
            self.gdb = self.connect('gdb')
            self.qtest = self.connect('qtest')
            self.qreader = self.qtest.makefile('rb')
            self.command('qSupported')
            # QEMU's default single-step mode suppresses IRQs. Keep them enabled.
            assert self.command('Qqemu.sstep=0x1') == 'OK'
        except BaseException:
            self.process.terminate()
            self.process.wait(timeout=5)
            self.log.close()
            raise

    def connect(self, name):
        connection = socket.socket(socket.AF_UNIX)
        connection.settimeout(2)
        for _ in range(100):
            try:
                connection.connect(str(self.directory / name))
                return connection
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process.poll() is not None:
                    raise RuntimeError((self.directory / 'qemu.log').read_text())
                time.sleep(.02)
        raise TimeoutError(f'QEMU {name} socket')

    def send(self, command):
        payload = command.encode()
        self.gdb.sendall(b'$' + payload + b'#' + f'{sum(payload) % 256:02x}'.encode())

    def receive(self):
        while True:
            byte = self.gdb.recv(1)
            if not byte:
                raise EOFError('QEMU GDB disconnected')
            if byte == b'$':
                break
        payload = bytearray()
        while True:
            byte = self.gdb.recv(1)
            if not byte:
                raise EOFError('QEMU GDB disconnected in packet')
            if byte == b'#':
                break
            payload.extend(byte)
        checksum = self.gdb.recv(1) + self.gdb.recv(1)
        assert int(checksum, 16) == sum(payload) % 256
        self.gdb.sendall(b'+')
        return payload.decode()

    def command(self, command):
        self.send(command)
        return self.receive()

    def irq(self, level):
        self.qtest.sendall(f'set_irq_in /machine/unattached/device[0] unnamed-gpio-in 0 {level}\n'.encode())
        assert self.qreader.readline().strip() == b'OK'

    def breakpoint(self, address, enable):
        assert self.command(f'{"Z" if enable else "z"}0,{address:x},4') == 'OK'

    def close(self):
        self.process.terminate()
        self.process.wait(timeout=5)
        self.qreader.close()
        self.qtest.close()
        self.gdb.close()
        self.log.close()


def reference(qemu, binary, output):
    for offset in range(0, len(binary), 512):
        data = binary[offset:offset + 512]
        assert qemu.command(f'M{offset:x},{len(data):x}:{data.hex()}') == 'OK'
    assert qemu.command('Pf=00000000') == 'OK'  # PC
    assert qemu.command('P19=d3000000') == 'OK'  # masked SVC
    qemu.irq(0)
    timer = None
    wfi_waits = 0
    for steps in range(100000):
        registers = bytes.fromhex(qemu.command('g'))
        r0, r10, pc = (struct.unpack_from('<I', registers, offset)[0] for offset in (0, 40, 60))
        if pc == 0x40:
            break
        instruction = int.from_bytes(bytes.fromhex(qemu.command(f'm{pc:x},4')), 'little')
        if r10 == 0xf0000000:
            if instruction == 0xe58a0008:
                qemu.irq(r0 & 1)
            elif instruction == 0xe58a000c:
                timer = r0
        if instruction == 0xee070f90:  # MCR p15,0,r0,c7,c0,4
            # Stop after the following instruction or at IRQ entry. The
            # handler then executes normally, including its BENCH acknowledge.
            qemu.breakpoint(pc + 8, True)
            qemu.breakpoint(0x18, True)
            qemu.send('c')
            qemu.gdb.settimeout(.05)
            try:
                reply = qemu.receive()
                assert timer is None, f'WFI at {pc:08x} fell through before its timer expired'
            except TimeoutError:
                assert timer is not None, 'WFI blocked without a pending timer'
                timer = None
                wfi_waits += 1
                qemu.irq(1)
                qemu.gdb.settimeout(2)
                reply = qemu.receive()
            finally:
                qemu.gdb.settimeout(2)
            qemu.breakpoint(pc + 8, False)
            qemu.breakpoint(0x18, False)
        else:
            reply = qemu.command('s')
        assert reply.startswith('T05'), reply
        if timer is not None:
            timer -= 1
            if timer < 0:
                timer = None
                qemu.irq(1)
    else:
        raise RuntimeError('test did not reach halt in 100000 steps')
    signature = b''.join(bytes.fromhex(qemu.command(f'm{address:x},200'))
                         for address in range(0xf00000, 0xf10000, 512))
    output.with_suffix('.sig').write_bytes(signature)
    assert struct.unpack_from('<I', signature)[0] == 1, signature[:20].hex()
    assert wfi_waits == 2, f'expected masked and unmasked WFI waits, saw {wfi_waits}'
    print(f'QEMU IRQ reference: PASS ({steps} steps, {wfi_waits} actual WFI waits)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--qemu', default=os.environ.get('QEMU', 'qemu-system-arm'))
    parser.add_argument('--cpu', default='arm926')
    args = parser.parse_args()
    # Do not leave a previous successful reference after a failed run.
    args.output.with_suffix('.sig').unlink(missing_ok=True)
    args.output.with_suffix('.qlog').unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix='qemu-wfi-') as directory:
        qemu = Qemu(args.qemu, args.cpu, directory)
        try:
            reference(qemu, args.binary.read_bytes(), args.output)
        finally:
            qemu.close()


if __name__ == '__main__':
    main()
