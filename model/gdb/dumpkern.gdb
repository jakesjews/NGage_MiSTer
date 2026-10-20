# Dump kernel data for model/tools/kthreads.py (used by model/threads.sh).
info registers pc lr cpsr
dump binary memory model/.out/kdata.bin 0x80000000 0x80010000
