import fs from 'node:fs';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { performance } from 'node:perf_hooks';
import { transform_pcm } from '../_build/js/release/build/bridge/bridge.js';

const sampleRate = 48000;
const channels = 2;
const seconds = 3;
const frames = sampleRate * seconds;
const input = Array.from({ length: frames * channels }, (_, i) => {
  const time = Math.floor(i / channels) / sampleRate;
  return 0.3 * Math.sin(2 * Math.PI * (i % 2 ? 659.25 : 440) * time) +
    0.1 * Math.sin(2 * Math.PI * 110 * time) * Math.exp(-5 * (time % 0.5));
});
const rows = [];
for (const [name, tempo, pitch, rate] of [
  ['identity', 1, 0, 1],
  ['speech_slow', 0.75, 0, 1],
  ['speech_fast', 1.5, 0, 1],
  ['transpose', 1, 7, 1],
  ['combined', 0.5, 12, 0.5],
]) {
  // Warm-up includes coefficient table generation; every timed run is a new stream.
  transform_pcm(input.slice(0, sampleRate / 2 * channels), sampleRate, channels, tempo, pitch, rate);
  const timings = [];
  let outputFrames = 0;
  for (let run = 0; run < 3; run++) {
    const begin = performance.now();
    const output = transform_pcm(input, sampleRate, channels, tempo, pitch, rate);
    timings.push(performance.now() - begin);
    outputFrames = output.length / channels;
    if (outputFrames !== Math.round(frames / (tempo * rate)) || !output.every(Number.isFinite)) {
      throw new Error(`Invalid benchmark result: ${name}`);
    }
  }
  timings.sort((a, b) => a - b);
  rows.push({ name, tempo, pitch_semitones: pitch, rate, input_frames: frames,
    output_frames: outputFrames, median_ms: timings[1], minimum_ms: timings[0],
    maximum_ms: timings[2], input_audio_seconds_per_wall_second: seconds * 1000 / timings[1] });
}
const report = { backend: 'MoonBit JS release / Node.js', node: process.version,
  platform: `${process.platform}/${process.arch}`, cpu: os.cpus()[0]?.model,
  sample_rate: sampleRate, channels, input_seconds: seconds,
  commit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
  includes_stream_construction: true, excludes_file_io: true, rows };
const output = process.argv[2] || 'work/benchmark.json';
fs.mkdirSync(new URL('../work/', import.meta.url), { recursive: true });
fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
for (const row of rows) console.log(`${row.name}: ${row.median_ms.toFixed(1)} ms, ${row.input_audio_seconds_per_wall_second.toFixed(2)} input audio seconds/s`);
console.log(`Report: ${output}`);
