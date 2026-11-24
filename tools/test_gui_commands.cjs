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

// F0 is a guest-specific NaN16 function key, not a standard PC key.
const kbd = fs.readFileSync(path.join(__dirname, '../src/lib/kbd.nas'), 'utf8');
const virtualRows = kbd.match(/^\.word 0,0,0,0,256,0,0,267,268,0,0,0,0,0,0,0$/gm) || [];
assert.equal(virtualRows.length, 2,
  'Both shifted and normal NaN16 keymaps must map Set-1 0x54 to F0 and preserve F11/F12');
const f0route = block('gk_np:', 'gk_notf0:');
assert.match(f0route, /MOVI r2,0x100\s*\nCMP r1,r2\s*\nJMP\[NE\] @gk_notf0\s*\nCALL @gk_help/,
  'The desktop must dispatch the virtual F0 event 0x100');
const f0help = block('gk_help:', 'gh_id:');
assert.match(f0help, /CALL @term_cmd[\s\S]*CALL @term_draw/,
  'F0 must display native terminal help inside the guest');

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

// The desktop's modern features must execute inside raw NaN16, never inside
// the browser DOM. Verify the native render and dispatch symbols are linked.
const wm = fs.readFileSync(path.join(__dirname, '../src/lib/wm.nas'), 'utf8');
const shell = fs.readFileSync(path.join(__dirname, '../src/lib/shell.nas'), 'utf8');
assert.match(source, /\.include "\.\.\/lib\/shell\.nas"/, 'Native shell must be linked into the bootable cartridge');
assert.match(source, /CALL @wm_draw_all\s*\nCALL @g_bar\s*\nCALL @sh_draw/,
  'Native launcher/modal must render after guest windows');
assert.match(source, /g_onkey:[\s\S]*?CALL @sh_handle[\s\S]*?gk_regular:/,
  'Modal guest keyboard routing must precede global hotkeys');
assert.match(source, /CALL @sh_launcher/, 'F1 must open native app launcher');
assert.match(source, /CALL @sh_dialog/, 'F4 must open native confirmation dialog');
assert.match(source, /CALL @wm_minimize/, 'F8 must minimize a guest window');
assert.match(source, /CALL @wm_tile/, 'F9 must tile native guest windows');
assert.match(source, /CALL @wm_snap/, 'F10/F11 must snap native guest windows');
assert.match(source, /CALL @wm_restore_minimized/, 'F12 must restore a minimized guest window');
assert.match(source, /CALL @wm_theme_toggle/, 'Shift+F5 must toggle native themes');
assert.match(source, /CALL @g_resizekey/, 'Shift+F2 must use native window resize mode');
assert.match(source, /CALL @wm_activate_slot/, 'Ctrl+1..8 must activate taskbar windows');
for (const name of [
  'wm_draw_taskbar:', 'wm_minimize:', 'wm_restore_minimized:', 'wm_activate_slot:',
  'wm_snap:', 'wm_tile:', 'wm_notice:', 'wm_notice_tick:', 'wm_theme_toggle:',
]) {
  assert.ok(wm.includes('\n' + name + '\n'), 'Missing raw NaN16 window manager symbol ' + name);
}
for (const name of ['sh_draw:', 'sh_init:', 'sh_launcher:', 'sh_dialog:', 'sh_handle:']) {
  assert.ok(shell.includes('\n' + name + '\n'), 'Missing raw NaN16 shell symbol ' + name);
}
assert.match(wm, /CALL @wm_draw_taskbar/, 'The native frame composition must include the taskbar');
assert.match(wm, /CALL @wm_rect[\s\S]*?dw_noaccent:/,
  'Window decorations must use native framebuffer drawing');
assert.match(shell, /sh_appnames:[\s\S]*?\.word @sh_n0,@sh_n1,@sh_n2,@sh_n3,@sh_n4,@sh_n5,@sh_n6,@sh_n7/,
  'App launcher must include all eight native applications');
assert.doesNotMatch(wm + shell, /<div|document\.|window\.(?:addEventListener|querySelector|document)|\.js\b|#include <stdio/,
  'No browser or foreign-language guest window implementation is allowed');
console.log('PASS: raw NaN16 taskbar, launcher, modal, notification, themes, tile, snap, resize and restore');

console.log('PASS: F0 native help, F1-F12 mapping, n/b routing, build command help, disk builder');
