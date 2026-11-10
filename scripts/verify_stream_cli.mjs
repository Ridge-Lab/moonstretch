import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { streamWav } from './stream_wav.mjs';
import { transform_wav } from '../_build/js/release/build/bridge/bridge.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const base = path.join(root, 'work'); fs.mkdirSync(base, { recursive: true });
const dir = fs.mkdtempSync(path.join(base, 'stream-cli-'));
const rows = [];
const defaults = { tempo: 1, pitch: 0, rate: 1, quality: 'balanced' };

// Independent fixture encoding and container checks. MoonWavKit does not create
// the input or calculate the expected duration/metadata in these tests.
function fixture(bits, channels, frames, floating = false) {
  const width = bits / 8, size = frames * channels * width;
  const b = Buffer.alloc(44 + size + size % 2);
  b.write('RIFF', 0); b.writeUInt32LE(b.length - 8, 4); b.write('WAVEfmt ', 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(floating ? 3 : 1, 20);
  b.writeUInt16LE(channels, 22); b.writeUInt32LE(8000, 24);
  b.writeUInt32LE(8000 * channels * width, 28); b.writeUInt16LE(channels * width, 32);
  b.writeUInt16LE(bits, 34); b.write('data', 36); b.writeUInt32LE(size, 40);
  for (let frame = 0; frame < frames; frame++) for (let ch = 0; ch < channels; ch++) {
    const v = 0.22 * Math.sin(2 * Math.PI * (220 + ch * 55) * frame / 8000);
    const offset = 44 + (frame * channels + ch) * width;
    if (floating) b.writeFloatLE(v, offset);
    else if (bits === 8) b[offset] = Math.round(v * 127 + 128);
    else b.writeIntLE(Math.round(v * (2 ** (bits - 1) - 1)), offset, width);
  }
  return b;
}

function outputCheck(output, frames, channels) {
  const b = fs.readFileSync(output), size = frames * channels * 3;
  assert.equal(b.length, 44 + size + size % 2);
  assert.equal(b.readUInt32LE(4), b.length - 8);
  assert.equal(b.readUInt32LE(40), size);
  assert.equal(b.readUInt16LE(22), channels);
  assert.equal(b.readUInt32LE(24), 8000);
  assert.equal(b.readUInt16LE(34), 24);
  return b;
}

for (const [bits, floating] of [[8, false], [16, false], [24, false], [32, false], [32, true]]) {
  const bytes = fixture(bits, 2, 8195, floating);
  const input = path.join(dir, 'input-' + bits + '-' + floating + '.wav'); fs.writeFileSync(input, bytes);
  const options = { ...defaults, tempo: 0.75, pitch: 3 };
  const expected = Buffer.from(transform_wav(bytes, options.tempo, options.pitch, options.rate));
  for (const block of [127, 4096]) {
    const output = input + '-' + block + '.wav';
    const result = streamWav(input, output, options, block);
    assert.deepEqual(outputCheck(output, Math.floor(8195 / 0.75 + 0.5), 2), expected);
    assert.ok(result.max_input_read_bytes <= block * 2 * bits / 8);
    rows.push({ case: 'codec-and-chunk-agreement', bits, floating, block });
  }
}

for (const channels of [1, 8]) for (const frames of [0, 1, 4099]) {
  const input = path.join(dir, 'short-' + channels + '-' + frames + '.wav');
  const bytes = fixture(24, channels, frames); fs.writeFileSync(input, bytes);
  const output = input + '.out.wav';
  streamWav(input, output, defaults);
  assert.deepEqual(outputCheck(output, frames, channels), Buffer.from(transform_wav(bytes, 1, 0, 1)));
  rows.push({ case: 'short-and-multichannel', channels, frames });
}

// Seek over odd metadata; fmt may follow data. The padding belongs to the file,
// not to PCM, and must not be emitted as an extra frame.
const source = fixture(16, 2, 4099);
const junk = Buffer.from([74, 85, 78, 75, 1, 0, 0, 0, 7, 0]);
const reordered = Buffer.concat([source.subarray(0, 12), junk, source.subarray(36), source.subarray(12, 36)]);
reordered.writeUInt32LE(reordered.length - 8, 4);
const orderInput = path.join(dir, 'reordered.wav'); fs.writeFileSync(orderInput, reordered);
streamWav(orderInput, orderInput + '.out.wav', defaults);
assert.deepEqual(outputCheck(orderInput + '.out.wav', 4099, 2), Buffer.from(transform_wav(reordered, 1, 0, 1)));
rows.push({ case: 'odd-metadata-and-data-before-format' });

const cli = (...args) => spawnSync(process.execPath, [path.join(root, 'scripts/moonstretch.mjs'), ...args], { encoding: 'utf8', timeout: 60000 });
const target = path.join(dir, 'target.wav');
let child = cli(orderInput, target, '--stream', '--source-bpm', '120', '--target-bpm', '90', '--pitch', '3');
assert.equal(child.status, 0, child.stderr);
const report = JSON.parse(child.stderr.trim()); assert.equal(report.mode, 'stream'); assert.equal(report.tempo, 0.75);
outputCheck(target, Math.floor(4099 / 0.75 + 0.5), 2);
rows.push({ case: 'real-cli-known-bpm' });
const original = fs.readFileSync(target);
child = cli(orderInput, target, '--stream'); assert.notEqual(child.status, 0);
assert.deepEqual(fs.readFileSync(target), original); rows.push({ case: 'no-overwrite' });
for (const args of [[orderInput, target + 'x', '--stream', '--detect-bpm'], [orderInput, target + 'x', '--stream', '--target-bpm', '90'], ['-', target + 'x', '--stream'], [orderInput, '-', '--stream']]) {
  child = cli(...args); assert.notEqual(child.status, 0); assert.ok(child.stderr.includes('--stream'));
}
assert.equal(fs.existsSync(target + 'x'), false);
rows.push({ case: 'unsupported-stream-modes-rejected' });

for (const name of ['truncated', 'duplicate-data', 'partial-frame', 'late-nan', 'high-bit-riff', 'high-bit-wave', 'high-bit-fmt', 'high-bit-data']) {
  let bytes = fixture(32, 2, 8195, true);
  const fourccOffsets = { 'high-bit-riff': 0, 'high-bit-wave': 8, 'high-bit-fmt': 12, 'high-bit-data': 36 };
  if (name in fourccOffsets) bytes[fourccOffsets[name]] |= 0x80;
  if (name === 'truncated') bytes = bytes.subarray(0, bytes.length - 1);
  if (name === 'duplicate-data') { bytes = Buffer.concat([bytes, bytes.subarray(36)]); bytes.writeUInt32LE(bytes.length - 8, 4); }
  if (name === 'partial-frame') { bytes = bytes.subarray(0, bytes.length - 4); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.writeUInt32LE(bytes.length - 44, 40); }
  if (name === 'late-nan') bytes.writeFloatLE(NaN, bytes.length - 4);
  const input = path.join(dir, name + '.wav'); fs.writeFileSync(input, bytes);
  const output = input + '.out.wav';
  assert.throws(() => streamWav(input, output, defaults), /WAV|PCM|finite/);
  assert.equal(fs.existsSync(output), false, 'failure must not leave a plausible partial result');
  assert.deepEqual(fs.readFileSync(input), bytes, 'input must remain unchanged');
  rows.push({ case: name + '-rejected-without-partial-output' });
}

const longReports = [];
for (const frames of [32000, 480000]) {
  const input = path.join(dir, 'duration-' + frames + '.wav'); fs.writeFileSync(input, fixture(16, 2, frames));
  const result = streamWav(input, input + '.out.wav', { ...defaults, tempo: 0.8, pitch: 3 });
  assert.ok(result.first_output_after_input_frames < frames);
  assert.equal(result.max_input_read_bytes, 4096 * 4);
  outputCheck(input + '.out.wav', Math.floor(frames / 0.8 + 0.5), 2);
  longReports.push(result);
}
assert.ok(longReports[1].peak_retained_pcm_frames <= longReports[0].peak_retained_pcm_frames + 4096);
rows.push({ case: 'long-recording-backpressure', measurements: longReports });
const reportPath = process.argv[2] ? path.resolve(process.argv[2]) : path.join(base, 'stream-cli-quality.json');
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
fs.writeFileSync(reportPath, JSON.stringify({ description: 'File pipeline conformance and retained-PCM measurements, not process RSS or subjective audio quality.', checks: rows.length, rows }, null, 2) + '\n');
console.log('Verified ' + rows.length + ' streaming file scenarios; report: ' + reportPath);
