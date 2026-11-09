#!/usr/bin/env node
// Independent waveform generation, RIFF I/O and onset-interval measurement.
// The reference BPM comes from known event times, not the MoonBit detector.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { analyze_bpm } from '../_build/js/release/build/bridge/bridge.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const workRoot = path.join(root, '_build');
fs.mkdirSync(workRoot, { recursive: true });
const work = fs.mkdtempSync(path.join(workRoot, 'bpm-verification-'));
const rows = [];
const sampleRate = 16000;

function percussion(bpm, seconds = 12, channels = 1) {
  const frames = Math.round(seconds * sampleRate);
  const samples = new Float64Array(frames * channels);
  let seed = 1701;
  for (let beat = 0, center = 0.3; center < seconds - 0.2; beat++, center = 0.3 + beat * 60 / bpm) {
    const start = Math.round(center * sampleRate);
    const strength = 0.7 + 0.05 * (beat % 4);
    for (let j = 0; j < Math.round(0.09 * sampleRate) && start + j < frames; j++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const time = j / sampleRate;
      const attack = Math.min(time / 0.004, 1);
      const carrier = 0.65 * Math.sin(2 * Math.PI * (180 * time - 250 * time * time)) +
        0.2 * (seed / 2 ** 31 - 1);
      const value = strength * attack * Math.exp(-time * 48) * carrier;
      for (let channel = 0; channel < channels; channel++)
        samples[(start + j) * channels + channel] = channel % 2 ? -value : value;
    }
  }
  return Array.from(samples);
}

function wave(samples, channels = 1) {
  const bytes = Buffer.alloc(44 + samples.length * 2);
  bytes.write('RIFF'); bytes.writeUInt32LE(bytes.length - 8, 4);
  bytes.write('WAVEfmt ', 8); bytes.writeUInt32LE(16, 16);
  bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(channels, 22);
  bytes.writeUInt32LE(sampleRate, 24); bytes.writeUInt32LE(sampleRate * channels * 2, 28);
  bytes.writeUInt16LE(channels * 2, 32); bytes.writeUInt16LE(16, 34);
  bytes.write('data', 36); bytes.writeUInt32LE(samples.length * 2, 40);
  samples.forEach((value, index) => bytes.writeInt16LE(Math.round(Math.max(-1, Math.min(1, value)) * 32767), 44 + index * 2));
  return bytes;
}

function decode24(bytes) {
  assert.equal(bytes.toString('ascii', 0, 4), 'RIFF');
  assert.equal(bytes.readUInt32LE(4), bytes.length - 8);
  assert.equal(bytes.toString('ascii', 8, 12), 'WAVE');
  let channels, rate, data;
  for (let offset = 12; offset + 8 <= bytes.length;) {
    const id = bytes.toString('ascii', offset, offset + 4);
    const length = bytes.readUInt32LE(offset + 4);
    assert.ok(offset + 8 + length <= bytes.length);
    if (id === 'fmt ') {
      assert.equal(bytes.readUInt16LE(offset + 8), 1);
      channels = bytes.readUInt16LE(offset + 10);
      rate = bytes.readUInt32LE(offset + 12);
      assert.equal(bytes.readUInt16LE(offset + 22), 24);
    } else if (id === 'data') data = bytes.subarray(offset + 8, offset + 8 + length);
    offset += 8 + length + length % 2;
  }
  assert.ok(data && channels); assert.equal(rate, sampleRate);
  assert.equal(data.length % (3 * channels), 0);
  return { channels, frames: data.length / (3 * channels),
    samples: Array.from({ length: data.length / 3 }, (_, i) => data.readIntLE(i * 3, 3) / 8388608) };
}

// A different oracle from energy autocorrelation: find isolated percussion
// regions above a global envelope threshold, then measure median event gaps.
function intervalBpm(samples, channels = 1) {
  const hop = Math.round(sampleRate * 0.005);
  const levels = [];
  for (let frame = 0; frame < samples.length / channels; frame += hop) {
    let energy = 0, count = 0;
    for (let i = frame; i < Math.min(frame + hop, samples.length / channels); i++) {
      energy += Math.abs(samples[i * channels]); count++;
    }
    levels.push(energy / count);
  }
  const smooth = levels.map((_, i) =>
    (levels[Math.max(0, i - 1)] + levels[i] + levels[Math.min(levels.length - 1, i + 1)]) / 3);
  const threshold = Math.max(...smooth) * 0.22;
  const times = [];
  for (let i = 0; i < smooth.length;) {
    if (smooth[i] <= threshold) { i++; continue; }
    let weight = 0, center = 0;
    const start = i;
    while (i < smooth.length && smooth[i] > threshold) {
      weight += smooth[i]; center += (i + 0.5) * smooth[i]; i++;
    }
    if (i - start >= 2) times.push(center / weight * hop / sampleRate);
  }
  assert.ok(times.length >= 8, `insufficient independent onset events: ${times.length}`);
  const gaps = times.slice(1).map((time, i) => time - times[i]).sort((a, b) => a - b);
  return { bpm: 60 / gaps[Math.floor(gaps.length / 2)], events: times.length };
}

function cli(args, input) {
  return spawnSync(process.execPath, [path.join(root, 'scripts/moonstretch.mjs'), ...args],
    { input, maxBuffer: 32 * 1024 * 1024, timeout: 60000 });
}
function success(result) {
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr.toString());
}
function rejection(args, outputPath, pattern, input) {
  const result = cli(args, input);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr.toString(), pattern);
  assert.equal(result.stdout.length, 0);
  if (outputPath) assert.equal(fs.existsSync(outputPath), false);
  return result;
}

for (const bpm of [65, 90, 120, 137, 180]) {
  const samples = percussion(bpm);
  const independent = intervalBpm(samples);
  assert.ok(Math.abs(independent.bpm - bpm) / bpm < 0.01);
  const estimate = JSON.parse(analyze_bpm(samples, sampleRate, 1, 60, 200));
  assert.ok(estimate, `no estimate for ${bpm}`);
  assert.ok(Math.abs(estimate.bpm - bpm) / bpm < 0.015);
  assert.ok(estimate.confidence >= 0.35 && estimate.confidence <= 1);
  rows.push({ case: 'known_percussive_event_times', bpm, independent, estimate });
}
const stereo = percussion(123, 10, 2);
const antiPhaseEstimate = JSON.parse(analyze_bpm(stereo, sampleRate, 2, 60, 200));
assert.ok(Math.abs(antiPhaseEstimate.bpm - 123) < 1);
rows.push({ case: 'anti_phase_stereo', estimate: antiPhaseEstimate });

for (const frequency of [20, 73, 440, 1000]) {
  const tone = Array.from({ length: sampleRate * 8 }, (_, i) => 0.5 * Math.sin(2 * Math.PI * frequency * i / sampleRate));
  assert.equal(JSON.parse(analyze_bpm(tone, sampleRate, 1, 60, 200)), null);
  rows.push({ case: 'steady_tone_has_no_periodic_beat_estimate', frequency });
}
let noiseSeed = 423, gain = 0, nextChange = 0;
const aperiodicNoise = Array.from({ length: sampleRate * 12 }, (_, i) => {
  noiseSeed = (Math.imul(noiseSeed, 1664525) + 1013904223) >>> 0;
  if (i >= nextChange) {
    gain = 0.05 + (noiseSeed >>> 16) / 100000;
    nextChange = i + 1300 + (noiseSeed >>> 16) % 11000;
  }
  return (noiseSeed / 2 ** 31 - 1) * gain;
});
assert.equal(JSON.parse(analyze_bpm(aperiodicNoise, sampleRate, 1, 60, 200)), null);
rows.push({ case: 'irregular_noise_has_no_periodic_beat_estimate' });

const source = path.join(work, 'source 90 BPM.wav');
const sourceSamples = percussion(90, 12, 2);
fs.writeFileSync(source, wave(sourceSamples, 2));
let result = cli([source, '--detect-bpm']); success(result);
let report = JSON.parse(result.stdout);
assert.ok(Math.abs(report.estimate.bpm - 90) < 1);
assert.equal(report.channels, 2);
rows.push({ case: 'cli_detect', report });

for (const [name, extra, target, rate] of [
  ['known_source', ['--source-bpm', '90'], 120, 1],
  ['automatic_source', [], 135, 1],
  ['rate_compensation', ['--source-bpm', '90', '--pitch', '3', '--rate', '1.25', '--quality', 'music'], 135, 1.25],
]) {
  const output = path.join(work, `${name}.wav`);
  result = cli([source, output, '--target-bpm', String(target), ...extra]); success(result);
  report = JSON.parse(result.stderr);
  const decoded = decode24(fs.readFileSync(output));
  assert.equal(decoded.channels, 2);
  assert.equal(decoded.frames, Math.floor(sourceSamples.length / 2 / (report.tempo * rate) + 0.5));
  const independent = intervalBpm(decoded.samples, 2);
  assert.ok(Math.abs(independent.bpm - target) / target < 0.03,
    `${name} independently measured ${independent.bpm}, expected ${target}`);
  for (let i = 0; i < decoded.samples.length; i += 2)
    assert.ok(Math.abs(decoded.samples[i] + decoded.samples[i + 1]) <= 3e-7);
  rows.push({ case: name, target, independent, report });
}

result = cli(['-', '--detect-bpm'], fs.readFileSync(source)); success(result);
assert.ok(Math.abs(JSON.parse(result.stdout).estimate.bpm - 90) < 1);
rows.push({ case: 'stdin_detection' });
result = cli(['-', '-', '--target-bpm', '120', '--source-bpm', '90'], fs.readFileSync(source)); success(result);
const piped = decode24(result.stdout);
const pipeRate = intervalBpm(piped.samples, 2);
assert.ok(Math.abs(pipeRate.bpm - 120) / 120 < 0.03);
assert.equal(JSON.parse(result.stderr).target_bpm, 120);
rows.push({ case: 'binary_stdio_pipeline', independent: pipeRate });

const silence = path.join(work, 'silence.wav');
fs.writeFileSync(silence, wave(Array(sampleRate * 8).fill(0)));
const noRhythm = path.join(work, 'no-rhythm-must-not-exist.wav');
rejection([silence, noRhythm, '--target-bpm', '120'], noRhythm, /No reliable periodic tempo/);
rows.push({ case: 'ambiguous_source_rejected_without_output' });
const tooFar = path.join(work, 'range-must-not-exist.wav');
rejection([source, tooFar, '--target-bpm', '300', '--source-bpm', '90'], tooFar, /outside 0\.5\.\.2/);
rows.push({ case: 'target_ratio_out_of_range_rejected' });
const conflicting = path.join(work, 'conflict-must-not-exist.wav');
rejection([source, conflicting, '--target-bpm', '120', '--tempo', '1.2'], conflicting, /mutually exclusive/);
rows.push({ case: 'conflicting_controls_rejected' });

const reportPath = process.argv[2] ? path.resolve(process.argv[2]) : path.join(root, 'work', 'bpm-quality.json');
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
fs.writeFileSync(reportPath, JSON.stringify({
  description: 'Synthetic percussion and independent onset-interval oracle; not a real-music accuracy benchmark.',
  sample_rate: sampleRate, checks: rows.length, cases: rows,
}, null, 2) + '\n');
console.log(`Verified ${rows.length} BPM/CLI cases; numerical results: ${reportPath}`);
