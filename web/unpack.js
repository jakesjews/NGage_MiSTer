// SPDX-License-Identifier: GPL-2.0-or-later
//
// Finds the two flash files the N-Gage QD core boots from, the firmware
// (RH2941.0C1, firmware 4.10) and one of its language packs, in what Nokia's
// service software shipped them in, and returns them as boot0.rom and
// boot1.rom. Everything happens on the bytes handed in; nothing is sent
// anywhere.
//
// It takes, in the order a person is likely to have them:
//   - N-GageQD RH-29.zip, the archive of every data package for the phone
//     (the package for 4.10 is picked out of it);
//   - one data package for firmware 4.10;
//   - one of the two flash files themselves.
//
// A data package is a Windows program with a Microsoft cabinet (MSZIP)
// appended. The cabinet holds an InstallShield cabinet (data1.hdr, data1.cab,
// data2.cab) whose files are stored as chunks of raw deflate, each inflated
// on its own. Next to the flash files it has one .ini a product (a country
// or operator variant), which names that product's language pack.
(function (root) {
	'use strict';

	// The package the core was brought up with; in the zip it is tried first.
	const PACKAGE = {
		name: 'RH-29_dp_emea_v_3_0_mcusw4_10-Oct19-151031.exe',
		size: 63836160,
		sha256: '2f8c8d66177aaf4f8321c14607c991691e15490dc7887a749c5764c54fc1eee5',
	};
	const ARCHIVE = { name: 'N-GageQD RH-29.zip', size: 811528203 };

	// The firmware file is one exact file: the core's patches and its
	// integrity digest are made for it.
	const FIRMWARE = {
		source: 'RH2941.0C1', save: 'boot0.rom', what: 'Firmware',
		sha256: '3ce529d6fbcd6db1f4290fabe8b70c62242a23444c4fa74caec42657d12ab4a0',
	};
	// A language pack is taken when the core's loader will take it, which it
	// decides by what the pack writes into the first 64 KB of flash
	// (rtl/mister/phoenix_load.sv): its own entry in the integrity table and
	// the digest it carries for the 4.10 firmware file. Any of 4.10's packs
	// has both. PACK is the one the core was brought up with: it is taken
	// when a package has it, and held to its hash as well.
	const PACK = {
		source: 'RH2941.021', save: 'boot1.rom', what: 'Language pack',
		sha256: '657c2d1bafbad6797732c86892999a9e201e10961ee8c1801b0b6cc73bb41fa5',
	};
	const PREFERRED = PACK.source.toLowerCase();
	const DIGEST = 'be87bc4467bc4c53f6de1ee8d80d9285';                       // CS0 0x8F20
	// RH29vv.xxx: vv is the firmware version (41 = 4.10, 46 = 4.60)
	const FLASH_NAME = /^rh29(\d)(\d)\.([0-9a-z]{3})$/i;

	class UnpackError extends Error {
		constructor(code, detail) {
			super(detail || code);
			this.name = 'UnpackError';
			this.code = code; // not-package, other-version, no-pack, damaged, unsupported, mismatch
			// (no-pack: the firmware file without a language pack for it)
			this.version = null; // other-version: the firmware version found, when known
		}
	}
	const damaged = (what) => new UnpackError('damaged', what);

	// ---------------------------------------------------------------- deflate

	const LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
	const LEXT = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
	const DBASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
	const DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
	const ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

	// A canonical Huffman code as counts per length and the symbols in order.
	function huffman(lengths, from, n) {
		const count = new Uint16Array(16);
		const symbol = new Uint16Array(n);
		const next = new Uint16Array(16);
		for (let i = 0; i < n; i++) count[lengths[from + i]]++;
		for (let len = 1; len < 15; len++) next[len + 1] = next[len] + count[len];
		for (let i = 0; i < n; i++) {
			const len = lengths[from + i];
			if (len) symbol[next[len]++] = i;
		}
		return { count, symbol };
	}

	let fixedCodes = null;
	function fixed() {
		if (!fixedCodes) {
			const l = new Uint8Array(288 + 30);
			l.fill(8, 0, 144); l.fill(9, 144, 256); l.fill(7, 256, 280); l.fill(8, 280, 288);
			l.fill(5, 288, 318);
			fixedCodes = { len: huffman(l, 0, 288), dist: huffman(l, 288, 30) };
		}
		return fixedCodes;
	}

	// Inflates one raw deflate stream from src[pos, end) into out at op. A
	// match may reach back as far as out[floor]: the blocks of a cabinet folder
	// share their history, the chunks of an InstallShield file do not.
	// Returns the position after the output.
	function inflate(src, pos, end, out, op, floor) {
		let hold = 0, have = 0;

		function bits(n) {
			while (have < n) {
				if (pos >= end) throw damaged('deflate data ends early');
				hold |= src[pos++] << have;
				have += 8;
			}
			const v = hold & ((1 << n) - 1);
			hold >>>= n;
			have -= n;
			return v;
		}
		function decode(code) {
			const count = code.count;
			let c = 0, first = 0, index = 0;
			for (let len = 1; len <= 15; len++) {
				if (have === 0) {
					if (pos >= end) throw damaged('deflate data ends early');
					hold = src[pos++];
					have = 8;
				}
				c |= hold & 1;
				hold >>>= 1;
				have--;
				const n = count[len];
				if (c - n < first) return code.symbol[index + (c - first)];
				index += n;
				first = (first + n) << 1;
				c <<= 1;
			}
			throw damaged('bad deflate code');
		}

		let last;
		do {
			last = bits(1);
			const type = bits(2);
			if (type === 0) {
				hold = 0; have = 0;
				if (pos + 4 > end) throw damaged('deflate data ends early');
				const len = src[pos] | (src[pos + 1] << 8);
				const nlen = src[pos + 2] | (src[pos + 3] << 8);
				pos += 4;
				if ((len ^ 0xFFFF) !== nlen || pos + len > end || op + len > out.length)
					throw damaged('bad stored block');
				out.set(src.subarray(pos, pos + len), op);
				pos += len;
				op += len;
			} else if (type === 3) {
				throw damaged('bad deflate block');
			} else {
				let lenCode, distCode;
				if (type === 1) {
					lenCode = fixed().len;
					distCode = fixed().dist;
				} else {
					const nlen = bits(5) + 257, ndist = bits(5) + 1, ncode = bits(4) + 4;
					if (nlen > 286 || ndist > 30) throw damaged('bad deflate header');
					const cl = new Uint8Array(19);
					for (let i = 0; i < ncode; i++) cl[ORDER[i]] = bits(3);
					const clCode = huffman(cl, 0, 19);
					const l = new Uint8Array(nlen + ndist);
					for (let i = 0; i < nlen + ndist;) {
						const sym = decode(clCode);
						if (sym < 16) {
							l[i++] = sym;
						} else {
							let prev = 0, rep;
							if (sym === 16) {
								if (i === 0) throw damaged('bad deflate header');
								prev = l[i - 1];
								rep = 3 + bits(2);
							} else if (sym === 17) {
								rep = 3 + bits(3);
							} else {
								rep = 11 + bits(7);
							}
							if (i + rep > nlen + ndist) throw damaged('bad deflate header');
							while (rep--) l[i++] = prev;
						}
					}
					if (l[256] === 0) throw damaged('bad deflate header');
					lenCode = huffman(l, 0, nlen);
					distCode = huffman(l, nlen, ndist);
				}
				for (;;) {
					let sym = decode(lenCode);
					if (sym < 256) {
						if (op >= out.length) throw damaged('more data than expected');
						out[op++] = sym;
					} else if (sym === 256) {
						break;
					} else {
						sym -= 257;
						if (sym >= 29) throw damaged('bad deflate code');
						const len = LBASE[sym] + bits(LEXT[sym]);
						const ds = decode(distCode);
						if (ds >= 30) throw damaged('bad deflate code');
						const dist = DBASE[ds] + bits(DEXT[ds]);
						if (dist > op - floor || op + len > out.length) throw damaged('bad deflate match');
						if (dist >= len) {
							out.copyWithin(op, op - dist, op - dist + len);
							op += len;
						} else {
							for (let k = 0; k < len; k++, op++) out[op] = out[op - dist];
						}
					}
				}
			}
		} while (!last);
		return op;
	}

	// ------------------------------------------------------ Microsoft cabinet

	const view = (b) => new DataView(b.buffer, b.byteOffset, b.byteLength);
	const pause = () => new Promise((resolve) => setTimeout(resolve, 0));

	function cstring(b, p) {
		let e = p;
		while (e < b.length && b[e] !== 0) e++;
		if (e >= b.length) throw damaged('name runs off the end');
		let s = '';
		for (let i = p; i < e; i++) s += String.fromCharCode(b[i]);
		return { text: s, next: e + 1 };
	}

	// The cabinet appended to the program: 'MSCF', version 1.3, and a size
	// that fits in what is left of the file.
	function findCabinet(b) {
		const dv = view(b);
		for (let p = 0; p + 36 <= b.length; p++) {
			if (b[p] !== 0x4D || b[p + 1] !== 0x53 || b[p + 2] !== 0x43 || b[p + 3] !== 0x46) continue;
			if (dv.getUint32(p + 4, true) !== 0) continue;
			const size = dv.getUint32(p + 8, true);
			if (size < 36 || b[p + 24] !== 3 || b[p + 25] !== 1) continue;
			return { at: p, cut: p + size > b.length };
		}
		return null;
	}

	// Returns the cabinet's files as { name: Uint8Array }.
	async function readCabinet(b, at, progress) {
		const dv = view(b);
		const coffFiles = dv.getUint32(at + 16, true);
		const cFolders = dv.getUint16(at + 26, true);
		const cFiles = dv.getUint16(at + 28, true);
		const flags = dv.getUint16(at + 30, true);
		let p = at + 36, reserveFolder = 0, reserveData = 0;
		if (flags & 4) {
			const reserveHeader = dv.getUint16(p, true);
			reserveFolder = b[p + 2];
			reserveData = b[p + 3];
			p += 4 + reserveHeader;
		}
		if (flags & 1) { p = cstring(b, p).next; p = cstring(b, p).next; }
		if (flags & 2) { p = cstring(b, p).next; p = cstring(b, p).next; }

		const folders = [];
		for (let i = 0; i < cFolders; i++) {
			if (p + 8 > b.length) throw damaged('cabinet header ends early');
			folders.push({
				first: at + dv.getUint32(p, true),
				blocks: dv.getUint16(p + 4, true),
				type: dv.getUint16(p + 6, true) & 0x0F,
				data: null,
			});
			p += 8 + reserveFolder;
		}

		const entries = [];
		p = at + coffFiles;
		for (let i = 0; i < cFiles; i++) {
			if (p + 16 > b.length) throw damaged('cabinet header ends early');
			const size = dv.getUint32(p, true);
			const offset = dv.getUint32(p + 4, true);
			const folder = dv.getUint16(p + 8, true);
			const name = cstring(b, p + 16);
			p = name.next;
			entries.push({ name: name.text.replace(/^.*[\\/]/, '').toLowerCase(), size, offset, folder });
		}

		const wanted = entries.filter((e) => /^data\d+\.(hdr|cab)$/.test(e.name));
		const total = wanted.reduce((n, e) => (folders[e.folder] && !folders[e.folder].counted
			? (folders[e.folder].counted = true, n + folders[e.folder].blocks) : n), 0);
		let done = 0;

		for (const e of wanted) {
			const f = folders[e.folder];
			if (!f) throw damaged('cabinet names a folder it does not have');
			if (f.data) continue;
			if (f.type !== 0 && f.type !== 1) throw new UnpackError('unsupported', 'cabinet compression ' + f.type);
			// sizes first, then the data
			let q = f.first, size = 0;
			for (let i = 0; i < f.blocks; i++) {
				if (q + 8 > b.length) throw damaged('cabinet data ends early');
				size += dv.getUint16(q + 6, true);
				q += 8 + reserveData + dv.getUint16(q + 4, true);
			}
			if (q > b.length) throw damaged('cabinet data ends early');
			const out = new Uint8Array(size);
			let op = 0;
			q = f.first;
			for (let i = 0; i < f.blocks; i++) {
				const packed = dv.getUint16(q + 4, true);
				const plain = dv.getUint16(q + 6, true);
				q += 8 + reserveData;
				if (f.type === 0) {
					out.set(b.subarray(q, q + plain), op);
				} else {
					if (b[q] !== 0x43 || b[q + 1] !== 0x4B) throw damaged('cabinet block without its mark');
					if (inflate(b, q + 2, q + packed, out, op, 0) !== op + plain) throw damaged('cabinet block of the wrong size');
				}
				op += plain;
				q += packed;
				if ((++done & 15) === 0) {
					progress(done / total);
					await pause();
				}
			}
			f.data = out;
		}

		const files = {};
		for (const e of wanted) {
			const data = folders[e.folder].data;
			if (e.offset + e.size > data.length) throw damaged('cabinet file runs off its folder');
			files[e.name] = data.subarray(e.offset, e.offset + e.size);
		}
		return files;
	}

	// -------------------------------------------------- InstallShield cabinet

	// The file descriptors of data1.hdr (format versions 6 and later).
	function readDescriptors(hdr) {
		const dv = view(hdr);
		if (hdr.length < 20 || dv.getUint32(0, true) !== 0x28635349) throw damaged('data1.hdr is not an InstallShield header');
		const version = dv.getUint32(4, true);
		let major = 0;
		if (version >>> 24 === 1) major = (version >>> 12) & 0x0F;
		else if (version >>> 24 === 2 || version >>> 24 === 4) major = Math.floor((version & 0xFFFF) / 100);
		if (major < 6) throw new UnpackError('unsupported', 'InstallShield format ' + major);
		const cd = dv.getUint32(12, true);
		if (cd + 0x30 > hdr.length) throw damaged('data1.hdr ends early');
		const table = cd + dv.getUint32(cd + 0x0C, true);
		const count = dv.getUint32(cd + 0x28, true);
		const first = table + dv.getUint32(cd + 0x2C, true);
		const list = [];
		for (let i = 0; i < count; i++) {
			const p = first + i * 0x57;
			if (p + 0x57 > hdr.length) throw damaged('data1.hdr ends early');
			const nameAt = dv.getUint32(p + 58, true);
			if (dv.getUint32(p + 6, true) || dv.getUint32(p + 14, true) || dv.getUint32(p + 22, true)) continue; // over 4 GB
			list.push({
				name: nameAt ? cstring(hdr, table + nameAt).text : '',
				flags: dv.getUint16(p, true),
				size: dv.getUint32(p + 2, true),
				packed: dv.getUint32(p + 10, true),
				offset: dv.getUint32(p + 18, true),
				volume: dv.getUint16(p + 85, true),
			});
		}
		return list;
	}

	async function readFile(d, volumes, progress) {
		const vol = volumes['data' + d.volume + '.cab'];
		if (!vol) throw damaged('data' + d.volume + '.cab is missing');
		if (d.flags & 3) throw new UnpackError('unsupported', 'split or scrambled file'); // FILE_SPLIT, FILE_OBFUSCATED
		if (d.offset + d.packed > vol.length) throw damaged(d.name + ' runs off its cabinet');
		const out = new Uint8Array(d.size);
		if (!(d.flags & 4)) { // not FILE_COMPRESSED
			out.set(vol.subarray(d.offset, d.offset + d.size));
			return out;
		}
		const end = d.offset + d.packed;
		let p = d.offset, op = 0, n = 0;
		while (p < end) {
			if (p + 2 > end) throw damaged(d.name + ' ends early');
			const len = vol[p] | (vol[p + 1] << 8);
			p += 2;
			if (p + len > end) throw damaged(d.name + ' ends early');
			op = inflate(vol, p, p + len, out, op, op);
			p += len;
			if ((++n & 15) === 0) {
				progress((p - d.offset) / d.packed);
				await pause();
			}
		}
		if (op !== d.size) throw damaged(d.name + ' has the wrong size');
		return out;
	}

	// ------------------------------------------------------------ flash files

	// The bytes a Phoenix flash file writes to CS0 0x0000-0xFFFF, with every
	// flash record's checksums verified on the way (the file starts with A2,
	// a token block, then records; rtl/mister/phoenix_load.sv reads the same).
	// A record's data sums to its check byte in one of two ways, one apart;
	// a file keeps to one of them, which is held here so that an error of
	// one in a byte does not pass as the other way.
	function firstBlock(bytes) {
		if (bytes.length < 9 || bytes[0] !== 0xA2) throw damaged('not a flash file');
		const dv = view(bytes);
		const block = new Uint8Array(0x10000).fill(0xFF);
		let way = -1;
		let p = 5 + dv.getUint32(1, false);
		if (p > bytes.length) throw damaged('the flash file ends in its header');
		while (p < bytes.length) {
			const type = bytes[p];
			let head, at = -1, len = 0, addr = -1;
			switch (type) {
				case 0x14: head = 10; at = p + 1; break;
				case 0x21: head = 16; at = p + 7; break;
				case 0x2E: head = 10; len = -1; break;
				case 0x20: head = 6; break;
				case 0x25: head = 2; break;
				case 0x26: head = 10; break;
				default: throw damaged('unknown record in the flash file');
			}
			if (p + head > bytes.length) throw damaged('the flash file ends in a record');
			if (at >= 0) {
				// address, data checksum, length, header checksum
				addr = dv.getUint32(at, false);
				len = (bytes[at + 5] << 16) | (bytes[at + 6] << 8) | bytes[at + 7];
				let sum = 0;
				for (let i = at; i < at + 8; i++) sum += bytes[i];
				if (((~sum) & 0xFF) !== bytes[at + 8]) throw damaged('a record header does not add up');
			} else if (len === -1) {
				len = (bytes[p + 6] << 16) | (bytes[p + 7] << 8) | bytes[p + 8];
			} else if (type === 0x20) {
				len = dv.getUint16(p + 3, false);
			} else if (type === 0x25) {
				len = bytes[p + 1];
			}
			const data = p + head;
			if (data + len > bytes.length) throw damaged('the flash file ends in a record');
			if (at >= 0 && len) {
				let sum = 0;
				for (let i = data; i < data + len; i++) sum += bytes[i];
				const off = (bytes[at + 4] + sum) & 0xFF;   // FF: complement, 00: one more
				if ((off !== 0xFF && off !== 0) || (way >= 0 && off !== way)) throw damaged('a record does not add up');
				way = off;
				if (addr < 0x10000) block.set(bytes.subarray(data, data + Math.min(len, 0x10000 - addr)), addr);
			}
			p = data + len;
		}
		return block;
	}

	// Is this flash file a language pack the core's loader takes?
	function isPack(bytes) {
		const block = firstBlock(bytes);
		if (block.subarray(0x8F10, 0x8F18).every((v) => v === 0xFF)) return false;
		return Array.from(block.subarray(0x8F20, 0x8F30), (x) => x.toString(16).padStart(2, '0')).join('') === DIGEST;
	}

	async function sha256(bytes) {
		const digest = await root.crypto.subtle.digest('SHA-256', bytes);
		return Array.from(new Uint8Array(digest), (x) => x.toString(16).padStart(2, '0')).join('');
	}

	const version = (name) => { const m = FLASH_NAME.exec(name); return m ? m[1] + '.' + m[2] + '0' : null; };
	function otherVersion(found, detail) {
		const e = new UnpackError('other-version', detail);
		e.version = found || null;
		return e;
	}

	// One of the two flash files, by itself: the firmware by its hash, a
	// language pack by what it writes.
	async function flashFile(bytes, name) {
		const hash = await sha256(bytes);
		if (hash === FIRMWARE.sha256) return { ...FIRMWARE, bytes, variant: '' };
		const base = (name || '').replace(/^.*[\\/]/, '');
		if (/\.0c1$/i.test(base) || !isPack(bytes)) {
			const v = version(base);
			throw otherVersion(v === '4.10' ? null : v, 'a flash file, but not the 4.10 firmware file or a language pack for it');
		}
		if (base.toLowerCase() === PREFERRED && hash !== PACK.sha256) throw damaged(PACK.source + ' is not as Nokia shipped it');
		return { ...PACK, source: FLASH_NAME.test(base) ? base.toUpperCase() : 'a 4.10 language pack', sha256: hash, bytes, variant: '' };
	}

	// --------------------------------------------------------- a data package

	const text = (b) => { let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return s; };

	// What a package holds for the phone, without unpacking the flash files:
	// { firmware: [names], packs: [{ name, variants: [descriptions] }], parts, descriptors }
	async function contents(bytes, progress) {
		const cab = findCabinet(bytes);
		if (!cab) throw new UnpackError('not-package', 'no cabinet in the file');
		if (cab.cut) throw damaged('the file is shorter than its cabinet');
		const parts = await readCabinet(bytes, cab.at, progress);
		if (!parts['data1.hdr']) throw new UnpackError('not-package', 'no InstallShield data in the cabinet');
		const descriptors = readDescriptors(parts['data1.hdr']).filter((d) => !(d.flags & 8)); // FILE_INVALID
		const flash = descriptors.filter((d) => FLASH_NAME.test(d.name));
		// the products' .ini files: which pack belongs to which variant
		const variants = {};
		for (const d of descriptors) {
			if (!/^\d+\.ini$/i.test(d.name) || d.size > 65536) continue;
			const ini = text(await readFile(d, parts, () => {}));
			const pack = /^\s*PpmId\s*=\s*(\S+)/im.exec(ini);
			const what = /^\s*Description\s*=\s*(.+?)\s*$/im.exec(ini);
			if (!pack || !what) continue;
			const list = variants[pack[1].toLowerCase()] || (variants[pack[1].toLowerCase()] = []);
			if (!list.includes(what[1])) list.push(what[1]);
		}
		const byName = (a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase());
		return {
			parts, descriptors,
			firmware: flash.filter((d) => /\.0c1$/i.test(d.name)).sort(byName),
			packs: flash.filter((d) => !/\.0c1$/i.test(d.name)).sort(byName)
				.map((d) => ({ d, name: d.name, variants: variants[d.name.toLowerCase()] || [] })),
		};
	}

	// The order in which a package's language packs are tried: the one the
	// core was brought up with, then English-speaking countries' variants,
	// then other variants with English in their name, then the rest by name.
	function packOrder(packs) {
		const rank = (p) => {
			if (p.name.toLowerCase() === PREFERRED) return 0;
			const v = p.variants.join(' / ');
			if (/\b(UK|Ireland|Australia|New Zealand)\b/i.test(v)) return 1;
			if (/\b(English|Euro ?1)\b/i.test(v)) return 2;
			return v ? 3 : 4;
		};
		return packs.map((p, i) => ({ p, r: rank(p), i })).sort((a, b) => a.r - b.r || a.i - b.i).map((x) => x.p);
	}

	async function fromPackage(bytes, progress) {
		const c = await contents(bytes, (f) => progress(0.4 * f));
		const fw = c.firmware.find((d) => d.name.toLowerCase() === FIRMWARE.source.toLowerCase());
		if (!fw) {
			const found = c.firmware.map((d) => version(d.name)).filter(Boolean);
			if (!c.firmware.length && !c.packs.length) throw new UnpackError('not-package', 'no N-Gage QD flash files in the package');
			throw otherVersion(found[0], c.firmware.length ? 'the firmware file is ' + c.firmware.map((d) => d.name).join(', ')
				: 'language packs only, no firmware file');
		}
		const mine = c.packs.filter((p) => version(p.name) === '4.10');

		const firmware = await readFile(fw, c.parts, (f) => progress(0.4 + 0.5 * f));
		const hash = await sha256(firmware);
		if (hash !== FIRMWARE.sha256) throw new UnpackError('mismatch', fw.name + ' is not the 4.10 firmware file the core is made for');

		for (const p of packOrder(mine)) {
			const pack = await readFile(p.d, c.parts, (f) => progress(0.9 + 0.1 * f));
			if (!isPack(pack)) continue;
			const packHash = await sha256(pack);
			if (p.name.toLowerCase() === PREFERRED && packHash !== PACK.sha256) throw damaged(p.name + ' is not as Nokia shipped it');
			progress(1);
			return [
				{ ...FIRMWARE, bytes: firmware, variant: '' },
				{ ...PACK, source: p.name.toUpperCase(), sha256: packHash, bytes: pack, variant: p.variants.join(', ') },
			];
		}
		throw new UnpackError('no-pack', 'the firmware file, but no language pack for it');
	}

	// ------------------------------------------------------------- a zip file

	// Something to read ranges from: bytes in memory or a File / Blob.
	function reader(source) {
		if (source instanceof Uint8Array) return { size: source.length, read: async (a, b) => source.subarray(a, b) };
		return { size: source.size, read: async (a, b) => new Uint8Array(await source.slice(a, b).arrayBuffer()) };
	}

	// The members of a zip (no zip64, no encryption): [{ name, method, packed, size, at }].
	async function zipMembers(r) {
		const tailAt = Math.max(0, r.size - 65557);
		const tail = await r.read(tailAt, r.size);
		let e = tail.length - 22;
		while (e >= 0 && !(tail[e] === 0x50 && tail[e + 1] === 0x4B && tail[e + 2] === 5 && tail[e + 3] === 6)) e--;
		if (e < 0) throw damaged('the zip file has no directory: it is cut short');
		const end = view(tail);
		const count = end.getUint16(e + 10, true), size = end.getUint32(e + 12, true), at = end.getUint32(e + 16, true);
		if (at === 0xFFFFFFFF || count === 0xFFFF) throw new UnpackError('unsupported', 'a zip64 archive');
		if (at + size > r.size) throw damaged('the zip file is cut short');
		const cd = await r.read(at, at + size);
		const dv = view(cd);
		const list = [];
		for (let p = 0, i = 0; i < count; i++) {
			if (p + 46 > cd.length || dv.getUint32(p, true) !== 0x02014B50) throw damaged('the zip directory is damaged');
			const n = dv.getUint16(p + 28, true);
			list.push({
				name: text(cd.subarray(p + 46, p + 46 + n)),
				flags: dv.getUint16(p + 8, true),
				method: dv.getUint16(p + 10, true),
				packed: dv.getUint32(p + 20, true),
				size: dv.getUint32(p + 24, true),
				at: dv.getUint32(p + 42, true),
			});
			p += 46 + n + dv.getUint16(p + 30, true) + dv.getUint16(p + 32, true);
		}
		return list;
	}

	async function zipMember(r, m, progress) {
		if (m.flags & 1) throw new UnpackError('unsupported', 'an encrypted zip');
		if (m.method !== 0 && m.method !== 8) throw new UnpackError('unsupported', 'zip compression ' + m.method);
		const head = await r.read(m.at, m.at + 30);
		if (head.length < 30 || view(head).getUint32(0, true) !== 0x04034B50) throw damaged('the zip file is damaged');
		const data = m.at + 30 + view(head).getUint16(26, true) + view(head).getUint16(28, true);
		if (data + m.packed > r.size) throw damaged('the zip file is cut short');
		progress(0);
		const packed = await r.read(data, data + m.packed);
		if (m.method === 0) return packed;
		const out = new Uint8Array(m.size);
		await pause();
		if (inflate(packed, 0, packed.length, out, 0, 0) !== m.size) throw damaged(m.name + ' has the wrong size');
		progress(1);
		return out;
	}

	// The archive of the phone's data packages: the package the core was
	// brought up with first, then the others named for 4.10, then the rest.
	async function fromZip(r, progress) {
		const base = (m) => m.name.replace(/^.*[\\/]/, '');
		const members = (await zipMembers(r)).filter((m) => /\.exe$/i.test(m.name) && m.size > 0);
		if (!members.length) throw new UnpackError('not-package', 'no data package in the zip file');
		const rank = (m) => (base(m).toLowerCase() === PACKAGE.name.toLowerCase() ? 0 : /4_10/i.test(base(m)) ? 1 : 2);
		members.sort((a, b) => rank(a) - rank(b) || base(a).localeCompare(base(b)));
		let other = null;
		for (const m of members) {
			try {
				const bytes = await zipMember(r, m, (f) => progress(0.3 * f));
				const out = await fromPackage(bytes, (f) => progress(0.3 + 0.7 * f));
				out.forEach((f) => { f.from = base(m); });
				return out;
			} catch (e) {
				// a package for another version or of another kind: try the next
				if (!(e instanceof UnpackError) || (e.code !== 'other-version' && e.code !== 'not-package')) throw e;
				if (e.code === 'other-version' && !other) other = e;
			}
		}
		throw other || new UnpackError('not-package', 'no data package for the N-Gage QD in the zip file');
	}

	// ---------------------------------------------------------------- results

	// Takes a dropped file (a File or Blob, or its bytes) and its name.
	// Returns the flash files found: [{ source, save, what, variant, bytes,
	// sha256, from }]. The zip and a data package give both; one of the flash
	// files gives that one back. Throws UnpackError.
	async function unpack(source, progress, name) {
		progress = progress || (() => {});
		const r = reader(source);
		const head = await r.read(0, Math.min(4, r.size));
		if (head.length === 4 && head[0] === 0x50 && head[1] === 0x4B && head[2] === 3 && head[3] === 4)
			return fromZip(r, progress);
		const bytes = await r.read(0, r.size);
		// One of the two flash files, already unpacked. They start with A2.
		if (bytes.length && bytes[0] === 0xA2) return [await flashFile(bytes, name)];
		return fromPackage(bytes, progress);
	}

	const api = { unpack, contents, sha256, UnpackError, PACKAGE, ARCHIVE, FIRMWARE, PACK };
	if (typeof module !== 'undefined' && module.exports) module.exports = api;
	else root.NGageUnpack = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
