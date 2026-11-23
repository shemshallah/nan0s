'use strict';
// Guard NaN/0S GUI commands and browser window initialization. This catches
// the command-n hang without changing guest behavior or requiring an emulator.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../src/exhibits/gui_cart.nas'), 'utf8');

function block(start, end) {
  const a = source.indexOf('\n' + start + '\n');
  assert.ok(a >= 0, 'Missing guest label ' + start);
  const b = source.indexOf('\n' + end + '\n', a + start.length + 2);
  assert.ok(b > a, 'Missing subsequent label ' + end);
  return source.slice(a, b);
}

const net = block('tm_net:', 'tm_utl:');
assert.match(net, /MOVI r1,5\s*\nCALL @gui_single/, 'n must launch NaNNet window kind 5');

const browser = block('tm_br:', 'tm_nsh:');
assert.match(browser, /MOVI r1,7\s*\nCALL @gui_open_new/, 'b must launch browser kind 7');

const init = block('br_init:', 'br_draw:');
assert.match(init, /ST r1,r0,@br_id[\s\S]*?LD r1,r0,@br_id\s*\nCALL @term_fit/,
  'browser initializer must restore the actual window ID before term_fit');
assert.doesNotMatch(init, /^PUTC r1\s*$/m, 'debug PUTC must not overwrite browser window ID');

const controls = block('term_key:', 'tk_id:');
assert.match(controls, /MOVI r4,13\s*\nCMP r3,r4\s*\nJMP\[EQ\] @tk_enter/,
  'the key n by itself must remain ordinary printable text, not a command');

console.log('PASS: n -> NaNNet (5), b -> browser (7), safe window ID, printable-key semantics');
