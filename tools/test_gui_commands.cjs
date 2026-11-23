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

const dispatch = block('fs_dispatch:', 'fs_d_build:');
assert.match(dispatch, /LA r2,@fs_s_build_head\s*\nCALL @fs_prefix/,
  'The build command family must be recognized by raw NaN16 before one-letter fallback');
assert.match(dispatch, /LA r2,@fs_s_build\s*\nCALL @fs_exact/,
  'Full bootable-image building requires an exact command match');
assert.match(dispatch, /JMP\[NE\] @fs_d_build\s*\nJMP @fs_d_build_help/,
  'Bare build and invalid arguments must display help instead of launching browser');

const exact = block('fs_exact:', 'fs_dispatch:');
assert.match(exact, /LDB r3,r1,0[\s\S]*?LDB r4,r2,0[\s\S]*?CMP r3,r4/,
  'The exact match must compare the whole command including NUL');
const help = block('fs_d_build_help:', 'fs_d_cc:');
assert.match(help, /CALL @vc_puts[\s\S]*?CALL @sb_serial/,
  'The raw NaN16 build help must be printed in the terminal and on serial');
const build = block('fs_d_build:', 'fs_d_build_help:');
assert.match(build, /CALL @sb_build/, 'Only build nan0s launches native image building');
assert.match(source, /fs_s_build_head:\s*\n\.str "build"\s*\nfs_s_build:\s*\n\.str "build nan0s"/,
  'The build family and full command must be declared independently');

console.log('PASS: n -> NaNNet; b -> browser; build -> help; build nan0s -> exact raw NaN16 disk builder');
