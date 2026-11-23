'use strict';
// Regression test for Android IME -> NaN/0S PS/2 guest keyboard bridge.
// Run: node tools/test_wasm_keyboard.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

async function main() {
  const html = fs.readFileSync(path.join(__dirname, '../docs/index.html'), 'utf8');
  const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)].filter(match => match[1].trim());
  assert.equal(scripts.length, 1, 'Expected a single inline browser-player script');
  const code = scripts[0][1];
  // Phones must not scroll to a text field located below the guest framebuffer.
  // Check that the IME input is viewport-pinned for touch/small-screen layouts.
  assert.match(html, /@media\s*\(pointer:\s*coarse\)[\s\S]*?\.typebar\s*\{\s*position:\s*fixed;/,
    'Touch layout must pin the keyboard input to the viewport');

  class Element {
    constructor() { this.listeners = {}; this.value = ''; this.disabled = true; this.className = ''; this.textContent = ''; }
    addEventListener(type, handler) { (this.listeners[type] ||= []).push(handler); }
    dispatch(type, props = {}) {
      const evt = {
        target: this, defaultPrevented: false, propagationStopped: false,
        preventDefault() { this.defaultPrevented = true; },
        stopPropagation() { this.propagationStopped = true; },
        ...props,
      };
      for (const handler of this.listeners[type] || []) handler(evt);
      return evt;
    }
    focus(options) { this.lastFocusOptions = options; }
    querySelectorAll() { return []; }
  }
  const elements = Object.fromEntries(
    ['type', 'clear-type', 'pad', 'status', 'screen_container', 'serial', 'restart', 'fullscreen',
     'zoom-out', 'zoom-in', 'zoom-fit', 'zoom-level', 'image-fingerprint']
      .map(id => [id, new Element()])
  );
  const document = { getElementById(id) { assert.ok(elements[id], 'Missing mock element ' + id); return elements[id]; } };
  let emulator;
  class V86 {
    constructor(opts) {
      this.options = opts;
      this.listeners = {};
      this.codes = [];
      emulator = this;
    }
    add_listener(type, handler) { this.listeners[type] = handler; }
    keyboard_send_scancodes(codes) { this.codes.push(...codes); }
    keyboard_set_enabled() { throw Error('PS/2 delivery must not be disabled by text field focus'); }
  }
  const disk = new Uint8Array(1474560);
  disk[510] = 0x55; disk[511] = 0xaa;
  const fetches = [];
  const fetch = async (url, opts) => {
    fetches.push({ url, opts });
    return { ok: true, arrayBuffer: async () => disk.buffer };
  };
  vm.runInNewContext(code, { document, fetch, V86, setInterval() {}, console }, { filename: 'docs/index.html' });
  // Let fetchImage().then(boot) run.
  for (let i = 0; i < 10 && !emulator; ++i) await new Promise(resolve => setImmediate(resolve));
  assert.ok(emulator, 'Browser did not boot after image fetch');
  assert.equal(fetches.length, 1, 'Only one guest image fetch expected');
  assert.match(fetches[0].url, /^nan0s\.img\?guest=[0-9]+$/, 'Guest URL must bust stale cached disk');
  assert.equal(fetches[0].opts.cache, 'no-store', 'Guest disk must bypass the browser HTTP cache');
  assert.match(elements['image-fingerprint'].textContent, /guest disk: 1474560 bytes/,
    'The page must identify the exact fetched disk to help detect stale images');
  emulator.listeners['emulator-ready']();
  assert.equal(elements.type.disabled, false);
  assert.equal(elements['clear-type'].disabled, false);
  assert.equal(elements['zoom-in'].disabled, false);
  assert.equal(elements['zoom-out'].disabled, false);
  assert.equal(elements['zoom-fit'].disabled, false);
  assert.ok(emulator.options.fda && emulator.options.hda, 'Full system must use floppy and IDE');

  const input = elements.type;
  function clear() {
    elements['clear-type'].dispatch('click');
    assert.equal(input.value, '', 'Clear must reset only the phone input field');
    assert.equal(input.lastFocusOptions && input.lastFocusOptions.preventScroll, true,
      'Refocusing after Clear must never scroll the guest out of view');
    emulator.codes.length = 0;
  }
  function check(label, actual, expected) {
    assert.deepEqual([...actual], expected, label);
  }
  function value(v) { input.value = v; input.dispatch('input'); }
  const key = code => [code, code | 0x80];
  const shift = code => [0x2a, code, code | 0x80, 0xaa];

  clear(); value('a');
  check('lowercase a', emulator.codes, key(0x1e));

  clear(); value('A!');
  check('shifted A and !', emulator.codes, [...shift(0x1e), ...shift(0x02)]);

  clear(); value('n'); value('na'); value('nan'); input.dispatch('compositionend');
  check('Gboard composition updates do not duplicate text', emulator.codes, [...key(0x31), ...key(0x1e), ...key(0x31)]);

  clear(); value('hello'); emulator.codes.length = 0; value('help');
  check('Android autocorrect / composing replacement',
    emulator.codes, [...key(0x0e), ...key(0x0e), ...key(0x19)]);

  clear();
  const back = input.dispatch('keydown', { key: 'Backspace' });
  check('Backspace works with empty phone buffer', emulator.codes, key(0x0e));
  assert.equal(back.defaultPrevented, true);
  assert.equal(back.propagationStopped, true);

  clear();
  const enter = input.dispatch('beforeinput', { inputType: 'insertParagraph' });
  check('Android enter action reaches guest', emulator.codes, key(0x1c));
  assert.equal(enter.defaultPrevented, true);

  clear();
  const tab = input.dispatch('keydown', { key: 'Tab' });
  check('Tab is forwarded to guest', emulator.codes, key(0x0f));
  assert.equal(tab.defaultPrevented, true);

  clear(); value('a'); emulator.codes.length = 0;
  elements['clear-type'].dispatch('click');
  check('Clear never sends guest backspaces', emulator.codes, []);
  assert.equal(input.value, '');

  console.log('PASS: Android IME keyboard input, shifts, composition, corrections, special keys, clear, full-system disks');
}
main().catch(err => { console.error(err); process.exitCode = 1; });
