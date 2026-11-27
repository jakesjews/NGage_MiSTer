// SPDX-License-Identifier: GPL-2.0-or-later
//
// The page around unpack.js: takes dropped or chosen files and, once it has
// the firmware file and a language pack, shows the two boot files made from
// them as cards and hands them out as downloads.
(function () {
	'use strict';

	const { unpack, images, PACKAGE, ARCHIVE, FIRMWARE, PACK } = window.NGageUnpack;
	const $ = (id) => document.getElementById(id);
	const status = $('status'), bar = $('bar'), input = $('file'), ask = $('ask');
	const cards = { 'boot0.rom': $('card0'), 'boot1.rom': $('card1') };
	const askText = ask.textContent;
	const count = (n) => n.toLocaleString('en-US');
	const have = {};                    // the flash files so far: firmware, pack
	let busy = false;

	function say(text, isError) {
		status.textContent = text;
		status.classList.toggle('is-error', !!isError);
	}

	function explain(error, name) {
		const want = 'Drop ' + ARCHIVE.name + ', or ' + PACKAGE.name + ' from it.';
		switch (error.code) {
			case 'not-package': return name + ' is not the firmware archive or a data package from it. ' + want;
			case 'other-version': return name + (error.version ? ' holds firmware ' + error.version + ', and the core runs 4.10 only. '
				: ' does not hold the firmware file for 4.10. ') + want;
			case 'no-pack': return name + ' holds the firmware file, but no language pack for it. ' + want;
			case 'damaged': return name + ' is cut short or damaged. Download it again: ' + ARCHIVE.name + ' is ' + count(ARCHIVE.size)
				+ ' bytes, the package ' + count(PACKAGE.size) + '.';
			case 'mismatch': return 'The firmware in ' + name + ' is not the 4.10 one the core runs. Download it again.';
			case 'unsupported': return name + ' is packed in a way this page cannot read. ' + want;
			default: return name + ' could not be read: ' + error.message;
		}
	}

	function show(file) {
		const card = cards[file.save];
		const link = card.querySelector('.save');
		if (link.href) URL.revokeObjectURL(link.href);
		link.href = URL.createObjectURL(new Blob([file.bytes], { type: 'application/octet-stream' }));
		link.download = file.save;
		link.hidden = false;
		card.querySelector('.meta').textContent = count(file.bytes.length) + ' bytes, firmware 4.10'
			+ (have.pack.variant ? ', ' + have.pack.variant : '') + ' (' + have.pack.source + ')'
			+ (file.checked ? ', checked' : '');
		card.classList.remove('is-ready');
		void card.offsetWidth; // so the card comes out of the slot again
		card.classList.add('is-ready');
	}

	async function take(files) {
		if (busy || !files.length) return;
		busy = true;
		bar.hidden = false;
		try {
			for (const file of files) {
				bar.value = 0;
				say('Unpacking ' + file.name);
				try {
					// the file itself, not its bytes: the archive is read in pieces
					const out = await unpack(file, (f) => { bar.value = f; }, file.name);
					out.forEach((part) => { have[part.part] = part; });
					if (have.firmware && have.pack) {
						say('Making the boot files');
						(await images(have.firmware, have.pack)).forEach(show);
					}
				} catch (error) {
					say(explain(error, file.name), true);
					return;
				}
			}
			if (have.firmware && have.pack) say('Both files are ready. Save them, then copy them to the MiSTer.');
			else if (have.firmware) say(FIRMWARE.source + ' is taken. Drop a language pack too (' + PACK.source + ', say): the boot files are made from the two.');
			else say(have.pack.source + ' is taken. Drop the firmware file too (' + FIRMWARE.source + '): the boot files are made from the two.');
		} finally {
			bar.hidden = true;
			busy = false;
			input.value = '';
		}
	}

	input.addEventListener('change', () => take(Array.from(input.files)));

	// A file can be dropped anywhere on the page.
	let depth = 0;
	const over = (on) => {
		document.body.classList.toggle('is-over', on);
		if (on) ask.textContent = 'Let go to unpack it';
		else ask.textContent = askText;
	};
	const hasFiles = (e) => e.dataTransfer && Array.from(e.dataTransfer.types).includes('Files');
	window.addEventListener('dragenter', (e) => {
		if (!hasFiles(e)) return;
		e.preventDefault();
		if (++depth === 1) over(true);
	});
	window.addEventListener('dragover', (e) => {
		if (!hasFiles(e)) return;
		e.preventDefault();
		e.dataTransfer.dropEffect = 'copy';
	});
	window.addEventListener('dragleave', (e) => {
		if (!hasFiles(e)) return;
		if (--depth <= 0) { depth = 0; over(false); }
	});
	window.addEventListener('drop', (e) => {
		if (!hasFiles(e)) return;
		e.preventDefault();
		depth = 0;
		over(false);
		take(Array.from(e.dataTransfer.files));
	});
})();
