// SPDX-License-Identifier: GPL-2.0-or-later
//
// Checks web/unpack.js against the real data package:
//   node web/test.mjs RH-29_dp_emea_v_10_0_MCUSW4_60.exe [RH2946.0C1 RH2946.0S5]
// The package must give the two 4.60 files; damaged and foreign input must be
// refused. With the two flash files given, they must be recognised as well.
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const { unpack, sha256, PACKAGE, KNOWN } = createRequire(import.meta.url)('./unpack.js');
const [packagePath, ...flashPaths] = process.argv.slice(2);
if (!packagePath) {
	console.error('usage: node web/test.mjs PACKAGE.exe [RH2946.0C1 RH2946.0S5]');
	process.exit(2);
}

let failed = 0;
const check = (ok, what) => {
	console.log((ok ? 'ok    ' : 'FAIL  ') + what);
	if (!ok) failed++;
};
const refused = async (bytes, code, what) => {
	try {
		await unpack(bytes);
		check(false, what + ': accepted');
	} catch (e) {
		const ok = [].concat(code).includes(e.code);
		check(ok, what + ': refused as "' + e.code + '"' + (ok ? '' : ', expected "' + code + '" (' + e.message + ')'));
	}
};

const pkg = new Uint8Array(readFileSync(packagePath));
check(pkg.length === PACKAGE.size && await sha256(pkg) === PACKAGE.sha256, 'the input is the 4.60 data package');

let last = -1, steps = 0, ordered = true;
const t0 = performance.now();
const files = await unpack(pkg, (f) => { if (f < last) ordered = false; last = f; steps++; });
const ms = Math.round(performance.now() - t0);
check(files.length === 2, 'two files come out (' + ms + ' ms)');
check(ordered && last === 1 && steps > 10, 'progress runs up to 1 (' + steps + ' steps)');
for (const [hash, k] of Object.entries(KNOWN)) {
	const f = files.find((x) => x.save === k.save);
	check(!!f && f.sha256 === hash && f.source === k.source, k.save + ' is ' + k.source + ', ' + (f ? f.bytes.length : 0) + ' bytes, SHA-256 matches');
}

await refused(pkg.subarray(0, pkg.length - 4096), 'damaged', 'a package cut short');
const flipped = pkg.slice();
flipped[6000000] ^= 0x10;
await refused(flipped, ['damaged', 'mismatch'], 'a package with one bit changed');
await refused(new Uint8Array(4096), 'not-package', 'a file of zeros');
await refused(pkg.subarray(0, 200000), 'not-package', 'the program without its cabinet');
await refused(new Uint8Array([0xA2, 0, 0, 0, 1, 2, 3]), 'other-version', 'some other flash file');

for (const path of flashPaths) {
	const out = await unpack(new Uint8Array(readFileSync(path)));
	check(out.length === 1 && !!KNOWN[out[0].sha256], path.replace(/^.*\//, '') + ' alone is recognised as ' + (out[0] && out[0].save));
}

console.log(failed ? failed + ' check(s) failed' : 'all checks passed');
process.exit(failed ? 1 : 0);
