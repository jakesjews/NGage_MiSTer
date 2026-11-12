// SPDX-License-Identifier: GPL-2.0-or-later
//
// The page around unpack.js: takes dropped or chosen files, shows the two
// boot files as cards and hands them out as downloads.
(function () {
	'use strict';

	const { unpack, PACKAGE } = window.NGageUnpack;
	const $ = (id) => document.getElementById(id);
	const status = $('status'), bar = $('bar'), input = $('file'), ask = $('ask');
	const cards = { 'boot0.rom': $('card0'), 'boot1.rom': $('card1') };
	const askText = ask.textContent;
	const count = (n) => n.toLocaleString('en-US');
	let busy = false;

	function say(text, isError) {
		status.textContent = text;
		status.classList.toggle('is-error', !!isError);
	}

	function explain(error, name) {
		const need = 'The core needs ' + PACKAGE.name + ', ' + count(PACKAGE.size) + ' bytes.';
		switch (error.code) {
			case 'not-package': return name + ' is not the data package. ' + need;
			case 'other-version': return name + ' holds another firmware version, and the core runs 4.60 only. ' + need;
			case 'damaged': return name + ' is cut short or damaged. Download it again: it should be ' + count(PACKAGE.size) + ' bytes.';
			case 'mismatch': return 'The files in ' + name + ' are not the 4.60 ones the core accepts. Download the package again.';
			case 'unsupported': return name + ' is packed in a way this page cannot read. ' + need;
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
		card.querySelector('.meta').textContent = count(file.bytes.length) + ' bytes, checked against firmware 4.60';
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
					const out = await unpack(new Uint8Array(await file.arrayBuffer()), (f) => { bar.value = f; });
					out.forEach(show);
				} catch (error) {
					say(explain(error, file.name), true);
					return;
				}
			}
			const ready = Object.keys(cards).filter((name) => cards[name].classList.contains('is-ready'));
			if (ready.length === 2) say('Both files are ready. Save them, then copy them to the MiSTer.');
			else say(ready[0] + ' is ready. Drop the other file for ' + (ready[0] === 'boot0.rom' ? 'boot1.rom' : 'boot0.rom') + '.');
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
