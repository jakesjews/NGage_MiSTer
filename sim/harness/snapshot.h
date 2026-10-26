// Snapshot helpers for the whole-core bench: the harness-side state (the
// memory chip models, the bench's counters) goes into a plain file next to
// Verilator's own save file (--savable: VerilatedSave/VerilatedRestore).
// Everything is written raw, host byte order, so a snapshot is for the same
// binary that wrote it.
#pragma once
#include <cstdint>
#include <cstdio>
#include <deque>
#include <random>
#include <sstream>
#include <string>
#include <vector>

namespace snap {

inline void fail(const char *what) {
	fprintf(stderr, "snapshot: %s\n", what);
	exit(2);
}
template <class T> void put(FILE *f, const T &v) {
	if (fwrite(&v, sizeof v, 1, f) != 1) fail("write failed");
}
template <class T> void get(FILE *f, T &v) {
	if (fread(&v, sizeof v, 1, f) != 1) fail("short read");
}
template <class T> void put(FILE *f, const std::vector<T> &v) {
	uint64_t n = v.size();
	put(f, n);
	if (n && fwrite(v.data(), sizeof(T), (size_t)n, f) != (size_t)n) fail("write failed");
}
template <class T> void get(FILE *f, std::vector<T> &v) {
	uint64_t n;
	get(f, n);
	v.resize((size_t)n);
	if (n && fread(v.data(), sizeof(T), (size_t)n, f) != (size_t)n) fail("short read");
}
template <class T> void put(FILE *f, const std::deque<T> &d) {
	put(f, std::vector<T>(d.begin(), d.end()));
}
template <class T> void get(FILE *f, std::deque<T> &d) {
	std::vector<T> v;
	get(f, v);
	d.assign(v.begin(), v.end());
}
inline void put(FILE *f, const std::string &s) {
	put(f, std::vector<char>(s.begin(), s.end()));
}
inline void get(FILE *f, std::string &s) {
	std::vector<char> v;
	get(f, v);
	s.assign(v.begin(), v.end());
}
// a standard engine's state, through its text form
inline void put(FILE *f, const std::mt19937 &g) {
	std::ostringstream ss;
	ss << g;
	put(f, ss.str());
}
inline void get(FILE *f, std::mt19937 &g) {
	std::string s;
	get(f, s);
	std::istringstream ss(s);
	ss >> g;
}
// a marker between sections, so a mismatch is caught where it happens
inline void mark(FILE *f, uint32_t m) { put(f, m); }
inline void check(FILE *f, uint32_t m) {
	uint32_t v;
	get(f, v);
	if (v != m) fail("section marker mismatch (a snapshot of another binary or layout?)");
}

}  // namespace snap
