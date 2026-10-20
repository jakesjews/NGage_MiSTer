# Dump kernel data and heap for model/tools/kthreads.py (used by model/threads.sh).
dump binary memory model/.out/kdata.bin 0x80000000 0x80010000
dump binary memory model/.out/kheap.bin 0x80400000 0x80420000
info registers pc lr cpsr
