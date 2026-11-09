#!/usr/bin/env node
// Independent analytical checks against the compiled public bridge.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import { performance } from 'node:perf_hooks';
import {
  transform_pcm_quality, live_create, live_put, live_read, live_finish,
  live_set_controls, live_stats, live_clear,
} from '../_build/js/release/build/bridge/bridge.js';

const rows = [];
const sr = 16000;
function tone(frames, channels = 1, start = 0) {
  return Array.from({ length: frames * channels }, (_, i) => {
    const v = 0.3 * Math.sin(2 * Math.PI * 440 * (start + Math.floor(i / channels)) / sr);
    return i % channels === 1 ? -v : v;
  });
}
function frequency(pcm, channels = 1) {
  const crossings = [];
  const frames = pcm.length / channels;
  for (let i = Math.floor(frames / 4) + 1; i < Math.floor(frames * 3 / 4); i++) {
    const a = pcm[(i - 1) * channels], b = pcm[i * channels];
    if (a <= 0 && b > 0) crossings.push(i - 1 - a / (b - a));
  }
  assert(crossings.length > 20, 'enough observable periods');
  return (crossings.length - 1) * sr / (crossings.at(-1) - crossings[0]);
}
function verifyTone(pcm, hz, channels = 1) {
  assert(pcm.every(Number.isFinite), 'finite PCM');
  const measured = frequency(pcm, channels);
  assert(Math.abs(measured / hz - 1) <= 0.015, `frequency ${measured} vs ${hz}`);
  const meanSquare = pcm.reduce((sum, x) => sum + x * x, 0) / pcm.length;
  assert(meanSquare > 0.005 && meanSquare < 0.1, `signal level ${meanSquare}`);
  return { measured_hz: measured, expected_hz: hz, rms: Math.sqrt(meanSquare) };
}
for (const quality of ['speech', 'balanced', 'music']) {
  const input = tone(sr);
  const begin = performance.now();
  const output = transform_pcm_quality(input, sr, 1, 0.75, 5, 1, quality);
  assert.equal(output.length, Math.round(sr / 0.75));
  rows.push({ case: 'profile', quality, output_frames: output.length,
    elapsed_ms: performance.now() - begin, ...verifyTone(output, 440 * 2 ** (5 / 12)) });
  const p = live_create(sr, 1, 0.75, 5, 1, quality);
  const live = [];
  for (let pos = 0; pos < input.length; pos += 127) {
    live_put(p, input.slice(pos, pos + 127));
    live.push(...live_read(p, 100000));
  }
  live_finish(p);
  live.push(...live_read(p, 100000));
  assert(Math.abs(live.length - Math.round(sr / 0.75)) <= 4, 'two-stage live rounding');
  rows.push({ case: 'constant_live', quality, output_frames: live.length, ...verifyTone(live, 440 * 2 ** (5 / 12)) });
}
const schedule = [[1, 0, 1], [0.75, 7, 1], [1.25, -5, 0.8], [1, 0, 1]];
function liveSchedule(chunk) {
  const p = live_create(sr, 2, 1, 0, 1, 'balanced');
  const output = [];
  const segments = [];
  let peak = 0;
  for (let segment = 0; segment < schedule.length; segment++) {
    const [tempo, pitch, rate] = schedule[segment];
    live_set_controls(p, tempo, pitch, rate);
    const startOutput = output.length;
    const input = tone(2 * sr, 2, segment * 2 * sr);
    for (let pos = 0; pos < input.length; pos += chunk * 2) {
      live_put(p, input.slice(pos, pos + chunk * 2));
      output.push(...live_read(p, 100000));
      peak = Math.max(peak, JSON.parse(live_stats(p)).buffered_frames);
    }
    segments.push({ case: 'live_control', segment, tempo, pitch, rate,
      ...verifyTone(output.slice(startOutput), 440 * 2 ** (pitch / 12) * rate, 2) });
  }
  live_finish(p);
  output.push(...live_read(p, 100000));
  const stats = JSON.parse(live_stats(p));
  assert.equal(stats.input_frames, sr * 8);
  assert.equal(stats.output_frames, output.length / 2);
  assert.equal(stats.buffered_frames, 0);
  for (let i = 0; i < output.length; i += 2) assert(Math.abs(output[i] + output[i + 1]) < 1e-12);
  return { output, peak, segments };
}
const a = liveSchedule(127);
const b = liveSchedule(4096);
assert.deepEqual(a.output, b.output, 'identical control boundaries must not depend on caller chunk sizes');
rows.push(...a.segments, { case: 'live_partition_invariance', frames: a.output.length / 2, peak_retained_frames: a.peak });
for (const controls of [[0.5, 12, 2], [2, -12, 0.5]]) {
  const peaks = [];
  for (const seconds of [4, 12]) {
    const p = live_create(sr, 1, ...controls, 'speech');
    let peak = 0;
    let emitted = 0;
    for (let pos = 0; pos < seconds * sr; pos += 512) {
      live_put(p, tone(Math.min(512, seconds * sr - pos), 1, pos));
      emitted += live_read(p, 100000).length;
      peak = Math.max(peak, JSON.parse(live_stats(p)).buffered_frames);
    }
    assert(emitted > 0, 'must output before finish');
    live_finish(p);
    emitted += live_read(p, 100000).length;
    peaks.push(peak);
    const stats = JSON.parse(live_stats(p));
    assert.equal(stats.buffered_frames, 0);
    live_clear(p);
    assert.equal(JSON.parse(live_stats(p)).input_frames, 0);
    rows.push({ case: 'retained_pcm', controls, seconds, peak_retained_frames: peak, emitted_frames: emitted });
  }
  assert(Math.abs(peaks[1] - peaks[0]) <= 1024, 'retained PCM must not scale with audio duration');
}
const report = { passed: true, backend: 'MoonBit JS release', node: process.version,
  platform: `${process.platform}/${process.arch}`, cpu: os.cpus()[0]?.model,
  frequency_relative_tolerance: 0.015, rows };
const output = process.argv[2] || 'work/streaming-quality.json';
fs.mkdirSync(new URL('../work/', import.meta.url), { recursive: true });
fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
console.log(`${rows.length} independent streaming/profile checks passed; report: ${output}`);
