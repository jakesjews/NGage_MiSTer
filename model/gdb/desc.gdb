# Usage: set $d = <TDesC16 address>; then "source model/gdb/desc.gdb"
# Prints up to 40 UTF-16 code units of the descriptor as hex (decode with
# model/tools/gdbdesc.py). Layout: word 0 = type << 28 | length; type 0
# TBufC (data at +4), 1 TPtrC (pointer at +4), 2 TPtr (pointer at +8),
# 3 TBuf (data at +8), 4 TBufCPtr (pointer at +8 to a TBufC).
set $t = *(unsigned*)$d >> 28
printf "DESC len=%d type=%d\n", *(unsigned*)$d & 0xfffffff, $t
if $t == 0
  x/40hx $d+4
end
if $t == 1
  x/40hx *(unsigned*)($d+4)
end
if $t == 2
  x/40hx *(unsigned*)($d+8)
end
if $t == 3
  x/40hx $d+8
end
if $t == 4
  x/40hx *(unsigned*)($d+8)+4
end
