// Standalone Phoenix loader, randomized DDR backpressure, real-image comparison.
#include "Vphoenix_load.h"
#include "verilated.h"
#include "common.h"
#include "phoenix_stream.h"
#include <fstream>
#include <algorithm>
#include <cstring>
using phoenix::Bytes;
static Bytes read_file(const std::string &name) {
	std::ifstream f(name, std::ios::binary);
	if (!f) { fprintf(stderr, "cannot read %s\n", name.c_str()); exit(1); }
	return Bytes(std::istreambuf_iterator<char>(f), {});
}
struct Bench {
	Vphoenix_load t;
	Bytes cs0 = Bytes(16u << 20, 0x5A), cs1 = Bytes(8u << 20, 0x69);
	sim::Rng rng{7};
	uint64_t cycles = 0, writes = 0;
	int notes[5] = {}, read_delay = 0;
	uint64_t read_data = 0;
	bool held = false;
	uint32_t held_addr = 0;
	uint64_t held_data = 0;
	uint8_t held_be = 0, held_cmd = 0;
	Bench() {
		t.clk = 0; t.reset = 1; t.ioctl_download = 0; t.ioctl_index = 0; t.ioctl_wr = 0;
		t.ioctl_dout = 0; t.ld_busy = 0; t.ld_valid = 0; t.ld_data = 0;
		for (int i=0;i<4;i++) tick(); t.reset = 0; tick();
	}
	uint8_t &mem(uint32_t addr) {
		if (addr >= 0x31000000 && addr < 0x32000000) return cs0[addr - 0x31000000];
		if (addr >= 0x32000000 && addr < 0x32800000) return cs1[addr - 0x32000000];
		fprintf(stderr,"loader address out of range: %08x\n",addr); exit(1);
	}
	void tick() {
		t.clk = 0; t.eval();
		uint8_t cmd = t.ld_we | (t.ld_rd << 1);
		if (held) CHECK(cmd == held_cmd && t.ld_addr == held_addr &&
			(!(cmd & 1) || (t.ld_din == held_data && t.ld_be == held_be)), "DDR command changed while stalled");
		held = cmd && t.ld_busy; held_cmd = cmd; held_addr = t.ld_addr; held_data = t.ld_din; held_be = t.ld_be;
		CHECK(cmd != 3, "simultaneous read/write");
		if (cmd && !t.ld_busy) {
			uint32_t a = t.ld_addr << 3;
			if (t.ld_we) {
				CHECK(a < 0x32400000, "Phoenix touched C:");
				for (int i=0;i<8;i++) if (t.ld_be & (1 << i)) mem(a+i) = t.ld_din >> (8*i);
				writes++;
			} else {
				CHECK(!read_delay, "multiple reads outstanding");
				read_delay = rng.range(3,12); read_data = 0;
				for(int i=0;i<8;i++) read_data |= uint64_t(mem(a+i)) << (8*i);
			}
		}
		t.clk = 1; t.eval();
		if (t.note) {
			CHECK(t.note < 5, "unknown loader note");
			if (t.note < 5) notes[t.note]++;
			if (t.note == 4) CHECK(!t.ioctl_download && !t.busy, "reload notice only after download finishes");
		}
		t.clk = 0; t.ld_busy = rng.chance(30); t.ld_valid = 0;
		if (read_delay && --read_delay == 0) { t.ld_valid = 1; t.ld_data = read_data; }
		t.eval(); cycles++;
	}
	void drain() { uint64_t end=cycles+200000000; while ((t.busy || t.ioctl_wait) && cycles<end) tick(); CHECK(cycles<end,"loader stuck"); }
	void download(int index, const Bytes &v) {
		t.ioctl_index=index; t.ioctl_download=1; for(int i=0;i<5;i++) tick();
		for(size_t i=0;i<v.size();i+=2) {
			uint64_t end=cycles+10000000;
			while(t.ioctl_wait && cycles<end) tick(); CHECK(cycles<end,"ioctl_wait stuck");
			t.ioctl_dout=v[i] | ((i+1<v.size()?v[i+1]:0x7A)<<8); t.ioctl_wr=1; tick();
			t.ioctl_wr=0; tick();
		}
		while(t.ioctl_wait) tick(); t.ioctl_download=0; tick(); drain();
	}
	void check_patches() {
		std::ifstream f("rtl/mister/phoenix_patch.hex"); Bytes p; unsigned x;
		while(f >> std::hex >> x) p.push_back(x);
		CHECK(!p.empty(), "patch ROM read");
		for(size_t pos=0;pos<p.size() && p[pos]!=255;) {
			unsigned chip=p[pos++],off=0,n=0;
			for(int i=0;i<3;i++) off=(off<<8)|p[pos++];
			for(int i=0;i<4;i++) n=(n<<8)|p[pos++];
			CHECK(pos+n<=p.size(),"patch table truncated");
			CHECK(!memcmp((chip?cs1:cs0).data()+off,p.data()+pos,n),"patch payload at %06x",off); pos+=n;
		}
	}
};
int main(int argc, char **argv) {
	Verilated::commandArgs(argc,argv);
	if(argc == 5) {
		Bench b; std::fill(b.cs1.begin()+(4u<<20),b.cs1.end(),255); // separate blank C: save
		b.download(1,read_file(argv[1])); b.download(2,read_file(argv[2]));
		CHECK(b.t.ready && !b.t.errors && b.notes[3]==1,"real firmware accepted");
		CHECK(b.cs0==read_file(argv[3]),"CS0 byte-identical to reference");
		CHECK(b.cs1==read_file(argv[4]),"CS1 byte-identical to reference");
		std::ofstream("sim/build/out/phoenix-cs0.bin",std::ios::binary).write((char*)b.cs0.data(),b.cs0.size());
		std::ofstream("sim/build/out/phoenix-cs1.bin",std::ios::binary).write((char*)b.cs1.data(),b.cs1.size());
		printf("real Phoenix: %llu clocks, %llu DDR writes\n",(unsigned long long)b.cycles,(unsigned long long)b.writes);
		b.download(1,read_file(argv[1]));
		CHECK(!b.t.ready && b.t.debug_have==1 && b.notes[4]==1 && !b.t.errors,"real MCU resend explains incomplete pair");
		b.download(2,read_file(argv[2]));
		CHECK(b.t.ready && b.notes[3]==2 && b.notes[4]==1,"real language reload completes pair");
		CHECK(b.cs0==read_file(argv[3]) && b.cs1==read_file(argv[4]),"reloaded pair byte-identical to both references");
		printf("real Phoenix including resend/recovery: %llu clocks, %llu DDR writes\n",(unsigned long long)b.cycles,(unsigned long long)b.writes);
		// The language pack first: the MCU file then puts the pack's entry in its
		// integrity table (CS0 0x8F00) back to FF, and the pair is refused. So the
		// game folder's files are boot0.rom (MCU) and boot1.rom, Main's order.
		{ Bench c; std::fill(c.cs1.begin()+(4u<<20),c.cs1.end(),255);
		  c.download(2,read_file(argv[2])); CHECK(!c.t.ready && !c.t.errors,"real language pack alone");
		  c.download(1,read_file(argv[1]));
		  CHECK(!c.t.ready && !c.t.errors && c.notes[2]==1 && c.notes[3]==0,"real language pack before the MCU file is refused, not started");
		  CHECK(std::all_of(c.cs0.begin()+0x8f00,c.cs0.begin()+0x8f18,[](uint8_t v){return v==255;}),"the pack's integrity entry is gone"); }
	} else {
		for(bool reverse:{false,true}) {
			Bench b;
			b.download(reverse?2:1,reverse?phoenix::language():phoenix::mcu()); CHECK(!b.t.ready,"needs both files");
			b.download(reverse?1:2,reverse?phoenix::mcu():phoenix::language());
			CHECK(b.t.ready && b.notes[3]==1 && !b.t.errors,"synthetic 4.10 accepted in either order");
			CHECK_EQ(b.cs0[0],255,"skipped records do not map to NOR"); CHECK_EQ(b.cs0[0x185],255,"FF gap");
			CHECK_EQ(b.cs0[0x180],1,"21 data"); CHECK_EQ(b.cs1[3],0x11,"CS1 firmware data");
			CHECK_EQ(b.cs0[0xf00001],6,"language data"); b.check_patches();
			CHECK_EQ(b.notes[4],0,"initial pair has no reload warning");
			b.download(reverse?2:1,reverse?phoenix::language():phoenix::mcu());
			CHECK(!b.t.ready && b.t.debug_have==(reverse?2:1) && b.notes[4]==1,"either repeated file requests companion");
			CHECK_EQ(b.cs0[0x9e4c4],255,"new pair does not retain old patch bytes");
			b.download(reverse?1:2,reverse?phoenix::mcu():phoenix::language());
			CHECK(b.t.ready && b.notes[3]==2 && b.notes[4]==1,"companion repairs pair without spurious warning");
			b.check_patches();
			b.download(1,phoenix::mcu(true,true));
			CHECK(!b.t.ready && b.notes[1]==1 && b.notes[4]==1,"damaged resend reports damage instead of reload");
			CHECK(std::all_of(b.cs1.begin()+(4u<<20),b.cs1.end(),[](uint8_t x){return x==0x69;}),"C: preserved");
		}
		{ Bench b; b.download(1,phoenix::mcu(false)); b.download(2,phoenix::language());
		  CHECK(!b.t.ready && b.notes[2]==1,"unknown firmware blocked"); CHECK_EQ(b.cs0[0x9e4c4],255,"unknown version left unpatched"); }
		// Another version's MCU file under a 4.10 language pack's table: the ROM
		// header's time stamp gives it away.
		{ Bench b; auto v=phoenix::mcu(); phoenix::record(v,0x14,0x84,{0x80,0x4B,0x2F,0xA2}); b.download(1,v); b.download(2,phoenix::language());
		  CHECK(!b.t.ready && b.notes[2]==1,"another version's MCU file blocked"); CHECK_EQ(b.cs0[0x9e4c4],255,"and left unpatched"); }
		// A table with no language pack entry.
		{ Bench b; auto v=phoenix::mcu(); phoenix::record(v,0x14,0x8F10,{255,255,255,255,255,255,255,255}); b.download(1,v); b.download(2,phoenix::language());
		  CHECK(!b.t.ready && b.notes[2]==1,"missing language pack entry blocked"); }
		{ Bench b; b.download(1,phoenix::mcu(true,true)); CHECK(b.t.errors && b.notes[1]==1 && !b.t.ready,"bad checksum blocked");
		  b.download(1,phoenix::mcu()); b.download(2,phoenix::language()); CHECK(b.t.ready,"retry after damage"); }
		{ Bench b; auto v=phoenix::stream(); phoenix::record(v,0x14,0x02400000,{0}); b.download(1,v);
		  CHECK(b.t.errors && b.notes[1]==1,"C: record rejected"); CHECK_EQ(b.cs1[0x400000],0x69,"C: guard"); }
		{ Bench b; auto v=phoenix::stream(); size_t h=v.size(); phoenix::record(v,0x14,0x100,{1,2}); v[h+9]^=1;
		  b.download(1,v); CHECK(b.t.errors==1 && b.notes[1]==1,"bad header checksum counted"); }
		{ Bench b; auto v=phoenix::stream(); phoenix::record(v,0x21,0x200,{1,2},true);
		  b.download(2,v); CHECK(b.t.errors==1 && b.notes[1]==1,"bad 21 data checksum counted"); }
		{ Bench b; auto v=phoenix::mcu(); v.resize(v.size()-3); b.download(1,v); CHECK(b.notes[1]==1,"truncated data rejected"); }
		{ Bench b; auto v=phoenix::stream(); v[8]=99; b.download(1,v); CHECK(b.notes[1]==1,"truncated token count rejected"); }
	}
	return sim::finish("phoenix_load");
}
