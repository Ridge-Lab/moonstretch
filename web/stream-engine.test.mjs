import test from 'node:test';
import assert from 'node:assert/strict';
import * as engine from './engine.js';
import { StreamPump } from './live-pump.mjs';

// Run after scripts/build_web.mjs so these tests exercise the generated MoonBit.
test('generated MoonBit bridge produces PCM before consuming the recording and preserves one live instance', async () => {
  const sampleRate = 48000;
  const channels = 2;
  const frames = sampleRate * 8;
  const samples = Float32Array.from({ length: frames * channels }, (_, i) =>
    0.25 * Math.sin(2 * Math.PI * 440 * Math.floor(i / channels) / sampleRate) * (i % 2 ? 0.8 : 1));
  let creations = 0;
  const api = { ...engine, live_create(...args) { creations += 1; return engine.live_create(...args); } };
  const pump = new StreamPump(api, { samples, sampleRate, channels },
    { tempo: 1, pitch: 0, rate: 1, quality: 'balanced' });
  let part = await pump.pull(2048);
  assert.equal(part.samples.length, 4096);
  assert.ok(pump.stats().input_frames < frames);
  assert.equal(pump.setControls({ tempo: 0.75, pitch: 3, rate: 1 }), true);
  let totalFrames = part.samples.length / channels;
  assert.ok(part.samples.every(Number.isFinite));
  while (!part.ended) {
    part = await pump.pull(2048);
    assert.ok(part.samples.every(Number.isFinite));
    totalFrames += part.samples.length / channels;
  }
  assert.equal(creations, 1, 'control changes must not create replacement processors');
  assert.ok(totalFrames > frames, 'slower tempo produces a longer result');
  assert.equal(pump.stats().available_frames, 0);
  assert.equal(pump.stats().input_frames, frames);
  pump.clear();
});

test('the browser beat demo has a 120 BPM estimate while a steady tone has no beat estimate', () => {
  const sampleRate = 48000;
  const beats = Array.from({ length: sampleRate * 12 }, (_, i) => {
    const time = i / sampleRate;
    const local = time % 0.5;
    return local < 0.15 ? 0.6 * Math.exp(-local * 32)
      * (Math.sin(2 * Math.PI * (Math.floor(time / 0.5) % 4 === 0 ? 85 : 65) * local)
      + 0.15 * Math.sin(2 * Math.PI * 1600 * local)) : 0;
  });
  const estimate = JSON.parse(engine.analyze_bpm(beats, sampleRate, 1, 40, 240));
  assert.ok(estimate && Math.abs(estimate.bpm - 120) < 2);
  const tone = Array.from({ length: sampleRate * 8 }, (_, i) =>
    0.25 * Math.sin(2 * Math.PI * 440 * i / sampleRate));
  assert.equal(JSON.parse(engine.analyze_bpm(tone, sampleRate, 1, 40, 240)), null);
});
