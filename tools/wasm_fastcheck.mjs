#!/usr/bin/env node
/**
 * Fast, local v86/WASM integration gate for the REAL NaN/0S guest.
 * No GitHub Actions, no QEMU, no emulated/mock keyboard, no host-side image
 * creation. The NaN16 code in src/lib/bootbuild.nas owns the disk build.
 *
 * One-time setup:
 *   npm install --no-save --no-package-lock v86@0.5.473
 *   sh tools/build.sh
 * Then:
 *   node tools/wasm_fastcheck.mjs
 *   node tools/wasm_fastcheck.mjs --boot-only
 */
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const diskPath = process.env.NAN0S_IMG || path.join(root, "build/nan0s.img");
const cacheDir = process.env.NAN0S_WASM_CACHE || path.join(root, ".cache/nan0s-wasm");
const bootOnly = process.argv.includes("--boot-only");
const timeoutMs = Math.max(30_000, Number(process.env.NAN0S_WASM_TIMEOUT || 180_000));
const diskBytes = fs.readFileSync(diskPath);
assert.equal(diskBytes.length, 1_474_560, "Need a complete 1.44 MiB guest image");
assert.equal(diskBytes[510], 0x55, "Missing boot signature byte 0");
assert.equal(diskBytes[511], 0xaa, "Missing boot signature byte 1");
function hash(buf) { return createHash("sha256").update(buf).digest("hex"); }
function bufferOf(bytes) {
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}
function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

let V86;
try {
    ({ V86 } = await import("v86"));
}
catch(error) {
    console.error("Install local WASM emulator once: npm install --no-save --no-package-lock v86@0.5.473");
    throw error;
}
// Resolve through the module rather than relying on the current working dir.
const esmPath = fileURLToPath(import.meta.resolve("v86"));
const actualWasm = path.join(path.dirname(esmPath), "v86.wasm");
assert.ok(fs.existsSync(actualWasm), "v86.wasm missing from locally installed package");
fs.mkdirSync(cacheDir, { recursive: true });

async function biosImage(name) {
    const dest = path.join(cacheDir, name);
    if (fs.existsSync(dest)) return bufferOf(fs.readFileSync(dest));
    const base = "https://cdn.jsdelivr.net/gh/copy/v86@master/bios/";
    console.log("Caching " + name + " (one-time download)...");
    const response = await fetch(base + name);
    if (!response.ok) throw Error(name + ": HTTP " + response.status);
    const bytes = Buffer.from(await response.arrayBuffer());
    assert.ok(bytes.length >= 16 * 1024, "BIOS is unexpectedly short");
    fs.writeFileSync(dest, bytes);
    return bufferOf(bytes);
}
const bios = await biosImage("seabios.bin");
const vgabios = await biosImage("vgabios.bin");

function track(emulator, label) {
    const state = { serial: "", guiMode: false, ready: false };
    emulator.add_listener("serial0-output-byte", byte => {
        state.serial += String.fromCharCode(byte);
        if (state.serial.length > 8192) state.serial = state.serial.slice(-8192);
        if (state.serial.includes("NANBUILD FAIL")) {
            console.error(label + ": NaN guest reported NANBUILD FAIL");
        }
    });
    emulator.add_listener("screen-set-size", info => {
        if (info && info[0] === 1024 && info[1] === 768) state.guiMode = true;
    });
    emulator.add_listener("emulator-ready", () => { state.ready = true; });
    return state;
}
async function until(condition, label, ms) {
    const stop = Date.now() + ms;
    while (Date.now() < stop) {
        if (condition()) return;
        await sleep(120);
    }
    throw Error("WASM timeout: " + label);
}
const code = {
    a: 0x1e, b: 0x30, d: 0x20, i: 0x17, l: 0x26,
    n: 0x31, s: 0x1f, u: 0x16, "0": 0x0b,
    " ": 0x39, "\n": 0x1c, "\b": 0x0e
};
async function type(emulator, chars) {
    for (const c of chars) {
        const scan = code[c];
        assert.ok(scan !== undefined, "No PS/2 code for " + JSON.stringify(c));
        emulator.keyboard_send_scancodes([scan, scan | 0x80]);
        await sleep(70);
    }
}
function options(image, source, output) {
    return {
        wasm_path: actualWasm,
        bios: { buffer: bios },
        vga_bios: { buffer: vgabios },
        boot_order: 0x321,
        fda: { buffer: image },
        hda: { buffer: source },
        ...(output ? { hdb: { buffer: output } } : {}),
        memory_size: 128 * 1024 * 1024,
        vga_memory_size: 2 * 1024 * 1024,
        autostart: true
    };
}
const original = bufferOf(diskBytes);
const sourceMaster = bufferOf(diskBytes);
const blankReplica = new ArrayBuffer(diskBytes.length);
let emulator;
let replicaBoot;
const started = Date.now();
try {
    console.log("WASM local fast gate: v86 + raw NaN16, image=" + hash(diskBytes).slice(0, 16));
    emulator = new V86(options(original, sourceMaster, blankReplica));
    const state = track(emulator, "generation 1");
    await until(() => state.serial.includes("NaN/0S"), "initial NaN/0S boot banner", 60_000);
    await sleep(2500);
    assert.ok(emulator.is_running(), "Guest stopped after boot");
    console.log("gen1 boot: PASS; elapsed=" + ((Date.now()-started)/1000).toFixed(2) + "s");

    // Target the actual issue reported on Android: bare 'n', then more input.
    await type(emulator, "na\b\b");
    await sleep(300);
    assert.ok(emulator.is_running(), "Guest stopped after bare n/backspace sequence");
    const ticksBefore = emulator.get_instruction_counter();
    await sleep(400);
    const ticksAfter = emulator.get_instruction_counter();
    assert.ok(ticksAfter > ticksBefore, "WASM CPU stopped after typing n");
    console.log("bare n + a + 2 backspaces: CPU still executing");

    if (!bootOnly) {
        // Bare build is a help command, never the legacy 'b' browser alias.
        await type(emulator, "build\n");
        await until(() => state.serial.includes("NANBUILD HELP"),
            "raw NaN16 build usage reply", 12_000);
        assert.ok(!state.serial.includes("NANBUILD OK"),
            "Bare build must not start a disk build");
        assert.ok(new Uint8Array(blankReplica).every(byte => byte === 0),
            "Bare build must leave the output disk unchanged");
        console.log("bare 'build' displayed NaN16 usage and left the output disk blank");
        await type(emulator, "build nan0s\n");
        await until(() =>
            state.serial.includes("NANBUILD OK") || state.serial.includes("NANBUILD FAIL"),
            "in-guest full 2880-sector NaN16 build", timeoutMs);
        assert.ok(state.serial.includes("NANBUILD OK"), "Guest build failed: " + state.serial.slice(-1200));
        const clone = Buffer.from(blankReplica);
        assert.equal(clone.length, diskBytes.length, "Secondary IDE image size mismatch");
        assert.deepEqual(clone, diskBytes, "Secondary image differs from the original source");
        assert.deepEqual(Buffer.from(sourceMaster), diskBytes,
            "Source IDE master was modified by guest build");
        console.log("gen1 complete guest-built disk: PASS; SHA256=" + hash(clone));

        // Free the first 128 MiB WASM machine before the second boot.
        // This matters on Android phones, and the verified clone is preserved.
        await emulator.destroy();
        emulator = null;
        // Separate v86 instance boots from guest-generated, verified bytes.
        replicaBoot = new V86(options(bufferOf(clone), bufferOf(clone)));
        const second = track(replicaBoot, "generation 2");
        await until(() => second.serial.includes("NaN/0S"), "self-replica cold boot", 60_000);
        assert.ok(replicaBoot.is_running(), "Rebuilt NaN/0S stopped after boot");
        console.log("gen2 independent WASM cold boot: PASS");
    }
    console.log("PASS: local WASM gate; seconds=" + ((Date.now()-started)/1000).toFixed(2));
}
finally {
    if (replicaBoot) await replicaBoot.destroy();
    if (emulator) await emulator.destroy();
}
