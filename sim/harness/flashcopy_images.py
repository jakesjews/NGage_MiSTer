#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# The images for `make -C sim flashcopy`: the program (raw, linked at 0) as
# a 16 MB CS0 image, and an 8 MB CS1 image of seeded pseudo-random bytes.
#   flashcopy_images.py PROGRAM.bin CS0.bin CS1.bin
import random
import sys

prog, cs0, cs1 = sys.argv[1:4]
code = open(prog, 'rb').read()
open(cs0, 'wb').write(code + b'\xff' * ((16 << 20) - len(code)))
rng = random.Random(20261025)
open(cs1, 'wb').write(rng.randbytes(8 << 20))
