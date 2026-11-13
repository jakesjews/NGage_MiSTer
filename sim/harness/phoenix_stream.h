// Synthetic Phoenix records shared by the loader and whole-core benches.
#pragma once
#include <cstdint>
#include <vector>
namespace phoenix {
using Bytes = std::vector<uint8_t>;
inline void be(Bytes &v, uint32_t n, int bytes) { for (int i = bytes - 1; i >= 0; i--) v.push_back(n >> (8 * i)); }
inline uint8_t checksum(const Bytes &v) { unsigned sum = 0; for (auto b : v) sum += b; return uint8_t(~sum); }
inline Bytes stream() {
	// Normal token, nested token with u16 length, extended u8 length, padding.
	Bytes tokens = {0,0,0,3, 0xC2,3,'a','b','c', 0xF3,0,2,'x','y', 0xC8,0,2,'p','q', 0};
	Bytes v = {0xA2}; be(v, tokens.size(), 4); v.insert(v.end(), tokens.begin(), tokens.end()); return v;
}
inline void record(Bytes &v, uint8_t type, uint32_t addr, const Bytes &data, bool damaged = false, bool plus_one = true) {
	Bytes tail; be(tail, addr, 4);
	tail.push_back(uint8_t(checksum(data) + (plus_one ? 1 : 0)) ^ (damaged ? 4 : 0));
	be(tail, data.size(), 3);
	v.push_back(type);
	if (type == 0x21) v.insert(v.end(), {0,2,0xDD,0x94,0x8C,0x14});
	v.insert(v.end(), tail.begin(), tail.end()); v.push_back(checksum(tail));
	v.insert(v.end(), data.begin(), data.end());
}
inline Bytes table(bool known = true) {
	// Entry 8F00 (a language pack's own: any digest that is not erased) and
	// entry 8F18 with the 4.10 MCU file's unpatched digest, as the loader
	// expects them (rtl/mister/phoenix_load.sv, signature_bad).
	Bytes t = {0,0,0x23,0x51, 0xFF,0x3F,0x37,0x51,
		0xBC,0x89,0x35,0x93,0x74,0x83,0x1B,0x03,0xCB,0x3B,0x8C,0xF4,0x0A,0x3B,0x06,0x70,
		0,0x90,0,0x50, 0xFF,0x4F,0x16,0x51,
		0xBE,0x87,0xBC,0x44,0x67,0xBC,0x4C,0x53,0xF6,0xDE,0x1E,0xE8,0xD8,0x0D,0x92,0x85};
	if (!known) t[32] ^= 1;
	return t;
}
// The loader gives every byte one owner (phoenix_load.sv, pack_area): the
// first 64 KB of CS0, CS0 from 0xF00000 and CS1 from 0x330000 are the
// language pack's, the rest the MCU file's. Both files below also carry a
// record in the other's area (bytes EE), as the real MCU file does for the
// first 64 KB: those must never reach flash.
inline Bytes mcu(bool damaged = false) {
	auto v = stream();
	record(v, 0x14, 0x80, {0xEE,0xEE,0xEE,0xEE,0xEE,0xEE,0xEE,0xEE}); // its copy of the ROM header: the pack's area
	record(v, 0x21, 0x10180, {1,2,3,4,5});
	record(v, 0x14, 0x12000, {0x55,0x66}, damaged);
	record(v, 0x14, 0x00F00010, {0xEE}); // the pack's ROM area
	record(v, 0x14, 0x02000003, {0x11,0x22,0x33,0x44}, false, false);
	v.insert(v.end(), {0x20,0,0,0,3,0, 0x14,0x21,0xFF}); // Bluetooth, not records
	v.insert(v.end(), {0x25,3,0x14,0x21,0xFF});
	v.insert(v.end(), {0x26,0,0,0,0,0,0,0,0,0});
	record(v, 0x2E, 0, {9,8,7}, false, false); // mass memory, never NOR
	return v;
}
inline Bytes language(bool known = true) {
	auto v = stream();
	record(v, 0x14, 0x80, {0,0,0,0,0x40,0x24,0x44,0x18}); // the 4.10 ROM header's time stamp
	record(v, 0x14, 0x8F00, table(known));
	record(v, 0x14, 0x00F00001, {6,7,8,9});
	record(v, 0x14, 0x20000, {0xEE}); // the MCU file's area
	record(v, 0x14, 0x02330000, {0x77});
	return v;
}
}
