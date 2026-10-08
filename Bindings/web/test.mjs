// Runs the WebAssembly build under Node against the demo's sample files:
//
//     node Bindings/web/test.mjs

import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { loadRawInput, RawInputError } from './rawinput.mjs';

const samples = fileURLToPath(new URL('../../Examples/RawInputDemo/Samples/files/', import.meta.url));
const sample = (name) => (existsSync(samples + name) ? new Uint8Array(readFileSync(samples + name)) : null);
const rawInput = await loadRawInput();

test('opens a Bayer file and exposes what a WebGPU kernel needs', (t) => {
  const bytes = sample('samsung-nx300.srw');
  if (!bytes) return t.skip('the sample files have not been fetched');
  const file = rawInput.open(bytes);
  try {
    assert.equal(file.info.make, 'Samsung');
    assert.equal(file.mosaic(), null, 'nothing to hand out before unpack');

    file.unpack();
    const info = file.info;
    assert.equal(info.layout, 'bayer');
    assert.equal(info.plainBayer, true);

    const mosaic = file.mosaic();
    assert.equal(mosaic.rawWidth, info.rawWidth);
    assert.ok(mosaic.samples.length >= info.rawWidth * info.rawHeight);

    const params = file.developParams();
    assert.equal(params.length, 128, 'the kernel uniform block is 128 bytes');
    const fields = new DataView(params.buffer);
    assert.deepEqual([fields.getUint32(104, true), fields.getUint32(108, true)], [info.width, info.height]);
  } finally {
    file.close();
  }
});

test('develops a Foveon file on the CPU', (t) => {
  const bytes = sample('sigma-dp0-quattro.x3f');
  if (!bytes) return t.skip('the sample files have not been fetched');
  const file = rawInput.open(bytes);
  try {
    file.unpack();
    assert.equal(file.info.plainBayer, false);
    assert.equal(file.mosaic(), null);
    assert.equal(file.developParams(), null);

    const picture = file.developCPU();
    assert.equal(picture.channels, 3);
    assert.equal(picture.pixels.length, picture.width * picture.height * 3);
    assert.ok(picture.pixels.some((value) => value > 0), 'the picture is not black');
  } finally {
    file.close();
  }
});

test('has an embedded preview', (t) => {
  const bytes = sample('samsung-nx300.srw');
  if (!bytes) return t.skip('the sample files have not been fetched');
  const file = rawInput.open(bytes);
  try {
    const thumbnail = file.thumbnail();
    assert.equal(thumbnail.isJPEG, true);
    assert.deepEqual([...thumbnail.bytes.slice(0, 2)], [0xff, 0xd8], 'a JPEG starts with its SOI marker');
  } finally {
    file.close();
  }
});

test('refuses a frame over the memory limit', (t) => {
  const bytes = sample('samsung-nx300.srw');
  if (!bytes) return t.skip('the sample files have not been fetched');
  const file = rawInput.open(bytes);
  try {
    file.setMemoryLimit(1);
    assert.throws(() => file.unpack(), RawInputError);
  } finally {
    file.close();
  }
});

test('rejects what is not a RAW file', () => {
  assert.throws(() => rawInput.open(new Uint8Array(4096)), RawInputError);
});
