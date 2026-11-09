// Logical byte address to the independent SDRAM chip model's physical halfword.
#pragma once
#include <cstdint>
inline uint32_t sdram_physical_halfword(uint32_t byte) {
    const unsigned bank = (byte / 4096) % 4;
    const unsigned row = (byte / 16384) * 4 + (byte / 1024) % 4;
    const unsigned column = (byte % 1024) / 2;
    return (bank * 8192 + row) * 512 + column;
}
