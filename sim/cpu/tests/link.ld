/* SPDX-License-Identifier: GPL-3.0-or-later */
/* CPU tests: everything at 0, in the 16 MB of RAM (see test.inc). */
ENTRY(_start)
SECTIONS
{
	. = 0;
	.text : {
		*(.vectors)
		*(.text*)
		*(.rodata*)
	}
	.data : { *(.data*) }
	.bss : { *(.bss*) *(COMMON) }
	_end = .;
}
