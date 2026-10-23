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
	Bytes t = {0,0,0x23,0x51, 0xFF,0xEF,0x38,0x51,
		0xA4,0xE5,0x13,0x08,0xDE,0x06,0xC2,0x14,0x5C,0x2A,0xC9,0xF8,0x01,0xDC,0x60,0x99,
		0,0x90,0,0x50, 0xFF,0x9F,0x16,0x51,
		0x2F,0,0xB1,0xFF,0x1B,0x8F,0x03,0xF0,0x59,0x2C,0x43,0x55,0xF3,0x17,0x76,0x51};
	if (!known) t[8] ^= 1;
	return t;
}
inline Bytes mcu(bool known = true, bool damaged = false) {
	auto v = stream();
	record(v, 0x21, 0x80, {1,2,3,4,5});
	record(v, 0x14, 0x8F00, table(known), damaged);
	record(v, 0x14, 0x02000003, {0x11,0x22,0x33,0x44}, false, false);
	v.insert(v.end(), {0x20,0,0,0,3,0, 0x14,0x21,0xFF}); // Bluetooth, not records
	v.insert(v.end(), {0x25,3,0x14,0x21,0xFF});
	v.insert(v.end(), {0x26,0,0,0,0,0,0,0,0,0});
	record(v, 0x2E, 0, {9,8,7}, false, false); // mass memory, never NOR
	return v;
}
inline Bytes language() { auto v = stream(); record(v, 0x14, 0x00F00001, {6,7,8,9}); return v; }
}
