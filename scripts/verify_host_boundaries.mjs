#!/usr/bin/env node
import assert from 'node:assert/strict';
import {
  analyze_bpm, transform_pcm, transform_pcm_quality, encode_wav, live_create, fixed_create, live_put, live_read,
  live_finish, live_clear, live_stats, live_set_controls,
} from '../_build/js/release/build/bridge/bridge.js';

let checks = 0;
// JavaScript does not enforce the Int annotations exported from MoonBit.
// Fractional frame counts previously allowed a partial stereo frame to escape.
const p = live_create(8000, 2, 1, 0, 1, 'balanced');
live_put(p, Array.from({ length: 8000 }, (_, i) => 0.2 * Math.sin(i * 0.1)));
live_finish(p);
const before = JSON.parse(live_stats(p));
for (const frames of [1.5, NaN, Infinity, -Infinity, -1, 2147483648]) {
  assert.throws(() => live_read(p, frames), /frames.*finite integer/);
  assert.deepEqual(JSON.parse(live_stats(p)), before);
  checks++;
}
const read = live_read(p, 1);
assert.equal(read.length, 2);
assert.equal(JSON.parse(live_stats(p)).available_frames, before.available_frames - 1);
checks++;
live_clear(p);
assert.equal(JSON.parse(live_stats(p)).buffered_frames, 0);
checks++;
for (const [rate, channels] of [
  [8000.5, 1], [NaN, 1], [Infinity, 1], [7999, 1], [192001, 1],
  [8000, 1.5], [8000, NaN], [8000, Infinity], [8000, 0], [8000, 9],
]) {
  assert.throws(() => live_create(rate, channels, 1, 0, 1, 'balanced'), /finite integer/);
  assert.throws(() => fixed_create(rate, channels, 1, 0, 1, 'balanced'), /finite integer/);
  assert.throws(() => transform_pcm_quality([], rate, channels, 1, 0, 1, 'balanced'), /finite integer/);
  assert.throws(() => analyze_bpm([], rate, channels, 60, 200), /finite integer/);
  assert.throws(() => transform_pcm([], rate, channels, 1, 0, 1), /finite integer/);
  assert.throws(() => encode_wav([], rate, channels), /finite integer/);
  checks += 6;
}
const fixed = fixed_create(8000, 1, 0.75, 3, 1, 'speech');
const fixedBefore = JSON.parse(live_stats(fixed));
assert.throws(() => live_set_controls(fixed, 1, 0, 1), /fixed|adjustable|live/);
assert.deepEqual(JSON.parse(live_stats(fixed)), fixedBefore);
checks++;
console.log(`Verified ${checks} JavaScript host integer-boundary and FIFO alignment checks.`);
