// SPDX-License-Identifier: GPL-2.0-or-later
//
// Checks web/unpack.js against the real files:
//   node web/test.mjs RH-29_dp_emea_v_3_0_mcusw4_10-Oct19-151031.exe [MORE...]
// The package must give the two 4.10 files; damaged and foreign input must be
// refused; zip files made from the package here must be read. MORE is any of
//   N-GageQD RH-29.zip          must give the same two files
//   other data packages (.exe)  what each gives or why it is refused is
//                               printed; a result must be the 4.10 firmware
//                               file with a language pack for it
//   flash files                 the 4.10 firmware file and any 4.10 language
//                               pack must be recognised, others refused
import { readFileSync, openSync, readSync, fstatSync, closeSync } from 'node:fs';
import { createRequire } from 'node:module';

const { unpack, sha256, PACKAGE, ARCHIVE, FIRMWARE, PACK } = createRequire(import.meta.url)('./unpack.js');
const [packagePath, ...more] = process.argv.slice(2);
if (!packagePath) {
	console.error('usage: node web/test.mjs PACKAGE.exe [N-GageQD RH-29.zip] [other packages] [flash files]');
	process.exit(2);
}
const PACK_SHA256 = PACK.sha256;

let failed = 0;
const check = (ok, what) => {
	console.log((ok ? 'ok    ' : 'FAIL  ') + what);
	if (!ok) failed++;
};
const refused = async (source, code, what, name) => {
	try {
		await unpack(source, null, name);
		check(false, what + ': accepted');
	} catch (e) {
		const ok = [].concat(code).includes(e.code);
		check(ok, what + ': refused as "' + e.code + '"' + (e.version ? ' (' + e.version + ')' : '') + (ok ? ', ' + e.message : ', expected "' + code + '" (' + e.message + ')'));
	}
};
const pair = (files, what) => {
	const fw = files.find((x) => x.save === 'boot0.rom'), lp = files.find((x) => x.save === 'boot1.rom');
	check(files.length === 2 && !!fw && fw.sha256 === FIRMWARE.sha256 && fw.source === FIRMWARE.source,
		what + ': boot0.rom is ' + FIRMWARE.source + ', ' + (fw ? fw.bytes.length : 0) + ' bytes, SHA-256 matches');
	check(!!lp && lp.sha256 === PACK_SHA256 && lp.source === PACK.source,
		what + ': boot1.rom is ' + (lp ? lp.source + ' (' + lp.variant + '), ' + lp.bytes.length : 0) + ' bytes, SHA-256 matches');
};
// A File-like source that reads from disk in pieces, as the page reads a dropped file.
const fileSource = (path) => {
	const fd = openSync(path, 'r');
	return {
		size: fstatSync(fd).size,
		slice: (a, b) => ({ arrayBuffer: async () => { const buf = Buffer.alloc(b - a); readSync(fd, buf, 0, b - a, a); return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length); } }),
		close: () => closeSync(fd),
	};
};
// A zip of stored members: [[name, bytes], ...] (no checksums: the reader does not use them).
const zip = (members) => {
	const parts = [], dir = [];
	let at = 0;
	const u16 = (n) => [n & 255, n >> 8], u32 = (n) => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
	for (const [name, bytes] of members) {
		const n = Array.from(name, (c) => c.charCodeAt(0));
		const local = Uint8Array.from([0x50, 0x4B, 3, 4, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, ...u32(0), ...u32(bytes.length), ...u32(bytes.length), ...u16(n.length), 0, 0, ...n]);
		dir.push(Uint8Array.from([0x50, 0x4B, 1, 2, 20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, ...u32(0), ...u32(bytes.length), ...u32(bytes.length), ...u16(n.length), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ...u32(at), ...n]));
		parts.push(local, bytes);
		at += local.length + bytes.length;
	}
	const size = dir.reduce((s, d) => s + d.length, 0);
	parts.push(...dir, Uint8Array.from([0x50, 0x4B, 5, 6, 0, 0, 0, 0, ...u16(dir.length), ...u16(dir.length), ...u32(size), ...u32(at), 0, 0]));
	const out = new Uint8Array(parts.reduce((s, x) => s + x.length, 0));
	let p = 0;
	for (const x of parts) { out.set(x, p); p += x.length; }
	return out;
};

const pkg = new Uint8Array(readFileSync(packagePath));
check(pkg.length === PACKAGE.size && await sha256(pkg) === PACKAGE.sha256, 'the input is the 4.10 data package');

let last = -1, steps = 0, ordered = true;
const t0 = performance.now();
const files = await unpack(pkg, (f) => { if (f < last) ordered = false; last = f; steps++; });
check(files.length === 2, 'two files come out (' + Math.round(performance.now() - t0) + ' ms)');
check(ordered && last === 1 && steps > 10, 'progress runs up to 1 (' + steps + ' steps)');
pair(files, 'the package');

await refused(pkg.subarray(0, pkg.length - 4096), 'damaged', 'a package cut short');
const flipped = pkg.slice();
flipped[54000000] ^= 0x10; // inside the firmware file's data
await refused(flipped, ['damaged', 'mismatch'], 'a package with one bit changed');
await refused(new Uint8Array(4096), 'not-package', 'a file of zeros');
await refused(pkg.subarray(0, 200000), 'not-package', 'the program without its cabinet');
await refused(new Uint8Array([0xA2, 0, 0, 0, 1, 2, 3]), ['other-version', 'damaged'], 'some other flash file');

// the two flash files by themselves, and one of them with a bit changed
for (const f of files) {
	const out = await unpack(f.bytes, null, f.source);
	check(out.length === 1 && out[0].save === f.save && out[0].sha256 === f.sha256, f.source + ' alone is recognised as ' + out[0].save);
}
const pack = files.find((x) => x.save === 'boot1.rom').bytes.slice();
pack[pack.length - 100] ^= 1;
await refused(pack, 'damaged', 'the language pack with one bit changed', PACK.source);
await refused(pack, 'damaged', 'the same under another name (its records no longer add up one way)', 'boot1.rom');

// zip files: the package under another name, behind a file that is no package
const other = new Uint8Array(3000).fill(7);
pair(await unpack(zip([['docs/readme.txt', other], ['some folder/renamed_4_10.exe', pkg]])), 'a zip holding the package');
pair(await unpack(zip([['a/not-a-package.exe', other], ['a/' + PACKAGE.name, pkg]])), 'a zip with another .exe before it');
await refused(zip([['readme.txt', other]]), 'not-package', 'a zip with no package in it');
await refused(zip([['x.exe', other]]), 'not-package', 'a zip whose .exe is no package');
const whole = zip([['p.exe', pkg]]);
await refused(whole.subarray(0, whole.length - 30), 'damaged', 'a zip cut short');

for (const path of more) {
	const name = path.replace(/^.*\//, '');
	if (/\.zip$/i.test(name)) {
		const src = fileSource(path);
		check(src.size === ARCHIVE.size, name + ' is ' + ARCHIVE.size + ' bytes');
		let peak = 0;
		const t = performance.now();
		const out = await unpack(src, (f) => { peak = Math.max(peak, f); });
		src.close();
		pair(out, name + ' (' + Math.round(performance.now() - t) + ' ms, read in pieces)');
		check(out.every((f) => f.from === PACKAGE.name) && peak === 1, name + ': taken from ' + out[0].from);
	} else if (/\.exe$/i.test(name)) {
		try {
			const out = await unpack(new Uint8Array(readFileSync(path)), null, name);
			const fw = out.find((x) => x.save === 'boot0.rom'), lp = out.find((x) => x.save === 'boot1.rom');
			check(out.length === 2 && !!fw && fw.sha256 === FIRMWARE.sha256 && !!lp && /^RH2941\.[0-9A-Z]{3}$/.test(lp.source),
				name + ': gives ' + FIRMWARE.source + ' and ' + (lp ? lp.source + ' (' + lp.variant + '), ' + lp.bytes.length + ' bytes' : 'nothing'));
			const again = await unpack(lp.bytes, null, lp.source);
			check(again.length === 1 && again[0].save === 'boot1.rom' && again[0].sha256 === lp.sha256, '  ' + lp.source + ' alone is recognised as boot1.rom');
		} catch (e) {
			const ok = ['other-version', 'no-pack'].includes(e.code);
			check(ok, name + ': refused as "' + e.code + '"' + (e.version ? ' (' + e.version + ')' : '') + ', ' + e.message);
		}
	} else {
		const bytes = new Uint8Array(readFileSync(path));
		try {
			const out = await unpack(bytes, null, name);
			check(out.length === 1 && out[0].sha256 === await sha256(bytes), name + ' alone is recognised as ' + out[0].save + (out[0].save === 'boot1.rom' ? ' (' + out[0].source + ')' : ''));
		} catch (e) {
			check(e.code === 'other-version', name + ': refused as "' + e.code + '"' + (e.version ? ' (' + e.version + ')' : '') + ', ' + e.message);
		}
	}
}

console.log(failed ? failed + ' check(s) failed' : 'all checks passed');
process.exit(failed ? 1 : 0);
