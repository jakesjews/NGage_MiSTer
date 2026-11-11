// SPDX-License-Identifier: GPL-2.0-or-later
//
// Reads Nokia's Phoenix data package for the N-Gage QD (RH-29, firmware 4.60)
// and returns the two flash files in it, which the core loads as boot0.rom
// and boot1.rom. Everything happens on the bytes handed in; nothing is sent
// anywhere.
//
// The package is a Windows program with a Microsoft cabinet (MSZIP) appended.
// The cabinet holds an InstallShield cabinet (data1.hdr, data1.cab, data2.cab)
// whose files are stored as chunks of raw deflate, each inflated on its own.
(function (root) {
	'use strict';

	const PACKAGE = {
		name: 'RH-29_dp_emea_v_10_0_MCUSW4_60.exe',
		size: 13445186,
		sha256: '2266f2905d12aab1eadc31eec1295c7bbabe02ce7f83750f5983c34a37a2efc9',
	};

	// The files the core accepts, by SHA-256.
	const KNOWN = {
		'ba5fea856d378f3e460d9daca11d3f1c254c0141c18c14b6498f348ba56d18f6':
			{ source: 'RH2946.0C1', save: 'boot0.rom', what: 'Firmware' },
		'4d2e36f61259b01f564bff89766c9af687f7c8c57248bda47e8776bd3cdc95f5':
			{ source: 'RH2946.0S5', save: 'boot1.rom', what: 'Language pack' },
	};
	const WANTED = Object.values(KNOWN).map((k) => k.source.toLowerCase());

	class UnpackError extends Error {
		constructor(code, detail) {
			super(detail || code);
			this.name = 'UnpackError';
			this.code = code; // not-package, other-version, damaged, unsupported, mismatch
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

	// ---------------------------------------------------------------- results

	async function sha256(bytes) {
		const digest = await root.crypto.subtle.digest('SHA-256', bytes);
		return Array.from(new Uint8Array(digest), (x) => x.toString(16).padStart(2, '0')).join('');
	}

	async function describe(bytes) {
		const hash = await sha256(bytes);
		return { bytes, sha256: hash, known: KNOWN[hash] || null };
	}

	// Takes the bytes of a dropped file. Returns the flash files in it:
	// [{ source, save, what, bytes, sha256 }]. The data package gives both;
	// one of the flash files itself gives that one back. Throws UnpackError.
	async function unpack(bytes, progress) {
		progress = progress || (() => {});

		// One of the two flash files, already unpacked. They start with A2.
		if (bytes.length && bytes[0] === 0xA2) {
			const f = await describe(bytes);
			if (!f.known) throw new UnpackError('other-version', 'a flash file, but not one of the 4.60 pair');
			return [{ ...f.known, bytes, sha256: f.sha256 }];
		}

		const cab = findCabinet(bytes);
		if (!cab) throw new UnpackError('not-package', 'no cabinet in the file');
		if (cab.cut) throw damaged('the file is shorter than its cabinet');
		const parts = await readCabinet(bytes, cab.at, (f) => progress(0.4 * f));
		if (!parts['data1.hdr']) throw new UnpackError('not-package', 'no InstallShield data in the cabinet');

		const descriptors = readDescriptors(parts['data1.hdr'])
			.filter((d) => !(d.flags & 8) && WANTED.includes(d.name.toLowerCase())); // FILE_INVALID
		if (descriptors.length !== WANTED.length) throw new UnpackError('other-version', 'no RH2946.0C1 and RH2946.0S5 in the package');

		const packed = descriptors.reduce((n, d) => n + d.packed, 0) || 1;
		const result = [];
		let before = 0;
		for (const d of descriptors) {
			const data = await readFile(d, parts, (f) => progress(0.4 + 0.6 * (before + f * d.packed) / packed));
			before += d.packed;
			const f = await describe(data);
			if (!f.known || f.known.source.toLowerCase() !== d.name.toLowerCase())
				throw new UnpackError('mismatch', d.name + ' is not the 4.60 file');
			result.push({ ...f.known, bytes: data, sha256: f.sha256 });
		}
		progress(1);
		return result.sort((a, b) => a.save.localeCompare(b.save));
	}

	const api = { unpack, sha256, UnpackError, PACKAGE, KNOWN };
	if (typeof module !== 'undefined' && module.exports) module.exports = api;
	else root.NGageUnpack = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
