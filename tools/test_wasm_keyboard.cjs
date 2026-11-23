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
    getBoundingClientRect() { return { left: 10, top: 20 }; }
    querySelectorAll() { return []; }
  }
  const elements = Object.fromEntries(
    ['type', 'clear-type', 'pad', 'status', 'screen_container', 'serial', 'restart', 'fullscreen',
     'zoom-out', 'zoom-in', 'zoom-fit', 'zoom-level', 'image-fingerprint', 'download-replica']
      .map(id => [id, new Element()])
  );
  elements.screen_container.clientWidth = 360;
  const document = { getElementById(id) { assert.ok(elements[id], 'Missing mock element ' + id); return elements[id]; } };
  const window = { matchMedia() { return { matches: true }; } };
  let emulator;
  class V86 {
    constructor(opts) {
      this.options = opts;
      this.listeners = {};
      this.codes = [];
      this.scales = [];
      emulator = this;
    }
    add_listener(type, handler) { this.listeners[type] = handler; }
    keyboard_send_scancodes(codes) { this.codes.push(...codes); }
    screen_set_scale(x, y) { this.scales.push([x, y]); }
    keyboard_set_enabled() { throw Error('PS/2 delivery must not be disabled by text field focus'); }
  }
  const disk = new Uint8Array(1474560);
  disk[510] = 0x55; disk[511] = 0xaa;
  const fetches = [];
  const fetch = async (url, opts) => {
    fetches.push({ url, opts });
    return { ok: true, arrayBuffer: async () => disk.buffer };
  };
  const frames = [];
  const requestAnimationFrame = callback => frames.push(callback);
  vm.runInNewContext(code, { document, window, fetch, V86, setInterval() {}, requestAnimationFrame, console },
    { filename: 'docs/index.html' });
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
  assert.ok(emulator.options.fda && emulator.options.hda && emulator.options.hdb,
    'Full system must use floppy, source IDE master, and independent output IDE slave');
  assert.equal(elements['download-replica'].disabled, true, 'Never download an unverified output');
  assert.equal(new Uint8Array(emulator.options.hdb.buffer).every(b => b === 0), true,
    'Output disk must start blank');
  new Uint8Array(emulator.options.hdb.buffer).set([0x55, 0xaa], 510);
  for (const character of 'NANBUILD OK\n') {
    emulator.listeners['serial0-output-byte'](character.charCodeAt(0));
  }
  assert.equal(elements['download-replica'].disabled, false,
    'Only the guest verified-output event enables downloading');
  assert.ok(emulator.options.hdb.buffer !== emulator.options.hda.buffer,
    'Replicator must never write to live source IDE disk');
  assert.deepEqual(emulator.scales.at(-1), [1.5, 1.5],
    'Touch devices must start zoomed in to make the guest readable');

  // Pinch the real WASM screen, not the HTML page. A moving midpoint must
  // keep its guest pixel anchored; one finger must retain native panning.
  const screen = elements.screen_container;
  screen.clientLeft = 0;
  screen.clientTop = 0;
  screen.scrollLeft = 120;
  screen.scrollTop = 80;
  const first = [{ clientX: 110, clientY: 120 }, { clientX: 210, clientY: 120 }];
  const expanded = [{ clientX: 95, clientY: 120 }, { clientX: 245, clientY: 120 }];
  const single = screen.dispatch('touchstart', { touches: [first[0]], cancelable: true });
  assert.equal(single.defaultPrevented, false, 'One-finger pan must not be intercepted');
  const pinchStart = screen.dispatch('touchstart', { touches: first, cancelable: true });
  assert.equal(pinchStart.defaultPrevented, true, 'Two-finger start blocks page zoom');
  const pinchOut = screen.dispatch('touchmove', { touches: expanded, cancelable: true });
  assert.equal(pinchOut.defaultPrevented, true, 'Pinch must block page scrolling and zoom');
  assert.deepEqual(emulator.scales.at(-1), [2.25, 2.25],
    'Spreading 1.5x must scale the NaN/0S desktop from 150% to 225%');
  assert.equal(elements['zoom-level'].textContent, '225%', 'Pinch updates toolbar');
  assert.equal(screen.scrollLeft, 245, 'Pinch must preserve the X content anchor');
  assert.equal(screen.scrollTop, 170, 'Pinch must preserve the Y content anchor');
  screen.dispatch('touchmove', { touches: first, cancelable: true });
  assert.deepEqual(emulator.scales.at(-1), [1.5, 1.5],
    'Pinching back restores the original guest scale');
  assert.equal(screen.scrollLeft, 120, 'Returning fingers restores horizontal pan');
  assert.equal(screen.scrollTop, 80, 'Returning fingers restores vertical pan');
  // The first queued frame refers to obsolete gesture coordinates; it must
  // never pull the viewport back to the earlier (225%) pinch location.
  for (const frame of frames.splice(0)) frame();
  assert.equal(screen.scrollLeft, 120, 'Stale RAF callback must not undo the newest pinch X');
  assert.equal(screen.scrollTop, 80, 'Stale RAF callback must not undo the newest pinch Y');
  screen.dispatch('touchend', { touches: [first[0]] });
  const oneMove = screen.dispatch('touchmove', { touches: [first[0]], cancelable: true });
  assert.equal(oneMove.defaultPrevented, false, 'Single-finger panning remains native');
  screen.dispatch('touchcancel', { touches: [] });
  assert.ok(!emulator.codes.length, 'Screen pinch must not inject keyboard input');

  elements['zoom-out'].dispatch('click');
  assert.deepEqual(emulator.scales.at(-1), [1.2, 1.2], 'Zoom out must scale the guest');
  elements['zoom-in'].dispatch('click');
  assert.deepEqual(emulator.scales.at(-1), [1.5, 1.5], 'Zoom in must scale the guest');
  elements['zoom-fit'].dispatch('click');
  assert.deepEqual(emulator.scales.at(-1), [0.328125, 0.328125],
    'Fit must show all 1024px even on a 360px phone');
  emulator.listeners['screen-set-size']([1024, 768]);
  assert.deepEqual(emulator.scales.at(-1), [0.328125, 0.328125],
    'Mode switches must preserve the current user-selected zoom');

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
